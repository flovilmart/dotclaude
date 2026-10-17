#!/usr/bin/env nu
# follow.nu [--once] [--reset] [--state-dir <dir>]
#
# Delivers the watcher's events to the dispatcher. Run under the Monitor tool:
# every new line of <state-dir>/events.log (written by watch.nu) is printed once,
# so it becomes one notification. A cursor (events.cursor, a line count) survives
# Monitor's 30-minute cap and re-arms: nothing is lost or repeated between runs,
# and events written while no dispatcher was listening are delivered on the next run.
#
# The watcher runs on its own (a tmux window), so re-arming this never restarts it
# and never asks 1Password for the API key again. When the watcher's process is gone,
# this prints one `tell:` line so the dispatcher can offer to restart it.
#
# --once   deliver what is new, then exit
# --reset  move the cursor to the end of events.log (skip old history), then exit

def count-lines [path: string] {
  if ($path | path exists) { open --raw $path | lines | length } else { 0 }
}

def watcher-alive [dir: string] {
  let pidfile = $"($dir)/watch.pid"
  if not ($pidfile | path exists) { return false }
  (do { ^ps -p (open --raw $pidfile | str trim) } | complete).exit_code == 0
}

def main [--once, --reset, --state-dir: string = "~/.claude/agent-workflow"] {
  let dir = ($state_dir | path expand)
  mkdir $dir
  let events = $"($dir)/events.log"
  let cursor_file = $"($dir)/events.cursor"
  if $reset {
    count-lines $events | into string | save --force $cursor_file
    return
  }
  mut warned = false
  loop {
    let cursor = if ($cursor_file | path exists) { open --raw $cursor_file | str trim | into int } else { 0 }
    let all = if ($events | path exists) { open --raw $events | lines } else { [] }
    let fresh = ($all | skip $cursor)
    for line in $fresh { print $line }
    if ($fresh | is-not-empty) { $all | length | into string | save --force $cursor_file }
    let alive = (watcher-alive $dir)
    if not $alive and not $warned {
      print "tell: the agent-workflow watcher is not running (see ~/.claude/agent-workflow/watch.log); /agent-workflow start restarts it"
      $warned = true
    }
    if $alive { $warned = false }
    if $once { break }
    sleep 2sec
  }
}
