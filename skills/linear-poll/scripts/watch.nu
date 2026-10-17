#!/usr/bin/env nu
# watch.nu [--once] [--dry-run] [--check] [--config <path>] [--fixtures <file>] [--state-dir <dir>]
#
# The Linear poll without the model. Every watch_interval seconds (default 60),
# during watch_hours on watch_days: one Linear query for my open issues (plus
# one for the comments the rules need), PRs every second cycle, then the rules
# in rules.nu decide, and this script acts:
#   - dispatches new tickets and restarts stopped coordinators itself
#     (dispatch.nu, resume.nu), redispatches or stalls dead ones (Linear comment, label)
#   - prints one line per event that needs the model or the human, and appends it to
#     <state-dir>/events.log. In monitor mode the watcher runs on its own (a tmux window)
#     and follow.nu, under the Monitor tool, turns each new line of events.log into a
#     notification in the dispatcher; quiet cycles cost nothing:
#       send <ticket>: <message>     relay to that running coordinator with SendMessage
#       spec-gate <ticket> <repo>    run the early spec gate for a next-cycle ticket
#       tell: <message>              tell the human
#       info: <message>              something the watcher did (dispatch, restart, redispatch)
#
# --once        one cycle, then exit (cron mode, or by hand)
# --dry-run     print the actions as `would ...` lines; execute nothing, save no state
# --check       check the API key and the queries, print what they return, exit
# --fixtures    read {issues, comments, sessions, prs} from a file instead of Linear, claude and gh (selftest)
#
# State: <state-dir>/watch-state.json (what was already reported), events.log, watch.log, watch.pid.
# The API key comes from `op read <linear_api_key_ref>` once at start, or $env.LINEAR_API_KEY.

use config.nu *
use rules.nu *
use linear.nu

const COOLDOWN = 10min

def range-has [spec, v: int] {
  if $spec == null or $spec == "*" { return true }
  $spec | into string | split row "," | any {|part|
    let b = ($part | split row "-" | each {|x| $x | str trim | into int })
    if ($b | length) == 1 { $v == $b.0 } else { $v >= $b.0 and $v <= $b.1 }
  }
}

def in-hours [cfg, now: datetime] {
  ((range-has ($cfg.watch_hours? | default "*") ($now | format date "%H" | into int))
    and (range-has ($cfg.watch_days? | default "*") ($now | format date "%u" | into int)))
}

def log-line [dir: string, msg: string] {
  $"((date now) | format date '%Y-%m-%dT%H:%M:%S%z') ($msg)\n" | save --append $"($dir)/watch.log"
}

# An event for the dispatcher: stdout, events.log (follow.nu delivers it) and watch.log
def emit [dir: string, line: string] {
  print $line
  $"($line)\n" | save --append $"($dir)/events.log"
  log-line $dir $line
}

def load-state [dir: string] {
  let p = $"($dir)/watch-state.json"
  if ($p | path exists) { try { open $p } catch { {} } } else { {} }
}

def save-state [dir: string, state] {
  let p = $"($dir)/watch-state.json"
  $state | to json | save --force $"($p).tmp"
  mv --force $"($p).tmp" $p
}

def gather [cfg, key, fixtures, with_prs: bool, since: string] {
  if $fixtures != null {
    let f = (open $fixtures)
    return {issues: $f.issues, sessions: $f.sessions, prs: (if $with_prs { $f.prs } else { [] })}
  }
  let dir = ($env.CURRENT_FILE | path dirname)
  let issues = (linear my-issues $key $cfg.team_key)
  let sessions = (^nu $"($dir)/sessions.nu" --json | from json)
  let prs = if not $with_prs { [] } else {
    $cfg.repos | get repo | uniq | each {|repo|
      try { ^nu $"($dir)/pr-sweep.nu" $repo --since $since | from json } catch { [] }
    } | flatten
  }
  {issues: $issues, sessions: $sessions, prs: $prs}
}

def comments [cfg, key, fixtures, issues: list, targets: list] {
  if $fixtures != null { return ((open $fixtures).comments? | default {}) }
  linear comments-for $key ($issues | where {|i| $i.identifier in $targets } | get id)
}

def dispatch [cfg, a] {
  let dir = ($env.CURRENT_FILE | path dirname)
  mut args = [$a.repo $a.ticket $a.branch "--dispatcher" ($cfg.dispatcher_name? | default "dispatcher") "--permission-mode" ($cfg.permission_mode? | default "auto")]
  if ($cfg.model? | default "") != "" { $args = ($args | append ["--model" $cfg.model]) }
  let out = (^nu $"($dir)/dispatch.nu" ...$args | from json)
  if $out.mode == "tmux" {
    $"tell: ($a.ticket) dispatched in a tmux window: accept the workspace trust dialog there once \(($out.worktree | path basename)\)"
  } else {
    $"info: dispatched ($a.ticket) \(($out.worktree | path basename), bg ($out.session)\)"
  }
}

# Run one action; returns {lines, cool} where cool marks the ticket for cooldown
def execute [cfg, key, a] {
  let dir = ($env.CURRENT_FILE | path dirname)
  let marker = $cfg.comment_marker
  match $a.type {
    "queued" => { {lines: [], cool: false} }
    "spec-gate" => { {lines: [$"spec-gate ($a.ticket) ($a.repo)"], cool: false} }
    "dispatch" => { {lines: [(dispatch $cfg $a)], cool: true} }
    "wake" => {
      let out = (^nu $"($dir)/resume.nu" $a.ticket $a.msg | str trim)
      if ($out | str starts-with "running") {
        {lines: [$"send ($a.ticket): ($a.msg)"], cool: false}
      } else if ($out | str starts-with "resumed") {
        {lines: [$"info: restarted ($a.ticket) with: ($a.msg)"], cool: true}
      } else if $a.repo != null and $a.branch != null {
        {lines: [(dispatch $cfg $a)], cool: true}
      } else {
        {lines: [$"tell: ($a.ticket) has news but no coordinator: ($a.msg)"], cool: true}
      }
    }
    "redispatch" => {
      let line = (dispatch $cfg $a)
      linear comment $key $a.issueId $"($marker) · ($a.ticket) · redispatched \(($a.n)/($a.max)\)"
      {lines: [($line | str replace "dispatched" $"redispatched \(($a.n)/($a.max)\)")], cool: true}
    }
    "stall" => {
      linear add-label $key $a.issueId $cfg.team_key $cfg.stalled_label
      linear comment $key $a.issueId $"($marker) · ($a.ticket) · stalled: coordinator died ($a.max) times; needs a human \(claude logs ($a.ticket)\)"
      {lines: [$"tell: ($a.ticket) stalled: its coordinator died ($a.max) times \(claude logs ($a.ticket)\)"], cool: true}
    }
  }
}

def cycle [cfg, key, fixtures, dry: bool, dir: string, state, with_prs: bool] {
  let now = (date now)
  let since = ($state.lastPrSweep? | default (($now - 1hr) | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ"))
  let data = (gather $cfg $key $fixtures $with_prs $since)
  let targets = (comment-targets $cfg $data.issues $data.sessions $state)
  let by_issue = (comments $cfg $key $fixtures $data.issues $targets)
  let issues = ($data.issues | each {|i|
    if $i.identifier in $targets { $i | upsert comments ($by_issue | get --optional $i.identifier | default []) } else { $i }
  })
  let r = (decide $cfg $now $issues $data.sessions $data.prs $state)

  if $dry {
    $r.actions | each {|a| print $"would ($a | to nuon)" } | ignore
    return $state
  }

  let results = ($r.actions | each {|a|
    try { execute $cfg $key $a } catch {|e|
      {lines: [$"tell: ($a.type) ($a.ticket) failed: ($e.msg)"], cool: true}
    } | insert ticket $a.ticket | insert type $a.type
  })
  for res in $results {
    for line in $res.lines { emit $dir $line }
    if $res.lines == [] { log-line $dir $"($res.type) ($res.ticket)" }
  }
  let until = (($now + $COOLDOWN) | format date "%Y-%m-%dT%H:%M:%S%z")
  let cooldown = ($results | where cool | reduce --fold $r.state.cooldown {|res, acc| $acc | upsert $res.ticket $until })
  $r.state
  | upsert cooldown $cooldown
  | upsert lastRun ($now | format date "%Y-%m-%dT%H:%M:%S%z")
  | upsert lastPrSweep (if $with_prs { $now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ" } else { $since })
}

def check [cfg, key, dir: string] {
  print $"Linear: authenticated as (linear whoami $key | to nuon)"
  let issues = (linear my-issues $key $cfg.team_key)
  print $"Linear: ($issues | length) open issues assigned to you in ($cfg.team_key)"
  print ($issues | select identifier state labels priority cycle hasSpec | first 10 | table)
  let sample = ($issues | first 3 | get id)
  print $"Linear: comments query ok \((linear comments-for $key $sample | columns | length) issues\)"
  let dir_scripts = ($env.CURRENT_FILE | path dirname)
  print $"claude agents: (^nu $"($dir_scripts)/sessions.nu" --json | from json | length) background sessions"
  print $"state dir: ($dir)"
}

def main [
  --once                 # one cycle, then exit
  --dry-run              # print actions, execute nothing, save nothing
  --check                # verify the API key and queries, then exit
  --config: string = ""  # default ~/.claude/skills/agent-workflow/config.local.md
  --fixtures: string     # offline inputs (selftest)
  --state-dir: string = "~/.claude/agent-workflow"
] {
  if "CLAUDECODE" in $env { hide-env CLAUDECODE }
  let cfg = if $config == "" { load-config } else { load-config $config }
  let dir = ($state_dir | path expand)
  mkdir $dir
  let key = if $fixtures != null { "" } else {
    if ($cfg.linear_api_key_ref? | default "") == "" and ($env.LINEAR_API_KEY? | default "") == "" {
      error make { msg: "set linear_api_key_ref in config.local.md (a 1Password reference such as op://Private/Linear/credential)" }
    }
    linear api-key ($cfg.linear_api_key_ref? | default "")
  }
  if $check { check $cfg $key $dir; return }

  # one watcher at a time: a second one (another Monitor, a cron tick) would act twice
  let pidfile = $"($dir)/watch.pid"
  if not $dry_run and ($pidfile | path exists) {
    let other = (open --raw $pidfile | str trim)
    if $other != ($nu.pid | into string) and ((do { ^ps -p $other } | complete).exit_code == 0) {
      emit $dir $"tell: another watcher is already running \(pid ($other)\); this one exits"
      return
    }
  }
  if not $dry_run { $nu.pid | into string | save --force $pidfile }

  let interval = (($cfg.watch_interval? | default 60) * 1sec)
  mut state = (load-state $dir)
  mut n = 0
  mut failures = 0
  loop {
    let now = (date now)
    if not $once and not (in-hours $cfg $now) { sleep 5min; continue }
    let with_prs = ($n mod 2 == 0)
    let res = (try { {ok: (cycle $cfg $key $fixtures $dry_run $dir $state $with_prs)} } catch {|e| {err: $e.msg} })
    if "ok" in $res {
      $state = $res.ok
      if not $dry_run { save-state $dir $state }
      $failures = 0
    } else {
      $failures += 1
      log-line $dir $"cycle failed: ($res.err)"
      if $failures == 5 or $once { emit $dir $"tell: watcher cycle failing \(($failures)x\): ($res.err)" }
    }
    $n += 1
    if $once { break }
    sleep $interval
  }
}
