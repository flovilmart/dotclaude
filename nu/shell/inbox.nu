# inbox — the Claude sessions waiting on you.
#
#   inbox                     running sessions that need input (state "blocked" in `claude agents --json`)
#   inbox open                one new tmux window "inbox", split into a tiled pane per session, attached
#                             (← detaches and closes the pane); outside tmux, attaches them one after another
#   inbox open --windows      a tmux window per session instead
#   inbox open --dry-run      what it would open, without opening anything
#
# A session already attached in a tmux pane isn't opened twice.
# Loaded at shell start by autoload.nu.

# Running sessions that need input, oldest first
export def main [] {
  ^claude agents --json
  | from json
  | where {|s| ($s.state? == "blocked") and ($s.pid? != null) }
  | sort-by startedAt
  | each {|s| {
      id: $s.id
      name: ($s.name? | default "")
      cwd: ($s.cwd | str replace $nu.home-dir "~")
      started: ($s.startedAt * 1_000_000 | into datetime)
    } }
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

# One window "inbox" with a pane per session, labelled with its name in the pane border
def open-split [sessions: list] {
  let first = $sessions.0
  let ids = (^tmux new-window -P -F "#{window_id} #{pane_id}" -n inbox -c ($first.cwd | path expand) $"claude attach ($first.id)" | str trim | split row " ")
  let win = $ids.0
  ^tmux set-option -w -t $win pane-border-status top
  ^tmux set-option -w -t $win pane-border-format " #{@inbox} "
  ^tmux set-option -p -t $ids.1 @inbox (title $first)
  for s in ($sessions | skip 1) {
    let pane = (^tmux split-window -P -F "#{pane_id}" -t $win -c ($s.cwd | path expand) $"claude attach ($s.id)" | str trim)
    ^tmux set-option -p -t $pane @inbox (title $s)
    # re-tile after each split, so the window never runs out of room for the next pane
    ^tmux select-layout -t $win tiled
  }
  ^tmux select-pane -t $ids.1
}

# Open every session that needs input: split in one tmux window (or a window each), or one after another outside tmux
export def open [--windows, --dry-run] {
  let waiting = (main)
  if ($waiting | is-empty) { print "Nothing needs your input."; return }
  let in_tmux = (($env.TMUX? | default "") != "")
  let attached = (if $in_tmux { attached-panes | get id } else { [] })
  let action = (if not $in_tmux { "attach" } else if $windows { "window" } else { "pane" })
  let plan = ($waiting | each {|s|
    {id: $s.id, name: $s.name, cwd: $s.cwd, action: (if $s.id in $attached { "already open" } else { $action })}
  })
  if $dry_run { return $plan }
  if not $in_tmux {
    for s in $plan { print $"── (title $s) \(($s.id)\) ──"; ^claude attach $s.id }
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
  print $"($todo | length) opened; ($plan | length) session\(s\) need input."
}
