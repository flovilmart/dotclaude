# rules.nu — the poll's rules as pure functions: no network, no Linear, no claude.
#
# watch.nu gathers the inputs, calls `comment-targets` to know which issues need
# their comments fetched, then `decide`, and executes the actions it returns.
# selftest.nu feeds it fixtures.
#
# Inputs
#   cfg       config record (config.nu)
#   now       datetime of this cycle
#   issues    my open issues: {id identifier title branchName priority createdAt updatedAt
#             state labels project parent cycle: {isActive isNext} | null hasSpec
#             comments: [{body createdAt}] | null}   comments only for comment-targets
#   sessions  rows from sessions.nu: {name pid state ...}
#   prs       rows from pr-sweep.nu
#   state     what earlier cycles already did:
#             {nudged: {ID: question createdAt}, prs: {url: {conds updatedAt}},
#              specGated: [ID], cooldown: {ID: datetime string}}
#             cooldown is set by watch.nu after it dispatches or restarts a ticket:
#             no action for that ticket until then, so a slow start isn't retried every cycle
#
# Actions, one record each, `type` first:
#   dispatch    ticket repo branch                new ticket, within capacity
#   queued      ticket                            new ticket, over capacity
#   wake        ticket repo branch msg            deliver msg: running → send, exited → resume, none → dispatch
#   redispatch  ticket issueId repo branch n max  coordinator gone mid-ticket
#   stall       ticket issueId max                gone max times: label + comment, tell the human
#   spec-gate   ticket repo                       early spec gate for next cycle (needs the model)

use config.nu resolve-repo

# What a ticket can wait on, most urgent first (the first three are on the owner, the last on a coworker)
export const WAITS = ["needs input" "needs plan validation" "draft ready" "waiting review"]

def has-label [issue, label] { $label != null and ($label in $issue.labels) }
def session-of [sessions: list, ticket] { $sessions | where {|s| $s.name == $ticket } | get 0? }
def ts [v] { $v | into datetime }
def comments-of [issue] { $issue.comments? | default [] | sort-by {|c| ts $c.createdAt } }
def repo-of [cfg, issue] { resolve-repo $cfg.repos $issue.project? ($issue.labels? | default []) }

def waits [cfg] {
  [
    {label: $cfg.needs_spec_label?, question: "Clarifications needed", spec: true,
     msg: "Answers posted on {ID}: re-run the spec gate and continue /ticket-workflow"}
    {label: $cfg.needs_plan_label?, question: "Plan for approval", spec: false,
     msg: "Reply on the plan for {ID}: approve or revise, and continue /ticket-workflow"}
  ] | where {|w| $w.label != null }
}

def stale-candidate [cfg, issue, sessions: list] {
  ($issue.state == $cfg.in_progress_state
    and ($issue.cycle?.isActive? | default false)
    and not (has-label $issue $cfg.needs_spec_label?)
    and not (has-label $issue $cfg.needs_plan_label?)
    and not (has-label $issue $cfg.stalled_label?)
    and (session-of $sessions $issue.identifier) == null
    # A sub-issue is worked by its parent's coordinator; redispatching it forks the stack.
    and ($issue.parent? == null or (session-of $sessions $issue.parent) == null))
}

def gate-candidate [cfg, issue, state] {
  (($cfg.pre_spec_next_cycle? | default false)
    and ($issue.cycle?.isNext? | default false)
    and $issue.state == $cfg.todo_state
    and not $issue.hasSpec
    and not (has-label $issue $cfg.needs_spec_label?)
    and not ($issue.identifier in ($state.specGated? | default [])))
}

# Issues whose comments decide needs: waiting on a human answer, stale, or early-gate candidates.
export def comment-targets [cfg, issues: list, sessions: list, state] {
  $issues
  | where {|i|
      ((waits $cfg | any {|w| has-label $i $w.label })
        or (stale-candidate $cfg $i $sessions)
        or (gate-candidate $cfg $i $state))
    }
  | get identifier
}

# PR conditions worth a coordinator's turn, from one pr-sweep row
export def pr-conds [row] {
  let open = $row.state == "open"
  let requested = ($row.requested? | default [])
  [
    [cond, on];
    [ci-fail ($open and $row.ci == "fail")]
    [changes-requested ($open and $row.review == "CHANGES_REQUESTED")]
    [out-of-draft ($open and not $row.draft and ($requested | is-empty) and $row.review not-in [APPROVED CHANGES_REQUESTED])]
    [approved-green ($open and $row.review == "APPROVED" and $row.ci == "pass" and not $row.draft and not $row.autoMerge)]
    [merged ($row.state == "merged")]
  ] | where on | get cond
}

def pr-message [row, cond: string] {
  match $cond {
    "ci-fail" => $"PR #($row.number) \(($row.branch)\): CI failing"
    "changes-requested" => $"PR #($row.number): changes requested"
    "out-of-draft" => $"PR #($row.number): out of draft, nobody requested \(validated by the owner, or a comment-only review\)"
    "approved-green" => $"PR #($row.number): approved and green, enable auto-merge if config allows"
    "merged" => $"PR #($row.number) \(($row.branch)\): merged at ($row.mergedAt), sync the stack and close its sub-issue"
    "activity" => $"PR #($row.number): new activity, check comments"
  }
}

# Messages for one PR given what was last seen: only conditions that newly hold,
# or "new activity" when it changed without a new condition. First sight: conditions only.
export def pr-events [row, prev] {
  let conds = (pr-conds $row)
  let fresh = if $prev == null { $conds } else { $conds | where {|c| $c not-in $prev.conds } }
  let activity = ($prev != null and ($fresh | is-empty) and $row.state == "open" and $row.updatedAt != $prev.updatedAt)
  let msgs = ($fresh | each {|c| pr-message $row $c } | append (if $activity { [(pr-message $row "activity")] } else { [] }))
  {msgs: $msgs, seen: {conds: $conds, updatedAt: $row.updatedAt}}
}

export def decide [cfg, now: datetime, issues: list, sessions: list, prs: list, state] {
  let state = {
    nudged: ($state.nudged? | default {})
    prs: ($state.prs? | default {})
    specGated: ($state.specGated? | default [])
    cooldown: ($state.cooldown? | default {})
  }
  let marker = $cfg.comment_marker
  let dispatcher = ($cfg.dispatcher_name? | default "dispatcher")
  let cooling = ($state.cooldown | transpose ticket until | where {|c| (ts $c.until) > $now } | get ticket)

  # 1. New tickets in the current cycle, by priority (Linear 0 = none, sorts last), then age
  let todo = (
    $issues
    | where {|i| $i.state == $cfg.todo_state and ($i.cycle?.isActive? | default false) and not (has-label $i $cfg.needs_spec_label?) }
    | where {|i| $i.parent? == null or (session-of $sessions $i.parent) == null }
    | where {|i| $i.identifier not-in $cooling }
    | insert rank {|i| if ($i.priority? | default 0) == 0 { 5 } else { $i.priority } }
    | sort-by rank createdAt
  )
  let busy = ($sessions | where {|s| $s.pid != null and $s.state in [working blocked] } | length)
  let capacity = ([(($cfg.max_parallel? | default 3) - $busy) 0] | math max)
  let fresh = ($todo | where {|i| (session-of $sessions $i.identifier) == null })
  let exited = ($todo | where {|i| let s = (session-of $sessions $i.identifier); $s != null and $s.pid == null })
  let new_actions = (
    ($fresh | first $capacity | each {|i| {type: dispatch, ticket: $i.identifier, repo: (repo-of $cfg $i), branch: $i.branchName} })
    | append ($fresh | skip $capacity | each {|i| {type: queued, ticket: $i.identifier} })
    | append ($exited | each {|i| {type: wake, ticket: $i.identifier, repo: (repo-of $cfg $i), branch: $i.branchName, msg: $"/ticket-workflow ($i.identifier) ($dispatcher)"} })
  )

  # 2. Human answers to clarifications or to a plan, each question nudged once
  let answered = (
    $issues | reduce --fold {actions: [], nudged: $state.nudged} {|i, acc|
      let w = (waits $cfg | where {|w| has-label $i $w.label } | get 0?)
      if $w == null or $i.comments? == null or $i.identifier in $cooling { return $acc }
      let cs = (comments-of $i)
      let q = ($cs | where {|c| ($c.body | str starts-with $marker) and ($c.body | str contains $w.question) } | last 1 | get 0?)
      if $q == null { return $acc }
      let replied = ($cs | any {|c| (ts $c.createdAt) > (ts $q.createdAt) and not ($c.body | str starts-with $marker) })
      let spec_edited = ($w.spec and $i.hasSpec and (ts $i.updatedAt) > (ts $q.createdAt))
      let already = (($acc.nudged | get --optional $i.identifier) == $q.createdAt)
      if not ($replied or $spec_edited) or $already { return $acc }
      {
        actions: ($acc.actions | append {type: wake, ticket: $i.identifier, repo: (repo-of $cfg $i), branch: $i.branchName, msg: ($w.msg | str replace '{ID}' $i.identifier)})
        nudged: ($acc.nudged | upsert $i.identifier $q.createdAt)
      }
    }
  )

  # 3. PR events for tickets that have a coordinator session, one message per ticket.
  #    A ticket in cooldown keeps its PRs unseen, so their events arrive after it.
  let with_session = ($prs | where {|r| $r.ticket != "" and $r.ticket not-in $cooling and (session-of $sessions $r.ticket) != null })
  let pr_pass = (
    $with_session | reduce --fold {msgs: {}, seen: $state.prs} {|r, acc|
      let ev = (pr-events $r ($acc.seen | get --optional $r.url))
      let prior = ($acc.msgs | get --optional $r.ticket | default [])
      {
        msgs: (if ($ev.msgs | is-empty) { $acc.msgs } else { $acc.msgs | upsert $r.ticket ($prior | append $ev.msgs) })
        seen: ($acc.seen | upsert $r.url $ev.seen)
      }
    }
  )
  let pr_actions = (
    $pr_pass.msgs | transpose ticket msgs | each {|t|
      let issue = ($issues | where {|i| $i.identifier == $t.ticket } | get 0?)
      {type: wake, ticket: $t.ticket,
       repo: (if $issue == null { null } else { repo-of $cfg $issue }),
       branch: ($issue.branchName? | default null),
       msg: ($t.msgs | str join "; ")}
    }
  )

  # 4. Coordinators gone mid-ticket: redispatch up to max_redispatch, then stall
  let max = ($cfg.max_redispatch? | default 3)
  let stale_actions = (
    $issues
    | where {|i| (stale-candidate $cfg $i $sessions) and $i.comments? != null and $i.identifier not-in $cooling }
    | each {|i|
        let n = (comments-of $i | where {|c| $c.body | str starts-with $"($marker) · ($i.identifier) · redispatched" } | length)
        if $n < $max {
          {type: redispatch, ticket: $i.identifier, issueId: $i.id, repo: (repo-of $cfg $i), branch: $i.branchName, n: ($n + 1), max: $max}
        } else {
          {type: stall, ticket: $i.identifier, issueId: $i.id, max: $max}
        }
      }
  )

  # 5. Early spec gate for next cycle's tickets, at most two per cycle, once each
  let gate = (
    $issues
    | where {|i| (gate-candidate $cfg $i $state) and $i.comments? != null }
    | where {|i| not (comments-of $i | any {|c| $c.body | str starts-with $"($marker) · ($i.identifier) · Clarifications needed" }) }
    | first 2
  )
  let gate_actions = ($gate | each {|i| {type: spec-gate, ticket: $i.identifier, repo: (repo-of $cfg $i)} })

  {
    actions: ($new_actions | append $answered.actions | append $pr_actions | append $stale_actions | append $gate_actions)
    state: {
      nudged: $answered.nudged
      prs: $pr_pass.seen
      specGated: ($state.specGated | append ($gate | get identifier) | uniq)
      cooldown: ($state.cooldown | transpose ticket until | where {|c| (ts $c.until) > $now } | reduce --fold {} {|c, acc| $acc | upsert $c.ticket $c.until })
    }
  }
}

# What each ticket waits on, from its Linear labels and open PRs; one row per ticket, the most urgent
# of WAITS. A sub-issue counts for its parent (the coordinator is named after the parent).
#   needs input            clarifications asked in a Linear comment (needs_spec_label)
#   needs plan validation  the slice plan is posted for approval (needs_plan_label)
#   draft ready            a draft PR waits for the owner's validation
#   waiting review         PRs out of draft, not approved yet: a coworker's turn
# Rows: {ticket waiting detail}; detail is the PR urls, or where to answer in Linear.
export def ticket-waits [cfg, issues: list, prs: list] {
  let open = ($prs | where {|r| $r.state == "open" and $r.ticket != "" })
  $issues
  | each {|i|
      let t = ($i.parent? | default $i.identifier)
      if (has-label $i $cfg.needs_spec_label?) {
        [{ticket: $t, waiting: "needs input", detail: $"clarifications on ($i.identifier) in Linear"}]
      } else if (has-label $i $cfg.needs_plan_label?) {
        [{ticket: $t, waiting: "needs plan validation", detail: $"plan on ($i.identifier) in Linear"}]
      } else { [] }
    }
  | flatten
  | append ($open | where draft | each {|r| {ticket: $r.ticket, waiting: "draft ready", detail: $r.url} })
  | append ($open | where {|r| not $r.draft and $r.review != "APPROVED" } | each {|r| {ticket: $r.ticket, waiting: "waiting review", detail: $r.url} })
  | group-by ticket
  | items {|ticket, rows|
      let top = ($rows | insert rank {|r| $WAITS | enumerate | where item == $r.waiting | get index.0 } | sort-by rank | get 0.waiting)
      {ticket: $ticket, waiting: $top, detail: ($rows | where waiting == $top | get detail | uniq | str join " ")}
    }
  | sort-by ticket
}
