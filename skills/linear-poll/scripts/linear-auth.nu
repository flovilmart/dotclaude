#!/usr/bin/env nu
# linear-auth.nu login [--manual] | status | logout
#
# Signs the agent-workflow watcher in to Linear with OAuth (authorization code + PKCE,
# ~/.claude/nu/oauth.nu), using the OAuth application in config `linear_oauth_client_id`.
# The tokens are stored in the macOS Keychain (a 0600 file elsewhere); access tokens
# last 24h and the watcher refreshes them itself.
#
#   login     opens the browser once and catches the redirect on
#             http://127.0.0.1:<linear_oauth_port>/callback (--manual: paste the redirected URL)
#   status    signed in or not, expiry and scope; never prints a token
#   logout    revokes the token at Linear and deletes it locally

use config.nu *
use linear.nu
use ../../../nu/oauth.nu

def main [] { print "usage: linear-auth.nu login [--manual] | status | logout" }

def provider [config: string] {
  let cfg = if $config == "" { load-config } else { load-config $config }
  if not (linear uses-oauth $cfg) {
    error make { msg: "set linear_oauth_client_id in config.local.md (the client ID of your Linear OAuth application)" }
  }
  linear provider $cfg
}

def "main login" [--manual, --config: string = ""] {
  let p = (provider $config)
  oauth login $p --manual=$manual | table | print
  print $"Signed in. Check it: nu ($env.CURRENT_FILE | path dirname)/watch.nu --check"
}

def "main status" [--config: string = ""] { oauth status (provider $config) }

def "main logout" [--config: string = ""] { oauth logout (provider $config) }
