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

# A PATH with a fake `claude agents --json` and a fake `tmux` whose panes run `claude attach b`; tmux calls
# go to $env.FAKE_LOG. Sessions (Claude's state; what the watcher or the state file says):
#   a ENG-1 blocked, waiting review     b ENG-2 blocked, nothing known (oldest)   c ENG-3 working
#   d ENG-4 blocked but not running     e ENG-5 blocked, draft ready + a blocked slice in its state file
#   f ENG-6 idle, needs plan validation
def fake-sessions [] {
  let bin = (mktemp -d | str trim)
  [
    {id: a, pid: 1, name: "ENG-1", cwd: "/w/a", startedAt: 2000, state: blocked}
    {id: b, pid: 2, name: "ENG-2", cwd: "/w/b", startedAt: 1000, state: blocked}
    {id: c, pid: 3, name: "ENG-3", cwd: "/w/c", startedAt: 3000, state: working}
    {id: d, name: "ENG-4", cwd: "/w/d", startedAt: 4000, state: blocked}
    {id: e, pid: 5, name: "ENG-5", cwd: "/w/e", startedAt: 2500, state: blocked}
    {id: f, pid: 6, name: "ENG-6", cwd: "/w/f", startedAt: 2600, state: done}
  ] | to json | save $"($bin)/agents.json"
  $"#!/bin/sh\ncat '($bin)/agents.json'\n" | save $"($bin)/claude"
  r##'#!/bin/sh
echo "$*" >> "$FAKE_LOG"
case "$1" in
  list-panes) printf '%%0\tnu\n%%7\t"claude attach b"\n' ;;
  new-window) case "$*" in *-P*) echo '@5 %8' ;; esac ;;
  split-window) echo '%9' ;;
esac
'## | save $"($bin)/tmux"
  chmod +x $"($bin)/claude" $"($bin)/tmux"
  $env.PATH | prepend $bin
}

# A watcher state dir: waiting.json, and ENG-5's state file with a blocked slice
def fake-state [] {
  let dir = (mktemp -d | str trim)
  {at: "2026-10-17T12:00:00+0000", tickets: [
    {ticket: "ENG-1", waiting: "waiting review", detail: "https://gh/pr/1"}
    {ticket: "ENG-5", waiting: "draft ready", detail: "https://gh/pr/5"}
    {ticket: "ENG-6", waiting: "needs plan validation", detail: "plan on ENG-6 in Linear"}
  ]} | to json | save $"($dir)/waiting.json"
  mkdir $"($dir)/state"
  "# ENG-5\nphase: subtasks\n## Slices\n| # | branch | status | PR |\n| 1 | b1 | awaiting-validation | https://gh/pr/5 |\n| 2 | b2 | blocked | |\n" | save $"($dir)/state/ENG-5.md"
  $dir
}

@test
def "inbox says what each running session waits on most urgent first" [] {
  let s = (with-env {PATH: (fake-sessions)} { inbox --state-dir (fake-state) })
  assert equal ($s | select name waiting detail) [
    {name: "ENG-2", waiting: "needs input", detail: ""}
    {name: "ENG-5", waiting: "needs input", detail: "question in the session"}
    {name: "ENG-6", waiting: "needs plan validation", detail: "plan on ENG-6 in Linear"}
    {name: "ENG-1", waiting: "waiting review", detail: "https://gh/pr/1"}
  ]
}

@test
def "inbox without the watcher calls every blocked session needs input" [] {
  let s = (with-env {PATH: (fake-sessions)} { inbox --state-dir (mktemp -d | str trim) })
  assert equal ($s | select name waiting) [
    {name: "ENG-2", waiting: "needs input"} {name: "ENG-1", waiting: "needs input"} {name: "ENG-5", waiting: "needs input"}
  ]
}

@test
def "inbox and the poll rules name the same waits in the same order" [] {
  let rules = (^nu --no-config-file -c $"use ($HERE | path join ../../skills/linear-poll/scripts/rules.nu) WAITS; $WAITS | to nuon" | from nuon)
  assert equal $inbox.WAITS $rules
}

@test
def "inbox open skips sessions waiting review unless all" [] {
  let st = (fake-state)
  let mine = (with-env {PATH: (fake-sessions), TMUX: ""} { inbox open --dry-run --state-dir $st })
  assert equal ($mine | get name) ["ENG-2" "ENG-5" "ENG-6"]
  assert equal ($mine | get action | uniq) [attach]
  let all = (with-env {PATH: (fake-sessions), TMUX: ""} { inbox open --all --dry-run --state-dir $st })
  assert equal ($all | get name) ["ENG-2" "ENG-5" "ENG-6" "ENG-1"]
}

@test
def "inbox open splits one tmux window into a pane per session not already attached" [] {
  let log = (mktemp | str trim)
  let st = (fake-state)
  with-env {PATH: (fake-sessions), TMUX: "/tmp/fake,1,0", FAKE_LOG: $log} { inbox open --state-dir $st }
  let calls = (open --raw $log | lines)
  assert equal ($calls | where $it =~ "^(new-window|split-window)") [
    "new-window -P -F #{window_id} #{pane_id} -n inbox -c /w/e claude attach e"
    "split-window -P -F #{pane_id} -t @5 -c /w/f claude attach f"
  ]
  assert equal ($calls | where $it starts-with "set-option -p") [
    "set-option -p -t %8 @inbox ENG-5 · needs input"
    "set-option -p -t %9 @inbox ENG-6 · needs plan validation"
  ]
  assert ("select-layout -t @5 tiled" in $calls)
  assert equal ($calls | last) "select-pane -t %8"
}

@test
def "inbox open windows opens a tmux window per session not already attached" [] {
  let log = (mktemp | str trim)
  let st = (fake-state)
  with-env {PATH: (fake-sessions), TMUX: "/tmp/fake,1,0", FAKE_LOG: $log} { inbox open --windows --state-dir $st }
  let calls = (open --raw $log | lines)
  assert equal ($calls | where $it starts-with "new-window") [
    "new-window -d -n ENG-5 -c /w/e claude attach e"
    "new-window -d -n ENG-6 -c /w/f claude attach f"
  ]
  assert equal ($calls | where $it starts-with "select-window") ["select-window -t %7"]
}

@test
def "inbox board groups every running session waits first then working and done" [] {
  let b = (with-env {PATH: (fake-sessions)} { inbox board --state-dir (fake-state) })
  assert equal ($b | select name waiting) [
    {name: "ENG-2", waiting: "needs input"}
    {name: "ENG-5", waiting: "needs input"}
    {name: "ENG-6", waiting: "needs plan validation"}
    {name: "ENG-3", waiting: "working"}
    {name: "ENG-1", waiting: "waiting review"}
  ]
  assert equal $inbox.GROUPS.0 $inbox.WAITS.0
}

@test
def "inbox attach selects an attached session and opens a window for another" [] {
  let log = (mktemp | str trim)
  let r = (with-env {PATH: (fake-sessions), TMUX: "/tmp/fake,1,0", FAKE_LOG: $log} { [(inbox attach b) (inbox attach e)] })
  assert equal ($r | get action) [selected opened]
  let calls = (open --raw $log | lines | where $it !~ "^list-panes")
  assert equal $calls ["select-window -t %7" "select-pane -t %7" "new-window -n ENG-5 -c /w/e claude attach e"]
}
