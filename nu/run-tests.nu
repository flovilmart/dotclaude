#!/usr/bin/env nu
# run-tests.nu [...files] [--filter <text>] — runs the tests in **/tests/*.nu under ~/.claude
#
# Tests use the markers of nushell's standard library (`use std/testing *`):
#   @test          a test: a plain `def`, failing by throwing (std/assert)
#   @ignore        skip it (reported as skipped)
#   @before-all    runs once per file; its record is the base context
#   @before-each   runs before each test; its record is merged into the context
#   @after-each    runs after each test, with the context as input
#   @after-all     runs once per file, with the base context as input
# Each test receives the context as pipeline input ($in). Test names are plain words
# (letters, digits, spaces, - and _): the runner calls each test by its name. std/testing only defines
# these markers; this runner finds them with `scope commands`. Each file runs in its
# own nu process, started without proxy variables (tests talk to 127.0.0.1 only; removing
# them inside the process isn't enough: nushell's jobs and HTTP client can still see them).
# Exit code 1 when any test fails. In GitHub Actions it also prints an annotation per failing
# test (at the failing line) and appends a results table to the job summary (gha.nu).

use gha.nu

const NO_PROXY = [-u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy]

def marked [cmds: list, attr: string] {
  $cmds | where {|c| $attr in ($c.attributes | get name) } | get name
}

# The script that runs one file's tests and prints their results as JSON
def runner-script [file: string, cmds: list] {
  let call = {|name| if $name == null { "{}" } else { $"\(($name) | default {})" } }
  let before_all = (marked $cmds before-all | get 0?)
  let before_each = (marked $cmds before-each | get 0?)
  let after_each = (marked $cmds after-each | get 0?)
  let after_all = (marked $cmds after-all | get 0?)
  let ignored = (marked $cmds ignore)
  let tests = (marked $cmds test)
  let runs = ($tests | each {|t|
    if $t in $ignored {
      $"  {name: ($t | to json), status: skipped}"
    } else {
      let after = if $after_each == null { "" } else { $"; try { $ctx | ($after_each) | ignore }" }
      [
        $"  \(do {"
        $"    let ctx = \($base | merge (do $call $before_each))"
        $"    let r = \(try { $ctx | ($t) | ignore; {status: passed} } catch {|e| {status: failed, error: \($e.rendered? | default $e.msg | ansi strip)} })($after)"
        $"    $r | insert name ($t | to json)"
        $"  })"
      ] | str join "\n"
    }
  })
  [
    $"source ($file | to json)"
    $"let base = (do $call $before_all)"
    "let results = ["
    ...$runs
    "]"
    (if $after_all == null { "" } else { $"try { $base | ($after_all) | ignore }" })
    "print ($results | to json --raw)"
  ] | str join "\n"
}

# Line of a test's `def` in its file: where its annotation points when the error has no location
def def-line [file: string, name: string] {
  if not ($file | path exists) { return 1 }
  let at = (open --raw $file | lines | enumerate | where {|l| $l.item | str contains $"def \"($name)\"" } | get 0?.index)
  if $at == null { 1 } else { $at + 1 }
}

def report [results: list, root: string] {
  let failures = ($results | where status == failed)
  for row in $failures {
    let error = ($row.error? | default "test names must be plain words (letters, digits, spaces, - and _)")
    let loc = (gha error-location $error $root | default {file: $row.file, line: (def-line ($root | path join $row.file) $row.name)})
    let message = ($error | lines | where {|l| $l !~ '^\s*$' } | first 12 | str join "\n")
    print (gha annotation error $message --file $loc.file --line $loc.line --title $"test failed: ($row.name)")
  }
  let by_file = ($results | group-by file --to-table | each {|g|
    let n = {|status| $g.items | where status == $status | length }
    $"| `($g.file)` | (do $n passed) | (do $n failed) | (do $n skipped) |"
  })
  let failed_list = ($failures | each {|f|
    # the error's message: its `x ...` line, else its first line
    let lines = ($f.error? | default "test names must be plain words" | lines | where {|l| $l !~ '^\s*$' })
    let message = ($lines | where {|l| $l =~ '^\s*x ' } | get 0? | default ($lines | get 0? | default "") | str replace --regex '^\s*x ' '')
    $"- `($f.file)`: **(gha cell $f.name)**: (gha cell $message)"
  })
  let skipped = ($results | where status == skipped | length)
  gha summary ([
    $"### nu tests: ($results | length) run, ($failures | length) failed, ($skipped) skipped"
    ""
    "| file | passed | failed | skipped |"
    "|------|-------:|-------:|--------:|"
    ...$by_file
    ...(if ($failures | is-empty) { [] } else { ["" "**Failures**" "" ...$failed_list] })
    ""
  ] | str join "\n")
}

def main [...files: string, --filter: string = ""] {
  let root = ($env.CURRENT_FILE | path expand | path dirname | path dirname)
  let targets = if ($files | is-empty) {
    glob $"($root)/{nu,skills}/**/tests/*.nu" | sort
  } else {
    $files | each {|f| $f | path expand }
  }
  let results = ($targets | each {|file|
    let label = ($file | path relative-to $root)
    let cmds = (^nu --no-config-file -c $"source ($file | to json); scope commands | where type == custom | select name attributes | to json" | from json)
    let tests = (marked $cmds test | where {|t| $filter == "" or ($t | str contains $filter) })
    if ($tests | is-empty) { return [] }
    let bad = ($tests | where {|t| $t !~ '^[A-Za-z0-9 _-]+$' })
    if ($bad | is-not-empty) {
      print $"  FAIL ($label): test names must be plain words \(letters, digits, spaces, - and _\): ($bad | str join '; ')"
      return [{name: ($bad | str join "; "), status: failed, file: $label}]
    }
    let script = (^mktemp | str trim)
    runner-script $file ($cmds | where {|c| $c.name in $tests or ($c.attributes.name | any {|a| $a != test }) }) | save --force $script
    let r = (do { ^env ...$NO_PROXY nu --no-config-file $script } | complete)
    rm --force $script
    let rows = (try { $r.stdout | lines | last | from json } catch {
      [{name: "(file)", status: failed, error: ($r.stderr | ansi strip | lines | first 15 | str join "\n")}]
    })
    $rows | each {|row|
      let mark = match $row.status { "passed" => "ok  ", "skipped" => "skip", _ => "FAIL" }
      print $"  ($mark) ($label): ($row.name)"
      if $row.status == "failed" {
        print ($row.error | lines | where {|l| $l !~ '^\s*$' } | first 10 | each {|l| $"       ($l)" } | str join "\n")
      }
      $row | insert file $label
    }
  } | flatten)
  let failed = ($results | where status == failed | length)
  let skipped = ($results | where status == skipped | length)
  print $"nu tests: ($results | length) run, ($failed) failed, ($skipped) skipped"
  if (gha enabled) { report $results $root }
  if $failed > 0 { exit 1 }
}
