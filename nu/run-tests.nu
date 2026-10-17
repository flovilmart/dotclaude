#!/usr/bin/env nu
# run-tests.nu [filter] — runs every command exported from nu/tests/*.nu, each in its own
# nu process, and prints ok/FAIL per test (the nupm convention: exported commands of a
# tests module are tests). Exit code 1 when any test fails. Proxy variables are cleared:
# the tests only talk to 127.0.0.1.

def main [filter: string = ""] {
  let dir = ($env.CURRENT_FILE | path dirname)
  let results = (glob $"($dir)/tests/*.nu" | sort | each {|file|
    let module = ($file | path parse | get stem)
    let names = (^nu --no-config-file -c $"use ($file); scope modules | where name == ($module) | get 0.commands.name | to json" | from json)
    $names | where {|n| $filter == "" or ($n | str contains $filter) } | each {|name|
      let r = (do { ^nu --no-config-file -c $"hide-env --ignore-errors HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy; use ($file); ($module) ($name)" } | complete)
      let ok = ($r.exit_code == 0)
      print $"  (if $ok { 'ok  ' } else { 'FAIL' }) ($module): ($name | str replace 'test ' '')"
      if not $ok { print ($r.stderr | lines | where {|l| $l !~ '^\s*$' } | first 8 | each {|l| $"       ($l)" } | str join "\n") }
      {name: $name, ok: $ok}
    }
  } | flatten)
  let failed = ($results | where not ok | length)
  print $"nu tests: ($results | length) run, ($failed) failed"
  if $failed > 0 { exit 1 }
}
