# Tests for nu/run-tests.nu, run against tests/fixtures/sample.nu.
use std/testing *
use std/assert

const HERE = path self .

def run-sample [] {
  let out = (mktemp -d | str trim)
  let runner = ($HERE | path join ../run-tests.nu)
  # GITHUB_ACTIONS off: in CI these deliberate failures must not reach the real job summary
  let r = (with-env {SAMPLE_OUT: $out, GITHUB_ACTIONS: "false"} { do { ^nu $runner ($HERE | path join fixtures/sample.nu) } | complete })
  {r: $r, lines: ($r.stdout | lines), after: (open --raw $"($out)/after.log" | lines)}
}

@before-all
def sample [] { {run: (run-sample)} }

@test
def "passing and failing and ignored tests are reported" [] {
  let lines = $in.run.lines
  assert ($lines | any {|l| $l =~ 'ok   .*: context reaches the test' })
  assert ($lines | any {|l| $l =~ 'FAIL .*: a failing test' })
  assert ($lines | any {|l| $l =~ 'skip .*: an ignored test' })
  assert ($lines | any {|l| $l == "nu tests: 3 run, 1 failed, 1 skipped" })
}

@test
def "a failure exits 1 and shows the assertion" [] {
  let run = $in.run
  assert equal $run.r.exit_code 1
  assert ($run.lines | any {|l| $l =~ 'These are not equal' })
}

@test
def "helpers without a test marker never run" [] {
  assert not ($in.run.lines | any {|l| $l =~ 'not a test|helpers are never run' })
}

@test
def "a test name the runner cannot call is a clear failure" [] {
  let r = (with-env {GITHUB_ACTIONS: "false"} { do { ^nu ($HERE | path join ../run-tests.nu) ($HERE | path join fixtures/badname.nu) } | complete })
  assert equal $r.exit_code 1
  assert ($r.stdout | str contains "test names must be plain words")
}

@test
def "after-each runs per executed test and after-all once" [] {
  assert equal $in.run.after ["each 2" "each 2" "all 1"]
}

@test
def "in GitHub Actions failures are annotated at the failing line and summarized" [] {
  let summary = (mktemp | str trim)
  let out = (mktemp -d | str trim)
  let r = (with-env {SAMPLE_OUT: $out, GITHUB_ACTIONS: "true", GITHUB_STEP_SUMMARY: $summary} {
    do { ^nu ($HERE | path join ../run-tests.nu) ($HERE | path join fixtures/sample.nu) } | complete
  })
  let annotations = ($r.stdout | lines | where {|l| $l starts-with "::" })
  assert equal ($annotations | length) 1
  assert ($annotations.0 starts-with "::error file=nu/tests/fixtures/sample.nu,line=25,title=test failed%3A a failing test::")
  let md = (open --raw $summary)
  assert ($md | str contains "### nu tests: 3 run, 1 failed, 1 skipped")
  assert ($md | str contains "| `nu/tests/fixtures/sample.nu` | 1 | 1 | 1 |")
  assert ($md | str contains "- `nu/tests/fixtures/sample.nu`: **a failing test**: These are not equal.")
}

@test
def "outside GitHub Actions nothing is annotated or summarized" [] {
  assert not ((run-sample).lines | any {|l| $l starts-with "::" })
}

