# Tests for nu/run-tests.nu, run against tests/fixtures/sample.nu.
use std/testing *
use std/assert

const HERE = path self .

def run-sample [] {
  let out = (mktemp -d | str trim)
  let runner = ($HERE | path join ../run-tests.nu)
  let r = (with-env {SAMPLE_OUT: $out} { do { ^nu $runner ($HERE | path join fixtures/sample.nu) } | complete })
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
  let r = (do { ^nu ($HERE | path join ../run-tests.nu) ($HERE | path join fixtures/badname.nu) } | complete)
  assert equal $r.exit_code 1
  assert ($r.stdout | str contains "test names must be plain words")
}

@test
def "after-each runs per executed test and after-all once" [] {
  assert equal $in.run.after ["each 2" "each 2" "all 1"]
}
