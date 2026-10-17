# Tests for the shell modules in nu/shell (no network: status only reads config and local state)
use std/testing *
use std/assert
use ../shell/linear.nu

const HERE = path self .

def config-with [extra: string] {
  let f = (mktemp --suffix .yaml | str trim)
  $"team_key: DEMO\n($extra)\nrepos:\n  - match: default\n    repo: ~/src/x\n" | save --force $f
  $f
}

@test
def "linear status reports an API key setup without reading the key" [] {
  let s = (with-env {LINEAR_API_KEY: ""} { linear status --config (config-with "linear_api_key_ref: op://Private/Linear/credential") })
  assert equal $s {method: "api-key", source: "op://Private/Linear/credential"}
}

# The sign-in state itself is the machine's (Keychain or token file), so it's only checked for its type
@test
def "linear status reports an OAuth setup and whether it is signed in" [] {
  let s = (linear status --config (config-with "linear_oauth_client_id: client-1"))
  assert equal ($s | select method provider redirect_uri) {method: "oauth", provider: "linear", redirect_uri: "http://127.0.0.1:8765/callback"}
  assert equal ($s.signed_in | describe) "bool"
}

@test
def "linear status shows a configured public redirect uri" [] {
  let s = (linear status --config (config-with "linear_oauth_client_id: client-1\nlinear_oauth_redirect_uri: https://t-8765.euw.devtunnels.ms/callback"))
  assert equal $s.redirect_uri "https://t-8765.euw.devtunnels.ms/callback"
}

@test
def "linear login without an OAuth client says what to configure" [] {
  assert error {|| linear login --config (config-with "linear_api_key_ref: op://x/y/z") }
}

@test
def "the autoload file loads the shell modules from the home checkout" [] {
  let text = (open --raw ($HERE | path join ../shell/autoload.nu))
  assert ($text | str contains "use ~/.claude/nu/shell/linear.nu")
}
