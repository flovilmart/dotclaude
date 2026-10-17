# Fixture for tests/run-tests.nu: a test name the runner can't call
use std/testing *

@test
def "the owner's test" [] { }
