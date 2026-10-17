# Tests for the shell modules in nu/shell (no network, no 1Password: a fake `op` on PATH)
use std/testing *
use std/assert
use ../shell/linear.nu

const HERE = path self .

def config-with [extra: string] {
  let f = (mktemp --suffix .yaml | str trim)
  $"team_key: DEMO\n($extra)\nrepos:\n  - match: default\n    repo: ~/src/x\n" | save --force $f
  $f
}

# A PATH whose `op read` prints $env.FAKE_OP_KEY, or fails when it's empty
def fake-op [] {
  let bin = (mktemp -d | str trim)
  r##'#!/bin/sh
if [ "$1" = read ] && [ -n "$FAKE_OP_KEY" ]; then echo "$FAKE_OP_KEY"; exit 0; fi
echo '[ERROR] not found' >&2
exit 1
'## | save $"($bin)/op"
  chmod +x $"($bin)/op"
  $env.PATH | prepend $bin
}

@test
def "linear status says the key is readable without printing it" [] {
  let s = (with-env {LINEAR_API_KEY: "", FAKE_OP_KEY: "lin_api_secret", PATH: (fake-op)} { linear status --config (config-with "linear_api_key_ref: op://Work/Linear/key") })
  assert equal $s {source: "1Password", ref: "op://Work/Linear/key", readable: true}
}

@test
def "linear status says when 1Password has no key" [] {
  let s = (with-env {LINEAR_API_KEY: "", FAKE_OP_KEY: "", PATH: (fake-op)} { linear status --config (config-with "") })
  assert equal $s {source: "1Password", ref: "op://Private/Linear/credential", readable: false}
}

@test
def "linear status prefers LINEAR_API_KEY" [] {
  let s = (with-env {LINEAR_API_KEY: "lin_api_env"} { linear status --config (config-with "") })
  assert equal $s {source: "LINEAR_API_KEY", ref: "op://Private/Linear/credential", readable: true}
}

@test
def "the autoload file loads the shell modules from the home checkout" [] {
  let text = (open --raw ($HERE | path join ../shell/autoload.nu))
  assert ($text | str contains "use ~/.claude/nu/shell/linear.nu")
}
