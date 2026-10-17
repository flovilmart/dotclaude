# oauth.nu — OAuth 2.1 for command-line tools, in nushell: authorization code with
# PKCE over a loopback redirect (RFC 8252), refresh-token rotation, token storage.
# Provider-agnostic: a provider is a record.
#
#   use ~/.claude/nu/oauth.nu
#   let p = {
#     name: "linear"                                     # storage key
#     authorize_url: "https://linear.app/oauth/authorize"
#     token_url: "https://api.linear.app/oauth/token"
#     revoke_url: "https://api.linear.app/oauth/revoke"  # optional
#     client_id: "..."                                   # public client: PKCE, no secret
#     scopes: [read write], scope_sep: ","               # scope_sep defaults to " "
#     port: 8765                                         # registered redirect http://<host>:<port>/callback
#     host: "127.0.0.1"                                  # optional; some providers only accept "localhost"
#     redirect_uri: "https://…/callback"                # optional: a public URL (e.g. a dev tunnel) that forwards to
#                                                        # 127.0.0.1:<port>, for providers that refuse loopback URLs
#     extra: {actor: user}                               # optional extra authorize parameters
#     store: "keychain" | "file", store_dir: "..."       # optional; default keychain on macOS, file elsewhere
#   }
#   oauth login $p        # once: opens the browser, catches the redirect, stores the tokens
#   oauth token $p        # a valid access token; refreshes (and stores the rotated refresh token) when needed
#   oauth status $p       # what is stored, without the secrets
#   oauth logout $p       # revoke when the provider supports it, delete the stored tokens
#
# The callback listener is a one-shot `nc -l` run as a job: nushell can't serve HTTP,
# and an OAuth redirect is one request and one response. The job is killed as soon as
# the request line arrives, because a browser may keep the connection open. Without nc,
# or with --manual, you paste the redirected URL instead.

const REFRESH_MARGIN = 10min
const SERVICE = "nu-oauth"

# ── PKCE (RFC 7636) ─────────────────────────────────────────────────────────

export def challenge-of [verifier: string] {
  $verifier | hash sha256 --binary | encode base64 --url --nopad
}

export def pkce [] {
  let verifier = (random binary 32 | encode base64 --url --nopad)
  {verifier: $verifier, challenge: (challenge-of $verifier), method: "S256"}
}

# ── authorization request and callback ──────────────────────────────────────

# The redirect URL sent to the provider (and registered with it): the public redirect_uri when
# set, else the loopback URL. The listener is on 127.0.0.1:<port> either way.
export def redirect-uri [p] {
  if ($p.redirect_uri? | default "") != "" { return $p.redirect_uri }
  $"http://($p.host? | default '127.0.0.1'):($p.port)/callback"
}

export def authorize-url [p, pkce, state: string] {
  let query = ({
    response_type: "code"
    client_id: $p.client_id
    redirect_uri: (redirect-uri $p)
    scope: ($p.scopes | str join ($p.scope_sep? | default " "))
    state: $state
    code_challenge: $pkce.challenge
    code_challenge_method: $pkce.method
  } | merge ($p.extra? | default {}) | url build-query)
  $"($p.authorize_url)?($query)"
}

def query-params [query: string] {
  $query | split row "&" | where {|kv| $kv != "" } | reduce --fold {} {|kv, acc|
    let parts = ($kv | split row "=")
    let value = ($parts | skip 1 | str join "=" | str replace --all "+" " " | url decode)
    $acc | upsert ($parts.0 | url decode) $value
  }
}

# The code from a redirect: an HTTP request line ("GET /callback?code=..&state=.. HTTP/1.1")
# or a pasted URL. Fails on a provider error or a state mismatch (CSRF).
export def parse-callback [input: string, state: string] {
  let target = ($input | str trim | split row " " | where {|w| $w =~ '\?' } | get 0? | default "")
  let params = (query-params ($target | split row "?" | skip 1 | str join "?"))
  if "error" in $params {
    error make { msg: $"authorization refused: ($params.error) ($params.error_description? | default '')" }
  }
  if ($params.state? | default "") != $state {
    error make { msg: "state mismatch: ignoring this callback (stale tab or forged request)" }
  }
  if ($params.code? | default "") == "" { error make { msg: "no authorization code in the callback" } }
  $params.code
}

const PAGE = "<html><body style=\"font-family: system-ui; margin: 3em\">Signed in. You can close this tab.</body></html>"

# Stop listeners an interrupted login left behind on this port: they would take the callback.
# The pattern is anchored to the whole command line, so it can't match anything else.
export def clear-listener [port: int] {
  do { ^pkill -f $"^\(/usr/bin/\)?nc -l 127\\.0\\.0\\.1 ($port)$" } | complete | ignore
}

# Wait for one request on 127.0.0.1:<port> and return its request line ("" on timeout).
export def wait-for-callback [port: int, timeout: duration = 5min] {
  clear-listener $port
  let out = (^mktemp | str trim)
  let response = $"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ($PAGE | encode utf-8 | bytes length)\r\nConnection: close\r\n\r\n($PAGE)"
  let job = (job spawn { $response | ^nc -l 127.0.0.1 $port | save --force $out })
  let started = (date now)
  mut line = ""
  while ((date now) - $started) < $timeout {
    let first = (open --raw $out | lines | first 1 | str join | str trim)
    if ($first | str starts-with "GET ") { $line = $first; break }
    sleep 100ms
  }
  try { job kill $job }
  rm --force $out
  $line
}

# ── token endpoint ──────────────────────────────────────────────────────────

def token-request [p, form: record] {
  let resp = (
    http post --full --allow-errors --content-type application/x-www-form-urlencoded
      $p.token_url $form
  )
  let body = if ($resp.body | describe | str starts-with "record") { $resp.body } else { try { $resp.body | from json } catch { {} } }
  if $resp.status != 200 or ($body.access_token? | default "") == "" {
    error make { msg: $"token endpoint ($resp.status): ($body.error? | default '') ($body.error_description? | default '')" }
  }
  $body
}

def to-tokens [body, previous_refresh, now: datetime] {
  {
    access_token: $body.access_token
    # rotation: a new refresh token replaces the old one; keep the old one if none came back
    refresh_token: ($body.refresh_token? | default $previous_refresh)
    expires_at: (if $body.expires_in? == null { null } else { ($now + ($body.expires_in * 1sec)) | format date "%Y-%m-%dT%H:%M:%S%z" })
    scope: ($body.scope? | default "")
  }
}

export def exchange [p, code: string, verifier: string, --now: datetime] {
  let body = (token-request $p {
    grant_type: "authorization_code", code: $code, redirect_uri: (redirect-uri $p),
    client_id: $p.client_id, code_verifier: $verifier
  })
  to-tokens $body null ($now | default (date now))
}

export def refresh [p, refresh_token: string, --now: datetime] {
  let body = (token-request $p {grant_type: "refresh_token", refresh_token: $refresh_token, client_id: $p.client_id})
  to-tokens $body $refresh_token ($now | default (date now))
}

# ── storage: macOS Keychain, or a 0600 file ─────────────────────────────────

def backend [p] {
  $p.store? | default (if $nu.os-info.name == "macos" { "keychain" } else { "file" })
}

def store-file [p] {
  let dir = ($p.store_dir? | default "~/.local/state/nu-oauth" | path expand)
  $"($dir)/($p.name).json"
}

export def store-get [p] {
  if (backend $p) == "keychain" {
    let r = (do { ^security find-generic-password -a $p.name -s $SERVICE -w } | complete)
    if $r.exit_code != 0 { return null }
    $r.stdout | str trim | decode base64 | decode utf-8 | from json
  } else {
    let f = (store-file $p)
    if ($f | path exists) { open $f } else { null }
  }
}

export def store-set [p, tokens] {
  if (backend $p) == "keychain" {
    # through `security -i` on stdin, so the token never appears in a process's arguments
    let b64 = ($tokens | to json --raw | encode base64)
    $"add-generic-password -U -a ($p.name) -s ($SERVICE) -w ($b64)\n" | ^security -i | ignore
  } else {
    let f = (store-file $p)
    mkdir ($f | path dirname)
    ^chmod 700 ($f | path dirname)
    $tokens | to json | save --force $f
    ^chmod 600 $f
  }
}

export def store-delete [p] {
  if (backend $p) == "keychain" {
    do { ^security delete-generic-password -a $p.name -s $SERVICE } | complete | ignore
  } else {
    rm --force (store-file $p)
  }
}

# ── commands ────────────────────────────────────────────────────────────────

export def login [p, --manual, --timeout: duration = 5min] {
  let pk = (pkce)
  let state = (random chars --length 32)
  let url = (authorize-url $p $pk $state)
  let listen = not $manual and (which nc | is-not-empty)
  print $"Opening the browser to authorize ($p.name). If it doesn't open, visit:\n($url)\n"
  if ($p.redirect_uri? | default "") != "" {
    print $"Waiting on 127.0.0.1:($p.port) for the callback forwarded from ($p.redirect_uri)\n"
  }
  let opener = (["open" "xdg-open"] | where {|o| which $o | is-not-empty } | get 0?)
  if $opener != null { do { ^$opener $url } | complete | ignore }
  let input = if $listen {
    let line = (wait-for-callback $p.port $timeout)
    if $line == "" { error make { msg: $"no callback on port ($p.port) within ($timeout): retry, or use --manual" } }
    $line
  } else {
    input "Paste the URL your browser was redirected to: "
  }
  let tokens = (exchange $p (parse-callback $input $state) $pk.verifier)
  store-set $p $tokens
  {provider: $p.name, expires_at: $tokens.expires_at, scope: $tokens.scope, refreshable: ($tokens.refresh_token != null)}
}

# A valid access token, refreshed when it expires within REFRESH_MARGIN
export def token [p, --now: datetime] {
  let now = ($now | default (date now))
  let stored = (store-get $p)
  if $stored == null { error make { msg: $"not signed in to ($p.name): run the login command first" } }
  let fresh = ($stored.expires_at == null or (($stored.expires_at | into datetime) - $now) > $REFRESH_MARGIN)
  if $fresh { return $stored.access_token }
  if $stored.refresh_token == null { error make { msg: $"($p.name) token expired and cannot be refreshed: log in again" } }
  let next = (refresh $p $stored.refresh_token --now $now)
  store-set $p $next
  $next.access_token
}

export def status [p] {
  let stored = (store-get $p)
  if $stored == null { return {provider: $p.name, signed_in: false} }
  {provider: $p.name, signed_in: true, expires_at: $stored.expires_at, scope: $stored.scope,
   refreshable: ($stored.refresh_token != null), store: (backend $p)}
}

export def logout [p] {
  let stored = (store-get $p)
  if $stored != null and ($p.revoke_url? | default "") != "" {
    try {
      (http post --allow-errors --content-type application/x-www-form-urlencoded
        --headers [Authorization $"Bearer ($stored.access_token)"] $p.revoke_url {token: $stored.access_token}) | ignore
    }
  }
  store-delete $p
  {provider: $p.name, signed_in: false}
}
