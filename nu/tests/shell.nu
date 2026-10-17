# Tests for the shell modules in nu/shell (no network, no 1Password: a fake `op` on PATH)
use std/testing *
use std/assert
use ../shell/linear.nu
use ../shell/inbox.nu

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
  assert equal $s {source: "1Password", ref: "op://Private/Linear API Key/credential", readable: false}
}

@test
def "linear status prefers LINEAR_API_KEY" [] {
  let s = (with-env {LINEAR_API_KEY: "lin_api_env"} { linear status --config (config-with "") })
  assert equal $s {source: "LINEAR_API_KEY", ref: "op://Private/Linear API Key/credential", readable: true}
}

@test
def "the autoload file loads the shell modules from the home checkout" [] {
  let text = (open --raw ($HERE | path join ../shell/autoload.nu))
  assert ($text | str contains "use ~/.claude/nu/shell/linear.nu")
  assert ($text | str contains "use ~/.claude/nu/shell/inbox.nu")
}

# A PATH with a fake `claude agents --json` (a: blocked, b: blocked and older, c: working, d: blocked
# but not running) and a fake `tmux` whose panes run `claude attach b`; tmux calls go to $env.FAKE_LOG
def fake-sessions [] {
  let bin = (mktemp -d | str trim)
  [
    {id: a, pid: 1, name: "ENG-1", cwd: "/w/a", startedAt: 2000, state: blocked}
    {id: b, pid: 2, name: "ENG-2", cwd: "/w/b", startedAt: 1000, state: blocked}
    {id: c, pid: 3, name: "ENG-3", cwd: "/w/c", startedAt: 3000, state: working}
    {id: d, name: "ENG-4", cwd: "/w/d", startedAt: 4000, state: blocked}
  ] | to json | save $"($bin)/agents.json"
  $"#!/bin/sh\ncat '($bin)/agents.json'\n" | save $"($bin)/claude"
  r##'#!/bin/sh
echo "$*" >> "$FAKE_LOG"
if [ "$1" = list-panes ]; then printf '%%0\tnu\n%%7\t"claude attach b"\n'; fi
'## | save $"($bin)/tmux"
  chmod +x $"($bin)/claude" $"($bin)/tmux"
  $env.PATH | prepend $bin
}

@test
def "inbox lists the running sessions that need input oldest first" [] {
  let s = (with-env {PATH: (fake-sessions)} { inbox })
  assert equal ($s | get id) [b a]
  assert equal ($s | get name) ["ENG-2" "ENG-1"]
}

@test
def "inbox open attaches one after another outside tmux" [] {
  let plan = (with-env {PATH: (fake-sessions), TMUX: ""} { inbox open --dry-run })
  assert equal ($plan | get action) [attach attach]
}

@test
def "inbox open opens a tmux window per session not already attached" [] {
  let log = (mktemp | str trim)
  with-env {PATH: (fake-sessions), TMUX: "/tmp/fake,1,0", FAKE_LOG: $log} { inbox open }
  let calls = (open --raw $log | lines)
  assert equal ($calls | where $it starts-with "new-window") ["new-window -d -n ENG-1 -c /w/a claude attach a"]
  assert equal ($calls | where $it starts-with "select-window") ["select-window -t %7"]
}
