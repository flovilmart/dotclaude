#!/usr/bin/env nu
# tui.nu [--log <path>] [--window <all|30d|7d|24h|1h>] [--refresh <duration>] [--once]
#
# Terminal dashboard over ~/.claude/agent-workflow/log.jsonl (written by
# hooks/agent-log.sh). Same data as report.nu, browsable and live-refreshing.
#
#   1-6 / tab / h l   switch view       j k / ↑ ↓   scroll
#   w                 cycle time window  r           reload now
#   q / esc           quit
#
# --once prints every view to stdout and exits (no TTY needed).

const VIEWS = [overview agents worktrees timeline recent running]
const WINDOWS = [all 30d 7d 24h 1h]

# ── data ────────────────────────────────────────────────────────────────────

def load [path: string, window: string] {
  let raw = if ($path | path exists) { open --raw $path | lines | where {|l| ($l | str trim) != "" } } else { [] }
  # Concurrent hook writes can interleave lines; skip what does not parse.
  let parsed = ($raw | each {|l| try { $l | from json } catch { null } } | compact)
  let span = {"30d": 30day, "7d": 7day, "24h": 24hr, "1h": 1hr} | get --optional $window
  let cutoff = if $span == null { null } else { (date now) - $span }
  let all = (
    $parsed
    | where {|e| ($e | describe | str starts-with "record") and ($e.event? | describe | str starts-with "record") }
    | each {|e|
        let ev = $e.event
        let tickets = (
          $ev.background_tasks? | default [] | each {|t| $t.description? | default "" }
          | str join " " | parse --regex '(?<t>\b[A-Z]{2,}-\d+\b)' | get t | uniq
        )
        {
          ts: ($e.ts | into datetime)
          kind: ($ev.hook_event_name? | default "?")
          agent_id: ($ev.agent_id? | default "")
          agent: ($ev.agent_type? | default "")
          worktree: ($ev.cwd? | default "" | path basename)
          session: ($ev.session_id? | default "")
          msg: ($ev.last_assistant_message? | default "" | str replace --all --regex '\s+' ' ')
          tickets: $tickets
        }
      }
    | sort-by ts
  )

  # Pair each stop with the latest start of the same agent id. Resumed
  # subagents start again under the same id, so walk each id's events in order.
  # Stops with no start are turns of a session's main agent (e.g. a
  # ticket-coordinator), not subagent runs; they are only counted.
  let paired = (
    $all | where {|e| $e.agent_id != "" and $e.kind in [SubagentStart SubagentStop] }
    | group-by agent_id | values
    | each {|evs|
        $evs | reduce --fold {open: null, runs: [], orphans: 0} {|e, acc|
          if $e.kind == "SubagentStart" {
            $acc | update open $e
          } else if $acc.open == null {
            $acc | update orphans ($acc.orphans + 1)
          } else {
            let s = $acc.open
            $acc | update open null | update runs ($acc.runs | append {
              ts: $e.ts
              worktree: $e.worktree
              agent: ([$s.agent $e.agent "general-purpose"] | where {|a| $a != "" } | first)
              minutes: (($e.ts - $s.ts) / 1min)
              tickets: $e.tickets
              msg: $e.msg
            })
          }
        }
      }
  )
  let in_window = {|ts| $cutoff == null or $ts >= $cutoff }
  let events = ($all | where {|e| do $in_window $e.ts })
  let runs = ($paired | get runs | flatten | where {|r| do $in_window $r.ts } | sort-by ts)
  let running = (
    $paired | get open | compact
    | each {|s| {
        started: $s.ts
        age_min: (((date now) - $s.ts) / 1min)
        worktree: $s.worktree
        agent: (if $s.agent == "" { "general-purpose" } else { $s.agent })
        agent_id: $s.agent_id
      } }
    | sort-by started --reverse
  )
  {
    path: $path
    window: $window
    loaded: (date now)
    lines: ($raw | length)
    bad: (($raw | length) - ($parsed | length))
    orphans: ($paired | get orphans | sum0)
    events: $events
    runs: $runs
    running: $running
  }
}

# ── formatting helpers ──────────────────────────────────────────────────────

# math sum / math max reject empty input; an empty window is normal here.
def sum0 [] { let xs = $in; if ($xs | is-empty) { 0 } else { $xs | math sum } }
def max0 [] { let xs = $in; if ($xs | is-empty) { 0 } else { $xs | math max } }

def fmt-min [m] {
  if $m == null { return "—" }
  if $m < 1 { return $"(($m * 60) | math round)s" }
  if $m < 60 { return $"($m | math round --precision 1)m" }
  let h = ($m / 60 | math floor)
  $"($h)h(($m - $h * 60) | math round | fill -a r -c '0' -w 2)m"
}

def bar [v, max, width: int] {
  let n = if $max == null or $max <= 0 or $v == null { 0 } else { ($v / $max * $width) | math round | into int }
  if $n <= 0 { "" } else { "" | fill -c '█' -w $n }
}

def spark [values: list] {
  let ticks = ["▁" "▂" "▃" "▄" "▅" "▆" "▇" "█"]
  let max = ($values | math max)
  $values | each {|v| if $max == 0 or $v == 0 { " " } else { $ticks | get ((($v / $max) * 7) | math round | into int) } } | str join
}

def cut [s: string, w: int] {
  if ($s | str length) <= $w { $s } else if $w <= 1 { $s | str substring 0..<$w } else { ($s | str substring 0..<($w - 1)) + "…" }
}

def col [s, w: int, --right (-r)] {
  let t = (cut ($s | into string) $w)
  if $right { $t | fill -a r -w $w } else { $t | fill -a l -w $w }
}

def heading [s: string] { $"(ansi cyan_bold)($s)(ansi reset)" }
def dim [s: string] { $"(ansi dark_gray)($s)(ansi reset)" }

def stats-by [runs: list, key: string] {
  $runs | group-by --to-table {|r| $r | get $key } | each {|g|
    let mins = ($g.items | get minutes | compact)
    {
      key: ($g.items.0 | get $key)
      runs: ($g.items | length)
      avg: (if ($mins | is-empty) { null } else { $mins | math avg })
      p50: (if ($mins | is-empty) { null } else { $mins | math median })
      max: (if ($mins | is-empty) { null } else { $mins | math max })
      total: (if ($mins | is-empty) { 0 } else { $mins | math sum })
      last: ($g.items | get ts | math max)
      items: $g.items
    }
  }
}

# ── views (each returns a list of lines) ────────────────────────────────────

def view-overview [d, w: int] {
  let total = ($d.runs | get minutes | compact | sum0)
  let worktrees = ($d.runs | get worktree | uniq | length)
  let sessions = ($d.events | get session | uniq | length)
  let tickets = ($d.runs | get tickets | flatten | uniq)
  let span = if ($d.events | is-empty) { "—" } else {
    let a = ($d.events | get ts | math min | format date "%m-%d %H:%M")
    let b = ($d.events | get ts | math max | format date "%m-%d %H:%M")
    $"($a) → ($b)"
  }
  let kpis = [
    [label value];
    ["completed runs" ($d.runs | length)]
    ["running now" ($d.running | where age_min < 120 | length)]
    ["agent time" (fmt-min $total)]
    ["worktrees" $worktrees]
    ["sessions" $sessions]
    ["tickets seen" ($tickets | length)]
    ["main-agent turns" $d.orphans]
    ["events" ($d.events | length)]
    ["span" $span]
  ]
  let by_kind = ($d.events | group-by kind | transpose kind items | each {|r| {kind: $r.kind, n: ($r.items | length)} } | sort-by n --reverse)
  let agents = (stats-by $d.runs agent | sort-by total --reverse | first 8)
  let amax = ($agents | get total | max0)
  let bw = ([($w - 36) 10] | math max)
  [
    (heading "Totals")
    ...($kpis | each {|k| $"  (col $k.label 18)(ansi white_bold)($k.value)(ansi reset)" })
    ""
    (heading "Agent time by type")
    ...($agents | each {|a| $"  (col $a.key 20) (col (fmt-min $a.total) 8 -r) (ansi green)(bar $a.total $amax $bw)(ansi reset)" })
    ""
    (heading "Events by hook")
    ...($by_kind | each {|k| $"  (col $k.kind 20) (col $k.n 6 -r)" })
    ...(if ($tickets | is-empty) { [] } else { ["" (heading "Tickets") $"  (cut ($tickets | sort | str join '  ') ($w - 4))"] })
  ]
}

def view-agents [d, w: int] {
  let rows = (stats-by $d.runs agent | sort-by total --reverse)
  let max = ($rows | get total | max0)
  let bw = ([($w - 72) 8] | math max)
  [
    $"(ansi white_bold)(col 'agent' 22)(col 'runs' 6 -r)(col 'avg' 9 -r)(col 'p50' 9 -r)(col 'max' 9 -r)(col 'total' 9 -r)  share(ansi reset)"
    ...($rows | each {|r|
      $"(col $r.key 22)(col $r.runs 6 -r)(col (fmt-min $r.avg) 9 -r)(col (fmt-min $r.p50) 9 -r)(col (fmt-min $r.max) 9 -r)(col (fmt-min $r.total) 9 -r)  (ansi green)(bar $r.total $max $bw)(ansi reset)"
    })
    ""
    (dim "Many implementer + code-challenger runs per worktree = review churn; many verifier runs = fast checks miss what CI catches.")
  ]
}

def view-worktrees [d, w: int] {
  let rows = (stats-by $d.runs worktree | sort-by last --reverse)
  $rows | each {|r|
    let tickets = ($r.items | get tickets | flatten | uniq | str join " ")
    let per_agent = (
      $r.items | group-by agent | transpose agent items
      | each {|a| {agent: $a.agent, n: ($a.items | length)} } | sort-by n --reverse
      | each {|a| $"($a.agent)×($a.n)" } | str join "  "
    )
    [
      $"(ansi yellow_bold)(col $r.key 24)(ansi reset) (col $r.runs 4 -r) runs  (col (fmt-min $r.total) 8 -r)  last ($r.last | format date '%m-%d %H:%M')  (ansi magenta)(cut $tickets 30)(ansi reset)"
      $"    (dim (cut $per_agent ($w - 6)))"
    ]
  } | flatten
}

def view-timeline [d, w: int] {
  if ($d.runs | is-empty) { return [(dim "no runs in window")] }
  let first = ($d.runs | get ts | math min)
  let hourly = ((date now) - $first) < 3day
  let fmt = if $hourly { "%m-%d %Hh" } else { "%Y-%m-%d" }
  let buckets = (
    $d.runs | group-by {|r| $r.ts | format date $fmt } | transpose bucket items
    | each {|b| {bucket: $b.bucket, n: ($b.items | length), mins: ($b.items | get minutes | compact | sum0)} }
    | sort-by bucket
  )
  let max = ($buckets | get mins | math max)
  let bw = ([($w - 34) 10] | math max)
  [
    $"(heading (if $hourly { 'Agent time per hour' } else { 'Agent time per day' }))  (spark ($buckets | get mins))"
    ""
    ...($buckets | each {|b| $"  (col $b.bucket 12) (col $b.n 4 -r) runs (col (fmt-min $b.mins) 8 -r) (ansi blue)(bar $b.mins $max $bw)(ansi reset)" })
  ]
}

def view-recent [d, w: int] {
  let mw = ([($w - 62) 10] | math max)
  [
    $"(ansi white_bold)(col 'finished' 13)(col 'worktree' 18)(col 'agent' 20)(col 'took' 8 -r)  tickets in flight · message(ansi reset)"
    ...($d.runs | reverse | each {|r|
      let note = ([($r.tickets | str join ' ') $r.msg] | where {|s| $s != "" } | str join " · ")
      $"(col ($r.ts | format date '%m-%d %H:%M') 13)(col $r.worktree 18)(col $r.agent 20)(col (fmt-min $r.minutes) 8 -r)  (dim (cut $note $mw))"
    })
  ]
}

def view-running [d, w: int] {
  if ($d.running | is-empty) { return [(dim "nothing running")] }
  [
    $"(ansi white_bold)(col 'started' 13)(col 'age' 9 -r)  (col 'worktree' 20)(col 'agent' 22)id(ansi reset)"
    ...($d.running | each {|r|
      let line = $"(col ($r.started | format date '%m-%d %H:%M') 13)(col (fmt-min $r.age_min) 9 -r)  (col $r.worktree 20)(col $r.agent 22)($r.agent_id)"
      if $r.age_min > 120 { dim $line } else { $"(ansi green)●(ansi reset) ($line)" }
    })
    ""
    (dim "Starts with no matching stop. Greyed out after 2h: the session most likely died.")
  ]
}

def render-view [view: string, d, w: int] {
  match $view {
    "overview" => (view-overview $d $w)
    "agents" => (view-agents $d $w)
    "worktrees" => (view-worktrees $d $w)
    "timeline" => (view-timeline $d $w)
    "recent" => (view-recent $d $w)
    "running" => (view-running $d $w)
  }
}

# ── screen ──────────────────────────────────────────────────────────────────

def tabs [view: string] {
  $VIEWS | enumerate | each {|v|
    let label = $" ($v.index + 1) ($v.item) "
    if $v.item == $view { $"(ansi black_bold)(ansi --escape '46m')($label)(ansi reset)" } else { $label }
  } | str join ""
}

def draw [d, view: string, scroll: int] {
  let size = (term size)
  let w = $size.columns
  let h = $size.rows
  let body = (render-view $view $d $w)
  let room = ($h - 4)
  let max_scroll = ([(($body | length) - $room) 0] | math max)
  let scroll = ([$scroll $max_scroll] | math min)
  let visible = ($body | skip $scroll | first $room)
  let bad = if $d.bad > 0 { $"  (ansi red)($d.bad) bad lines(ansi reset)" } else { "" }
  let header = $"(ansi cyan_bold) agent-workflow stats (ansi reset)(tabs $view)  window (ansi yellow)($d.window)(ansi reset)($bad)"
  let more = if $max_scroll > 0 { $"  ($scroll + 1)-($scroll + ($visible | length))/($body | length)" } else { "" }
  let footer = (dim $" q quit · 1-6/tab view · j/k scroll · w window · r reload · ($d.loaded | format date '%H:%M:%S')($more)")
  let lines = [$header "" ...$visible]
  let pad = (0..<([($h - 1 - ($lines | length)) 0] | math max) | each { "" })
  let out = ([...$lines ...$pad $footer] | each {|l| $"($l)\e[K" } | str join "\n")
  print --no-newline $"\e[H($out)\e[J"
  $scroll
}

def main [
  --log: string = ""             # log path (default ~/.claude/agent-workflow/log.jsonl)
  --window: string = "all"       # all | 30d | 7d | 24h | 1h
  --refresh: duration = 5sec     # auto reload interval
  --once                         # print every view and exit
] {
  let path = if $log != "" { $log } else { $"($env.HOME)/.claude/agent-workflow/log.jsonl" }
  if $window not-in $WINDOWS { error make {msg: $"--window must be one of ($WINDOWS | str join ', ')"} }

  if $once {
    let d = (load $path $window)
    let w = (try { (term size).columns } catch { 120 })
    for v in $VIEWS {
      print (heading $"── ($v) ──")
      render-view $v $d $w | each {|l| print $l }
      print ""
    }
    return
  }

  mut view = "overview"
  mut window = $window
  mut scroll = 0
  mut d = (load $path $window)
  print --no-newline "\e[?1049h\e[?25l"
  try {
    loop {
      $scroll = (draw $d $view $scroll)
      # A timeout raises an error; treat it as the auto-refresh tick.
      let ev = (try { input listen --types [key resize] --timeout $refresh } catch { null })
      if $ev == null or ($ev.type? == null) {
        $d = (load $path $window)
        continue
      }
      if $ev.type == "resize" { continue }
      let k = ($ev.code? | default "")
      let idx = ($VIEWS | enumerate | where item == $view | get 0.index)
      if $k in ["q" "esc"] or ($k == "c" and "control" in ($ev.modifiers? | default [])) { break }
      if $k in ["1" "2" "3" "4" "5" "6"] { $view = ($VIEWS | get (($k | into int) - 1)); $scroll = 0 }
      if $k in ["tab" "right" "l"] { $view = ($VIEWS | get (($idx + 1) mod ($VIEWS | length))); $scroll = 0 }
      if $k in ["backtab" "left" "h"] { $view = ($VIEWS | get (($idx + ($VIEWS | length) - 1) mod ($VIEWS | length))); $scroll = 0 }
      if $k in ["j" "down"] { $scroll = $scroll + 1 }
      if $k in ["k" "up"] { $scroll = ([($scroll - 1) 0] | math max) }
      if $k in ["pagedown" " "] { $scroll = $scroll + 10 }
      if $k == "pageup" { $scroll = ([($scroll - 10) 0] | math max) }
      if $k in ["g" "home"] { $scroll = 0 }
      if $k == "w" {
        let wi = ($WINDOWS | enumerate | where item == $window | get 0.index)
        $window = ($WINDOWS | get (($wi + 1) mod ($WINDOWS | length)))
        $d = (load $path $window)
        $scroll = 0
      }
      if $k == "r" { $d = (load $path $window) }
    }
  } catch {|e|
    print --no-newline "\e[?25h\e[?1049l"
    error make {msg: $e.msg}
  }
  print --no-newline "\e[?25h\e[?1049l"
}
