#!/usr/bin/env nu
# report.nu [--since <iso8601>] [--log <path>]
#
# Turns ~/.claude/agent-workflow/log.jsonl (written by hooks/agent-log.sh) into
# per-worktree, per-agent metrics: how many times each worker ran (review and
# fix rounds show up as repeated implementer/code-challenger runs), average and
# total minutes per run, and failed runs if the hook reported them.
# Pass --since to limit to recent events (e.g. the last sprint).

def main [--since: string = "", --log: string = ""] {
  let path = if $log != "" { $log } else { $"($env.HOME)/.claude/agent-workflow/log.jsonl" }
  if not ($path | path exists) {
    print $"no log at ($path) yet \(hooks write it as agents run\)"
    return
  }
  let events = (
    open --raw $path
    | lines
    | where {|l| ($l | str trim) != "" }
    | each {|l| $l | from json }
    | where {|e| ($since == "") or (($e.ts | into datetime) > ($since | into datetime)) }
  )

  let starts = ($events | where {|e| ($e.event.hook_event_name? | default "") == "SubagentStart" })
  let stops = ($events | where {|e| ($e.event.hook_event_name? | default "") == "SubagentStop" })

  let runs = (
    $stops
    | each {|s|
        let id = ($s.event.agent_id? | default "")
        let start = ($starts | where {|x| ($x.event.agent_id? | default "-") == $id } | get 0?)
        let minutes = if $start == null { null } else {
          (($s.ts | into datetime) - ($start.ts | into datetime)) / 1min
        }
        {
          worktree: ($s.event.cwd? | default "" | path basename)
          agent: ($s.event.agent_type? | default ($start.event?.agent_type? | default "?"))
          minutes: $minutes
          ts: $s.ts
        }
      }
  )

  if ($runs | is-empty) {
    print "no completed subagent runs in range"
    return
  }

  $runs
  | group-by --to-table {|r| $"($r.worktree)|($r.agent)" }
  | each {|g|
      let items = $g.items
      let mins = ($items | get minutes | compact)
      {
        worktree: $items.0.worktree
        agent: $items.0.agent
        runs: ($items | length)
        avg_min: (if ($mins | is-empty) { null } else { $mins | math avg | math round --precision 1 })
        total_min: (if ($mins | is-empty) { null } else { $mins | math sum | math round --precision 1 })
        last: ($items | get ts | sort | last)
      }
    }
  | sort-by worktree agent
}
