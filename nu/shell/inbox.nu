# inbox — the Claude sessions waiting on you.
#
#   inbox                 running sessions that need input (state "blocked" in `claude agents --json`)
#   inbox open            open each in its own tmux window, attached (← detaches and closes the window);
#                         outside tmux, attaches them one after another
#   inbox open --dry-run  what it would open, without opening anything
#
# A session already attached in a tmux window isn't opened twice; focus goes to the oldest waiting one.
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

# Open every session that needs input: a tmux window each, or one after another outside tmux
export def open [--dry-run] {
  let waiting = (main)
  if ($waiting | is-empty) { print "Nothing needs your input."; return }
  let in_tmux = (($env.TMUX? | default "") != "")
  let attached = (if $in_tmux { attached-panes | get id } else { [] })
  let plan = ($waiting | each {|s|
    {id: $s.id, name: $s.name, cwd: $s.cwd, action: (if not $in_tmux { "attach" } else if $s.id in $attached { "already open" } else { "window" })}
  })
  if $dry_run { return $plan }
  for s in $plan {
    let title = (if $s.name == "" { $s.id } else { $s.name | str substring 0..23 })
    match $s.action {
      "window" => { ^tmux new-window -d -n $title -c ($s.cwd | path expand) $"claude attach ($s.id)" }
      "attach" => { print $"── ($title) \(($s.id)\) ──"; ^claude attach $s.id }
      _ => {}
    }
  }
  if $in_tmux {
    let first = (attached-panes | where id == $plan.0.id | get pane.0? | default null)
    if $first != null { ^tmux select-window -t $first }
    print $"($plan | where action == window | length) window\(s\) opened; ($plan | length) session\(s\) need input."
  }
}
