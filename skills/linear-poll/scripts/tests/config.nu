# Tests for config.nu and linear.nu's auth choice, against the shipped config.example.md.
use std/testing *
use std/assert
use ../config.nu *
use ../linear.nu

const HERE = path self .
def example [] { parse-config (open --raw ($HERE | path join ../../../agent-workflow/config.example.md)) }

@test
def "integers and booleans and quoted strings are parsed" [] {
  let cfg = (example)
  assert equal $cfg.max_parallel 3
  assert equal $cfg.auto_merge true
  assert equal $cfg.comment_marker "🤖 agent-workflow"
}

@test
def "an empty value followed by a comment is absent" [] {
  assert equal ((example).reviewers? | default "absent") "absent"
}

@test
def "repos resolve by project then label then default" [] {
  let repos = (example).repos
  assert equal (resolve-repo $repos "Demo App" []) ("~/src/flovilmart/demo-app" | path expand)
  assert equal (resolve-repo $repos null [infra]) ("~/src/flovilmart/infra" | path expand)
  assert equal (resolve-repo $repos "Other" []) ("~/src/flovilmart/dotclaude" | path expand)
}

@test
def "linear uses an API key unless an OAuth client is configured" [] {
  let cfg = (example)
  assert equal (linear uses-oauth $cfg) false
  assert equal (linear uses-oauth ($cfg | upsert linear_oauth_client_id "client-1")) true
}

@test
def "the linear OAuth provider is a public client on the loopback port acting as the user" [] {
  let p = (linear provider ((example) | upsert linear_oauth_client_id "client-1"))
  assert equal ($p | select client_id scope_sep port extra) {client_id: "client-1", scope_sep: ",", port: 8765, extra: {actor: "user"}}
  assert ("client_secret" not-in $p)
}
