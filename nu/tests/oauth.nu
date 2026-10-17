# Tests for oauth.nu, marked with std/testing's @test. Run: nu ~/.claude/nu/run-tests.nu
use std/testing *
use std/assert
use ../oauth.nu

def provider [extra: record = {}] {
  {
    name: "test", authorize_url: "https://auth.example/authorize", token_url: "http://127.0.0.1:18799/token",
    client_id: "client-1", scopes: [read write], scope_sep: ",", port: 18765, extra: {actor: user},
    store: "file", store_dir: (mktemp -d | str trim)
  } | merge $extra
}

# Serve one JSON response on 127.0.0.1:<port> and capture the request; returns {job, out, provider}
# (a provider whose token_url points at it). Each test uses its own port; stop it with `done`.
def fake-token-endpoint [port: int, body: record] {
  oauth clear-listener $port
  let out = (mktemp | str trim)
  let json = ($body | to json --raw)
  let resp = $"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ($json | encode utf-8 | bytes length)\r\nConnection: close\r\n\r\n($json)"
  let job = (job spawn { $resp | ^nc -l 127.0.0.1 $port | save --force $out })
  sleep 300ms
  {job: $job, out: $out, provider: (provider {token_url: $"http://127.0.0.1:($port)/token"})}
}

def done [ep] {
  try { job kill $ep.job }
  oauth clear-listener ($ep.provider.token_url | url parse | get port | into int)
}

def form-of [captured: string] {
  open --raw $captured | split row "\r\n\r\n" | last | split row "&"
  | reduce --fold {} {|kv, acc| let p = ($kv | split row "="); $acc | upsert $p.0 ($p.1? | default "" | url decode) }
}

# expected value from Python's hashlib + base64.urlsafe_b64encode on the RFC 7636 appendix B verifier
@test
def "pkce challenge is the unpadded base64url sha256 of the verifier" [] {
  assert equal (oauth challenge-of "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
}

@test
def "pkce verifier is 43 url-safe chars and matches its challenge" [] {
  let pk = (oauth pkce)
  assert equal ($pk.verifier | str length) 43
  assert ($pk.verifier =~ '^[A-Za-z0-9_-]+$')
  assert equal $pk.challenge (oauth challenge-of $pk.verifier)
  assert equal $pk.method "S256"
}

@test
def "authorize url carries the PKCE and loopback parameters" [] {
  let url = (oauth authorize-url (provider) {challenge: "ch", method: "S256"} "st")
  assert ($url | str starts-with "https://auth.example/authorize?")
  let q = ($url | url parse | get query)
  for part in ["response_type=code" "client_id=client-1" "redirect_uri=http%3A%2F%2F127.0.0.1%3A18765%2Fcallback" "scope=read%2Cwrite" "state=st" "code_challenge=ch" "code_challenge_method=S256" "actor=user"] {
    assert ($q | str contains $part) $"missing ($part) in ($q)"
  }
}

@test
def "a public redirect uri replaces the loopback one in the authorize url" [] {
  let p = (provider {redirect_uri: "https://abc-8765.euw.devtunnels.ms/callback"})
  assert equal (oauth redirect-uri $p) "https://abc-8765.euw.devtunnels.ms/callback"
  let q = (oauth authorize-url $p {challenge: "ch", method: "S256"} "st" | url parse | get query)
  assert ($q | str contains "redirect_uri=https%3A%2F%2Fabc-8765.euw.devtunnels.ms%2Fcallback")
}

@test
def "the token exchange sends the same public redirect uri" [] {
  let ep = (fake-token-endpoint 18775 {access_token: "a1", refresh_token: "r1", expires_in: 86400})
  let p = ($ep.provider | upsert redirect_uri "https://abc-8765.euw.devtunnels.ms/callback")
  oauth exchange $p "code-1" "verifier-1" | ignore
  let form = (form-of $ep.out)
  done $ep
  assert equal $form.redirect_uri "https://abc-8765.euw.devtunnels.ms/callback"
  assert equal $form.code_verifier "verifier-1"
}

@test
def "callback code is taken from a request line or a pasted url" [] {
  assert equal (oauth parse-callback "GET /callback?code=abc%2B1&state=st HTTP/1.1" "st") "abc+1"
  assert equal (oauth parse-callback "http://127.0.0.1:18765/callback?state=st&code=xyz" "st") "xyz"
}

@test
def "callback with a wrong state is refused" [] {
  assert error {|| oauth parse-callback "GET /callback?code=abc&state=other HTTP/1.1" "st" }
}

@test
def "callback with a provider error is refused" [] {
  assert error {|| oauth parse-callback "GET /callback?error=access_denied&state=st HTTP/1.1" "st" }
}

@test
def "loopback listener returns the request line and answers the browser" [] {
  let page = (mktemp | str trim)
  let browser = (job spawn { sleep 500ms; http get "http://127.0.0.1:18765/callback?code=c1&state=s1" | save --force $page })
  let line = (oauth wait-for-callback 18765 10sec)
  sleep 300ms
  assert equal (oauth parse-callback $line "s1") "c1"
  assert (open --raw $page | str contains "You can close this tab")
}

@test
def "listener gives up after the timeout" [] {
  assert equal (oauth wait-for-callback 18767 1sec) ""
}

@test
def "refresh posts a public-client refresh grant and rotates the refresh token" [] {
  let ep = (fake-token-endpoint 18771 {access_token: "a2", refresh_token: "r2", expires_in: 86400, scope: "read,write"})
  let now = ("2026-10-17T12:00:00Z" | into datetime)
  let t = (oauth refresh $ep.provider "r1" --now $now)
  let form = (form-of $ep.out)
  done $ep
  assert equal $form.grant_type "refresh_token"
  assert equal $form.refresh_token "r1"
  assert equal $form.client_id "client-1"
  assert ("client_secret" not-in $form)
  assert equal $t.refresh_token "r2"
  assert equal ($t.expires_at | into datetime) ($now + 1day)
}

@test
def "token is served from the store while it is fresh" [] {
  let p = (provider)
  oauth store-set $p {access_token: "a1", refresh_token: "r1", expires_at: "2026-10-17T13:00:00+0000", scope: ""}
  assert equal (oauth token $p --now ("2026-10-17T12:00:00Z" | into datetime)) "a1"
}

@test
def "token near expiry is refreshed and the rotated refresh token stored" [] {
  let ep = (fake-token-endpoint 18772 {access_token: "a2", refresh_token: "r2", expires_in: 86400})
  let p = $ep.provider
  oauth store-set $p {access_token: "a1", refresh_token: "r1", expires_at: "2026-10-17T12:05:00+0000", scope: ""}
  let got = (oauth token $p --now ("2026-10-17T12:00:00Z" | into datetime))
  done $ep
  assert equal $got "a2"
  assert equal (oauth store-get $p | get refresh_token) "r2"
}

@test
def "a refresh without a new refresh token keeps the old one" [] {
  let ep = (fake-token-endpoint 18773 {access_token: "a2", expires_in: 3600})
  let p = $ep.provider
  oauth store-set $p {access_token: "a1", refresh_token: "r1", expires_at: "2026-10-17T11:00:00+0000", scope: ""}
  oauth token $p --now ("2026-10-17T12:00:00Z" | into datetime) | ignore
  done $ep
  assert equal (oauth store-get $p | get refresh_token) "r1"
}

@test
def "the token file is private and logout removes it" [] {
  let p = (provider)
  oauth store-set $p {access_token: "a1", refresh_token: "r1", expires_at: null, scope: ""}
  let f = $"($p.store_dir)/test.json"
  assert equal (ls -l $f | get mode.0) "rw-------"
  assert equal (oauth status $p | get signed_in) true
  oauth logout $p | ignore
  assert equal (oauth status $p | get signed_in) false
}

@test
def "a listener left by an interrupted login is cleared before listening again" [] {
  let stale = (job spawn { "stale" | ^nc -l 127.0.0.1 18774 | ignore })
  sleep 200ms
  let browser = (job spawn { sleep 700ms; http get "http://127.0.0.1:18774/callback?code=fresh&state=s" | ignore })
  let line = (oauth wait-for-callback 18774 10sec)
  assert equal (oauth parse-callback $line "s") "fresh"
}

@test
def "token without login says to log in" [] {
  assert error {|| oauth token (provider) }
}

# Linux has no Keychain: there the file store above is what runs, and this test has nothing to do
@test
def "keychain store round trips on macOS" [] {
  if $nu.os-info.name != "macos" { return }
  # no explicit store: macOS must default to the Keychain
  let p = (provider {name: $"selftest-(random chars --length 8)"} | reject store)
  let tokens = {access_token: "a b&c", refresh_token: "r1", expires_at: null, scope: "read,write"}
  oauth store-set $p $tokens
  assert equal (oauth status $p | get store) "keychain"
  let back = (oauth store-get $p)
  oauth store-set $p ($tokens | upsert refresh_token "r2")
  let updated = (oauth store-get $p)
  oauth store-delete $p
  assert equal $back $tokens
  assert equal $updated.refresh_token "r2"
  assert equal (oauth store-get $p) null
}

