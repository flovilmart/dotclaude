# Tests for linear.nu's API key handling: where it lives, reading it, storing it with `op`.
# No 1Password: a fake `op` on PATH logs its arguments and answers from FAKE_OP_* variables.
use std/testing *
use std/assert
use ../linear.nu

# A directory with an `op` that appends its arguments to $env.FAKE_OP_LOG; `op read` prints $env.FAKE_OP_KEY
# (fails when empty), `op item get` succeeds when $env.FAKE_OP_EXISTS is 1, edit and create succeed
def fake-op [] {
  let bin = (mktemp -d | str trim)
  r##'#!/bin/sh
echo "$*" >> "$FAKE_OP_LOG"
case "$1 $2" in
  "read "*) if [ -n "$FAKE_OP_KEY" ]; then echo "$FAKE_OP_KEY"; exit 0; fi ;;
  "item get") if [ "$FAKE_OP_EXISTS" = 1 ]; then echo '{}'; exit 0; fi ;;
  "item edit"|"item create") exit 0 ;;
esac
echo '[ERROR] not found' >&2
exit 1
'## | save $"($bin)/op"
  chmod +x $"($bin)/op"
  $bin
}

# Run `code` with the fake op; returns {result, calls}
def with-op [vars: record, code: closure] {
  let log = (mktemp | str trim)
  let env_vars = {LINEAR_API_KEY: "", FAKE_OP_KEY: "", FAKE_OP_EXISTS: "0", FAKE_OP_LOG: $log, PATH: ($env.PATH | prepend (fake-op))} | merge $vars
  let result = (with-env $env_vars { do $code })
  {result: $result, calls: (open --raw $log | lines)}
}

@test
def "the key lives at op Private Linear credential unless configured" [] {
  assert equal (linear key-ref {}) "op://Private/Linear/credential"
  assert equal (linear key-ref {linear_api_key_ref: "op://Work/Linear/key"}) "op://Work/Linear/key"
}

@test
def "a reference splits into vault item and field" [] {
  assert equal (linear parse-ref "op://Work/Linear API/key") {vault: "Work", item: "Linear API", field: "key"}
  assert error {|| linear parse-ref "lin_api_0123" }
  assert error {|| linear parse-ref "op://Work/Linear" }
}

@test
def "the key is read from 1Password" [] {
  let r = (with-op {FAKE_OP_KEY: "lin_api_secret"} {|| linear auth {linear_api_key_ref: "op://Work/Linear/key"} })
  assert equal $r.result "lin_api_secret"
  assert equal $r.calls ["read op://Work/Linear/key"]
}

@test
def "LINEAR_API_KEY overrides 1Password" [] {
  let r = (with-op {LINEAR_API_KEY: "lin_api_env"} {|| linear auth {} })
  assert equal $r.result "lin_api_env"
  assert equal $r.calls []
}

@test
def "an unreadable key points to linear login" [] {
  let r = (with-op {} {|| try { linear auth {}; "read" } catch {|e| $e.msg } })
  assert ($r.result | str contains "op read op://Private/Linear/credential failed")
  assert ($r.result | str contains "linear login")
}

@test
def "storing a key creates an API Credential item when there is none" [] {
  let r = (with-op {} {|| linear store-key "op://Private/Linear/credential" "lin_api_new" })
  assert equal $r.result {ref: "op://Private/Linear/credential", item: "created"}
  assert equal $r.calls [
    "item get Linear --vault Private --format json"
    "item create --category API Credential --title Linear --vault Private credential=lin_api_new"
  ]
}

@test
def "storing a key updates the existing item" [] {
  let r = (with-op {FAKE_OP_EXISTS: "1"} {|| linear store-key "op://Work/Linear/key" "lin_api_new" })
  assert equal $r.result {ref: "op://Work/Linear/key", item: "updated"}
  assert equal ($r.calls | last) "item edit Linear --vault Work key[password]=lin_api_new"
}
