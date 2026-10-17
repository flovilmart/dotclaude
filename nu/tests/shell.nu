# Tests for the shell modules in nu/shell (no network: status only reads config and local state)
use std/testing *
use std/assert
use ../shell/linear.nu

const HERE = path self .

def config-with [extra: string] {
  let f = (mktemp --suffix .md | str trim)
  $"- team_key: DEMO\n($extra)\n| match | repo |\n|---|---|\n| default | ~/src/x |\n" | save --force $f
  $f
}

@test
def "linear status reports an API key setup without reading the key" [] {
  let s = (with-env {LINEAR_API_KEY: ""} { linear status --config (config-with "- linear_api_key_ref: op://Private/Linear/credential") })
  assert equal $s {method: "api-key", source: "op://Private/Linear/credential"}
}

@test
def "linear status reports an OAuth setup that is not signed in yet" [] {
  let home = (mktemp -d | str trim)
  let s = (with-env {HOME: $home} { linear status --config (config-with "- linear_oauth_client_id: client-1") })
  assert equal ($s | select method provider signed_in) {method: "oauth", provider: "linear", signed_in: false}
}

@test
def "linear login without an OAuth client says what to configure" [] {
  assert error {|| linear login --config (config-with "- linear_api_key_ref: op://x/y/z") }
}

@test
def "the autoload file loads the shell modules from the home checkout" [] {
  let text = (open --raw ($HERE | path join ../shell/autoload.nu))
  assert ($text | str contains "use ~/.claude/nu/shell/linear.nu")
}
