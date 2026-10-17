# inbox — the Claude sessions waiting on someone, and on what.
#
#   inbox                     running sessions waiting on someone, most urgent first, with `waiting`:
#                               needs input            a question for you (a comment to answer, a permission prompt)
#                               needs plan validation  the slice plan is posted in Linear for your approval
#                               draft ready            a draft PR waits for your validation
#                               waiting review         PRs are with a coworker (not on you)
#   inbox open                one new tmux window "inbox", split into a tiled pane per session waiting on you,
#                             attached (← detaches and closes the pane); outside tmux, attaches them one after another
#   inbox open --all          also the sessions waiting review
#   inbox open --windows      a tmux window per session instead
#   inbox open --dry-run      what it would open, without opening anything
#
# What a ticket waits on comes from the watcher's waiting.json (Linear labels and open PRs, refreshed every
# minute while it runs) and the coordinator's state file; a session Claude reports as blocked with neither
# is "needs input". A session already attached in a tmux pane isn't opened twice.
# Loaded at shell start by autoload.nu.

# rules.nu WAITS, most urgent first (copied, not imported: its config.nu needs the built-in `open`,
# which this module's `open` shadows; a test keeps the two equal)
export const WAITS = ["needs input" "needs plan validation" "draft ready" "waiting review"]

const STATE_DIR = "~/.claude/agent-workflow"

# What the watcher last saw each ticket wait on: {ticket: {waiting detail}}
# (`open` here is this module's command, so files are read with cat)
def watcher-waits [dir: string] {
  let p = ($dir | path join waiting.json)
  if not ($p | path exists) { return {} }
  try { ^cat $p | from json | get tickets | reduce --fold {} {|t, acc| $acc | upsert $t.ticket {waiting: $t.waiting, detail: $t.detail} } } catch { {} }
}

# The coordinator asked a question it is blocked on (state file: phase or a slice marked blocked)
def asked [dir: string, ticket: string] {
  let p = ($dir | path join state $"($ticket).md")
  if $ticket == "" or not ($p | path exists) { return false }
  ^cat $p | lines | any {|l| ($l =~ '^phase:\s*blocked') or ($l =~ '^\|.*\|\s*blocked\b[^|]*\|') }
}

def why [s: record, waits: record, dir: string] {
  let name = ($s.name? | default "")
  if (($s.waitingFor? | default "") =~ "permission") { return {waiting: "needs input", detail: "permission prompt"} }
  if (asked $dir $name) { return {waiting: "needs input", detail: "question in the session"} }
  let w = ($waits | get --optional $name)
  if $w != null { return $w }
  if $s.state? == "blocked" { return {waiting: "needs input", detail: ""} }
  null
}

# Running sessions waiting on someone, most urgent first, then oldest
export def main [--state-dir: string = $STATE_DIR] {
  let dir = ($state_dir | path expand)
  let waits = (watcher-waits $dir)
  ^claude agents --json
  | from json
  | where {|s| $s.pid? != null }
  | each {|s|
      let w = (why $s $waits $dir)
      if $w == null { [] } else { [{
        id: $s.id
        name: ($s.name? | default "")
        waiting: $w.waiting
        detail: $w.detail
        cwd: ($s.cwd | str replace $nu.home-dir "~")
        started: ($s.startedAt * 1_000_000 | into datetime)
        rank: ($WAITS | enumerate | where item == $w.waiting | get index.0)
      }] }
    }
  | flatten
  | sort-by rank started
  | reject rank
}

# tmux panes already running `claude attach <id>`, with that id
def attached-panes [] {
  ^tmux list-panes -a -F "#{pane_id}\t#{pane_start_command}"
  | lines
  | parse "{pane}\t{cmd}"
  | each {|p| {pane: $p.pane, id: ($p.cmd | str trim -c '"' | parse "claude attach {id}" | get id.0? | default "")} }
  | where id != ""
}

def title [s: record] { if $s.name == "" { $s.id } else { $s.name | str substring 0..23 } }

# One window "inbox" with a pane per session, labelled with its name and what it waits on in the pane border
def open-split [sessions: list] {
  let first = $sessions.0
  let ids = (^tmux new-window -P -F "#{window_id} #{pane_id}" -n inbox -c ($first.cwd | path expand) $"claude attach ($first.id)" | str trim | split row " ")
  let win = $ids.0
  ^tmux set-option -w -t $win pane-border-status top
  ^tmux set-option -w -t $win pane-border-format " #{@inbox} "
  ^tmux set-option -p -t $ids.1 @inbox $"(title $first) · ($first.waiting)"
  for s in ($sessions | skip 1) {
    let pane = (^tmux split-window -P -F "#{pane_id}" -t $win -c ($s.cwd | path expand) $"claude attach ($s.id)" | str trim)
    ^tmux set-option -p -t $pane @inbox $"(title $s) · ($s.waiting)"
    # re-tile after each split, so the window never runs out of room for the next pane
    ^tmux select-layout -t $win tiled
  }
  ^tmux select-pane -t $ids.1
}

# Open the sessions waiting on you: split in one tmux window (or a window each), or one after another outside tmux
export def open [--all, --windows, --dry-run, --state-dir: string = $STATE_DIR] {
  let waiting = (main --state-dir $state_dir | where {|s| $all or $s.waiting != "waiting review" })
  if ($waiting | is-empty) { print "Nothing is waiting on you."; return }
  let in_tmux = (($env.TMUX? | default "") != "")
  let attached = (if $in_tmux { attached-panes | get id } else { [] })
  let action = (if not $in_tmux { "attach" } else if $windows { "window" } else { "pane" })
  let plan = ($waiting | each {|s|
    {id: $s.id, name: $s.name, waiting: $s.waiting, cwd: $s.cwd, action: (if $s.id in $attached { "already open" } else { $action })}
  })
  if $dry_run { return $plan }
  if not $in_tmux {
    for s in $plan { print $"── (title $s) · ($s.waiting) \(($s.id)\) ──"; ^claude attach $s.id }
    return
  }
  let todo = ($plan | where action != "already open")
  if $windows {
    for s in $todo { ^tmux new-window -d -n (title $s) -c ($s.cwd | path expand) $"claude attach ($s.id)" }
    let first = (attached-panes | where id == $plan.0.id | get pane.0? | default null)
    if $first != null { ^tmux select-window -t $first }
  } else if ($todo | is-not-empty) {
    open-split $todo
  }
  print $"($todo | length) opened; ($plan | length) session\(s\) waiting on you."
}
