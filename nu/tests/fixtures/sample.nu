# Fixture for tests/run-tests.nu: one of each case the runner must handle. Not discovered by
# the runner itself (it only globs tests/*.nu). The marker files go to $env.SAMPLE_OUT.
use std/testing *
use std/assert

@before-all
def setup-all [] { {from_all: 1} }

@before-each
def setup-each [] { {from_each: 2} }

@after-each
def teardown-each [] { $"each ($in.from_each)\n" | save --append $"($env.SAMPLE_OUT)/after.log" }

@after-all
def teardown-all [] { $"all ($in.from_all)\n" | save --append $"($env.SAMPLE_OUT)/after.log" }

@test
def "context reaches the test" [] {
  let ctx = $in
  assert equal $ctx {from_all: 1, from_each: 2}
}

@test
def "a failing test" [] { assert equal 1 2 }

@ignore
@test
def "an ignored test" [] { assert false }

def "not a test" [] { error make { msg: "helpers are never run" } }
