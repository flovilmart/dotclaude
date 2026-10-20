# Tests for rules.nu: the poll's decisions, from fixtures.
use std/testing *
use std/assert
use ../config.nu *
use ../rules.nu *

const HERE = path self .
def cfg [] { load-config ($HERE | path join ../../../agent-workflow/config.example.yaml) }
def now [] { "2026-10-17T12:00:00Z" | into datetime }

# An issue as linear.nu returns it, with overrides
def issue [id: string, extra: record = {}] {
  {
    id: $"uuid-($id)", identifier: $id, title: "t", branchName: $"f/($id | str lowercase)", priority: 2
    createdAt: "2026-10-01T00:00:00.000Z", updatedAt: "2026-10-01T00:00:00.000Z", state: "Todo"
    labels: [], project: null, parent: null, cycle: {isActive: true, isNext: false}, hasSpec: false, comments: null
  } | merge $extra
}

def pr [n: int, ticket: string, extra: record = {}] {
  {
    number: $n, url: $"https://gh/pr/($n)", branch: $"f/($ticket | str lowercase)-s1", ticket: $ticket, state: "open"
    draft: false, ci: "pass", review: "REVIEW_REQUIRED", requested: ["bob"], autoMerge: false, updatedAt: "t1", mergedAt: ""
  } | merge $extra
}

def types [actions: list] { $actions | each {|a| $"($a.type) ($a.ticket)" } }
def live [ticket: string] { [{name: $ticket, pid: 1, state: "idle"}] }

def plan-question [] { {body: "🤖 agent-workflow · DEMO-6 · Plan for approval\n...", createdAt: "2026-10-02T00:00:00.000Z"} }
def waiting-plan [comments: list] { issue DEMO-6 {state: "In Progress", labels: [needs-plan-approval], comments: $comments} }
def approve [] { {body: "approve", createdAt: "2026-10-02T01:00:00.000Z"} }

@test
def "new tickets go by priority within capacity and none-priority last" [] {
  let r = (decide (cfg) (now) [
    (issue DEMO-1 {priority: 3}) (issue DEMO-2 {priority: 1}) (issue DEMO-3 {priority: 0})
  ] [{name: "DEMO-9", pid: 9, state: "working"}] [] {})
  assert equal (types $r.actions) ["dispatch DEMO-2" "dispatch DEMO-1" "queued DEMO-3"]
}

@test
def "sub-issues of a coordinator and needs-spec or next-cycle tickets are not dispatched" [] {
  let r = (decide (cfg) (now) [
    (issue DEMO-5 {parent: "DEMO-9"}) (issue DEMO-6 {labels: [needs-spec]}) (issue DEMO-7 {cycle: {isActive: false, isNext: true}})
  ] (live DEMO-9) [] {})
  assert equal $r.actions []
}

@test
def "a stopped coordinator of a Todo ticket is restarted" [] {
  let r = (decide (cfg) (now) [(issue DEMO-4)] [{name: "DEMO-4", pid: null, state: "done"}] [] {})
  assert equal ($r.actions.0 | select type msg) {type: wake, msg: "/ticket-workflow DEMO-4 dispatcher"}
}

@test
def "a ticket in cooldown gets no action until the cooldown ends" [] {
  let cooling = (decide (cfg) (now) [(issue DEMO-1)] [] [] {cooldown: {"DEMO-1": "2026-10-17T12:05:00Z"}})
  assert equal $cooling.actions []
  let later = (decide (cfg) ((now) + 10min) [(issue DEMO-1)] [] [] $cooling.state)
  assert equal (types $later.actions) ["dispatch DEMO-1"]
  assert equal $later.state.cooldown {}
}

@test
def "comments are fetched only where the rules need them" [] {
  assert equal (comment-targets (cfg) [(waiting-plan []) (issue DEMO-1)] (live DEMO-6) {}) ["DEMO-6"]
}

@test
def "an unanswered plan wakes nobody" [] {
  assert equal (decide (cfg) (now) [(waiting-plan [(plan-question)])] (live DEMO-6) [] {} | get actions) []
}

@test
def "an answered plan wakes its coordinator once" [] {
  let first = (decide (cfg) (now) [(waiting-plan [(plan-question) (approve)])] (live DEMO-6) [] {})
  assert equal $first.actions.0.msg "Reply on the plan for DEMO-6: approve or revise, and continue /ticket-workflow"
  assert equal (decide (cfg) (now) [(waiting-plan [(plan-question) (approve)])] (live DEMO-6) [] $first.state | get actions) []
}

@test
def "a spec section edited after the questions counts as an answer" [] {
  let q = {body: "🤖 agent-workflow · DEMO-8 · Clarifications needed\n1. ?", createdAt: "2026-10-02T00:00:00.000Z"}
  let edited = (issue DEMO-8 {state: "In Progress", labels: [needs-spec], hasSpec: true, updatedAt: "2026-10-03T00:00:00.000Z", comments: [$q]})
  assert equal (decide (cfg) (now) [$edited] (live DEMO-8) [] {} | get actions | types $in) ["wake DEMO-8"]
}

@test
def "PR events go only to tickets with a coordinator" [] {
  let r = (decide (cfg) (now) [] (live DEMO-6) [(pr 7 DEMO-6 {ci: "fail"}) (pr 8 "") (pr 9 DEMO-99 {ci: "fail"})] {})
  assert equal ($r.actions | select type ticket msg) [{type: wake, ticket: "DEMO-6", msg: "PR #7 (f/demo-6-s1): CI failing"}]
}

@test
def "a PR condition is reported once and later changes are activity" [] {
  let first = (decide (cfg) (now) [] (live DEMO-6) [(pr 7 DEMO-6 {ci: "fail"})] {})
  let again = (decide (cfg) (now) [] (live DEMO-6) [(pr 7 DEMO-6 {ci: "fail", updatedAt: "t2"})] $first.state)
  assert equal $again.actions.0.msg "PR #7: new activity, check comments"
}

@test
def "owner validation is reported" [] {
  let r = (decide (cfg) (now) [] (live DEMO-6) [(pr 7 DEMO-6 {requested: []})] {})
  assert equal $r.actions.0.msg "PR #7: out of draft, nobody requested (validated by the owner, or a comment-only review)"
}

@test
def "PR events wait unseen while the ticket cools down" [] {
  let r = (decide (cfg) (now) [] (live DEMO-6) [(pr 7 DEMO-6 {state: "merged", mergedAt: "m"})] {cooldown: {"DEMO-6": "2026-10-17T12:05:00Z"}})
  assert equal $r.actions []
  assert equal $r.state.prs {}
}

@test
def "a dead coordinator is redispatched by Linear comment count then stalls" [] {
  let gone = {|n| issue DEMO-10 {state: "In Progress", comments: (1..$n | each {|i| {body: $"🤖 agent-workflow · DEMO-10 · redispatched \(($i)/3\)", createdAt: "2026-10-02T00:00:00.000Z"} })} }
  assert equal (decide (cfg) (now) [(do $gone 1)] [] [] {} | get actions.0 | select type n) {type: redispatch, n: 2}
  assert equal (decide (cfg) (now) [(do $gone 3)] [] [] {} | get actions.0.type) "stall"
}

@test
def "an in-progress sub-issue of a live coordinator is not redispatched" [] {
  let slice = (issue DEMO-14 {state: "In Progress", parent: "DEMO-9", comments: []})
  assert equal (comment-targets (cfg) [$slice] (live DEMO-9) {}) []
  assert equal (decide (cfg) (now) [$slice] (live DEMO-9) [] {} | get actions) []
  assert equal (decide (cfg) (now) [$slice] [] [] {} | get actions | types $in) ["redispatch DEMO-14"]
}

@test
def "the early spec gate runs at most two per cycle and each ticket once" [] {
  let gcfg = ((cfg) | upsert pre_spec_next_cycle true)
  let next = {|id| issue $id {cycle: {isActive: false, isNext: true}, comments: []} }
  let tickets = [(do $next DEMO-11) (do $next DEMO-12) (do $next DEMO-13)]
  let first = (decide $gcfg (now) $tickets [] [] {})
  assert equal (types $first.actions) ["spec-gate DEMO-11" "spec-gate DEMO-12"]
  assert equal (decide $gcfg (now) $tickets [] [] $first.state | get actions | types $in) ["spec-gate DEMO-13"]
}

@test
def "ticket waits name what each ticket is waiting on" [] {
  let issues = [
    (issue DEMO-1 {labels: [needs-spec]})
    (issue DEMO-2 {labels: [needs-plan-approval]})
    (issue DEMO-3)
    (issue DEMO-4)
    (issue DEMO-5)
  ]
  let prs = [
    (pr 3 DEMO-3 {draft: true})
    (pr 4 DEMO-4)
    (pr 5 DEMO-5 {review: "APPROVED"})
    (pr 6 DEMO-5 {state: "merged"})
  ]
  assert equal (ticket-waits (cfg) $issues $prs) [
    {ticket: DEMO-1, waiting: "needs input", detail: "clarifications on DEMO-1 in Linear"}
    {ticket: DEMO-2, waiting: "needs plan validation", detail: "plan on DEMO-2 in Linear"}
    {ticket: DEMO-3, waiting: "draft ready", detail: "https://gh/pr/3"}
    {ticket: DEMO-4, waiting: "waiting review", detail: "https://gh/pr/4"}
  ]
}

@test
def "ticket waits keep the most urgent and count sub-issues for their parent" [] {
  let issues = [(issue DEMO-1) (issue DEMO-9 {parent: DEMO-1, labels: [needs-spec]})]
  let prs = [(pr 1 DEMO-1) (pr 2 DEMO-1 {draft: true}) (pr 3 DEMO-1 {draft: true}) (pr 4 DEMO-2) (pr 5 DEMO-2 {draft: true})]
  assert equal (ticket-waits (cfg) $issues $prs) [
    {ticket: DEMO-1, waiting: "needs input", detail: "clarifications on DEMO-9 in Linear"}
    {ticket: DEMO-2, waiting: "draft ready", detail: "https://gh/pr/5"}
  ]
}
