#!/usr/bin/env nu
# selftest.nu — offline checks for the linear-poll scripts.
#
# Builds a throwaway repo with a local "origin", then exercises
# ensure-worktree.nu (create, reuse, free-after-merge, worktree path as input,
# .worktreeinclude copy, ticket holds), profile-key.nu, pr-sweep.nu's branch → ticket parsing,
# config.nu, the poll rules (rules.nu) and watch.nu end to end with a fake claude,
# then runs the saved workflows' regression tests (workflows/test) when node is installed.
# No network, no Linear, no claude. Prints ok/FAIL per check; exit code 1 on failure.
#
# Fails first when nu is older than MIN_NU: nushell still renames flags and
# commands between releases, and these scripts are tested on MIN_NU and later.

const MIN_NU = [0 106 0]

# true when the running nu is at least `min` ([major minor patch])
def nu-at-least [min: list<int>] {
  let v = (version)
  let cur = [$v.major $v.minor $v.patch]
  let diff = ($cur | zip $min | each {|p| $p.0 - $p.1 } | where {|d| $d != 0 } | first 1)
  ($diff | is-empty) or ($diff.0 > 0)
}

use config.nu *
use rules.nu *
use linear.nu

def assert-eq [actual, expected, label: string] {
  if $actual == $expected {
    print $"  ok   ($label)"
  } else {
    print $"  FAIL ($label): expected '($expected)', got '($actual)'"
    error make { msg: $"selftest failed: ($label)" }
  }
}

# An issue as linear.nu returns it, with overrides
def issue [id: string, extra: record = {}] {
  {
    id: $"uuid-($id)", identifier: $id, title: "t", branchName: $"f/($id | str downcase)", priority: 2
    createdAt: "2026-10-01T00:00:00.000Z", updatedAt: "2026-10-01T00:00:00.000Z", state: "Todo"
    labels: [], project: null, parent: null, cycle: {isActive: true, isNext: false}, hasSpec: false, comments: null
  } | merge $extra
}

def pr [n: int, ticket: string, extra: record = {}] {
  {
    number: $n, url: $"https://gh/pr/($n)", branch: $"f/($ticket | str downcase)-s1", ticket: $ticket, state: "open"
    draft: false, ci: "pass", review: "REVIEW_REQUIRED", requested: ["bob"], autoMerge: false, updatedAt: "t1", mergedAt: ""
  } | merge $extra
}

def types [actions: list] { $actions | each {|a| $"($a.type) ($a.ticket)" } }

def git-commit [repo: string, msg: string] {
  ^git -C $repo -c user.name=selftest -c user.email=selftest@example.com commit --quiet --allow-empty -m $msg
}

def main [] {
  let skill_dir = ($env.CURRENT_FILE | path dirname)
  let ensure = $"($skill_dir)/ensure-worktree.nu"
  let sweep = $"($skill_dir)/pr-sweep.nu"
  let tmp = (^mktemp -d | str trim | path expand)
  let src = $"($tmp)/src"
  let origin = $"($tmp)/origin.git"
  let main = $"($tmp)/demo"

  print "nu"
  let min = ($MIN_NU | str join '.')
  if not (nu-at-least $MIN_NU) {
    print $"  FAIL nu (version | get version) is older than ($min): brew upgrade nushell"
    error make { msg: $"selftest failed: nu older than ($min)" }
  }
  print $"  ok   nu (version | get version) >= ($min)"

  print "setup"
  ^git init --quiet --initial-branch=main $src
  git-commit $src "init"
  ".env" | save $"($src)/.gitignore"
  ".env" | save $"($src)/.worktreeinclude"
  ^git -C $src add .gitignore .worktreeinclude
  git-commit $src "ignore and worktreeinclude"
  ^git clone --quiet --bare $src $origin
  ^git clone --quiet $origin $main
  "SECRET=1" | save $"($main)/.env"

  print "ensure-worktree.nu"
  let wt1 = (^nu $ensure $main feat/demo-1 | str trim)
  assert-eq $wt1 $"($tmp)/demo-wt1" "new branch gets demo-wt1"
  assert-eq (^git -C $wt1 branch --show-current | str trim) "feat/demo-1" "demo-wt1 is on feat/demo-1"
  assert-eq ($"($wt1)/.env" | path exists) true ".worktreeinclude copied .env into the new worktree"

  let again = (^nu $ensure $main feat/demo-1 | str trim)
  assert-eq $again $wt1 "same branch returns the same worktree"

  let wt2 = (^nu $ensure $main feat/demo-2 | str trim)
  assert-eq $wt2 $"($tmp)/demo-wt2" "second branch gets demo-wt2 while wt1 is busy"

  let from_wt = (^nu $ensure $wt2 feat/demo-2 | str trim)
  assert-eq $from_wt $wt2 "a worktree path works as repo_path"

  git-commit $wt1 "work on demo-1"
  ^git -C $wt1 push --quiet -u origin feat/demo-1
  ^git -C $main merge --quiet --ff-only feat/demo-1
  ^git -C $main push --quiet origin main
  let wt3 = (^nu $ensure $main feat/demo-3 | str trim)
  assert-eq $wt3 $wt1 "merged and clean worktree is reused"
  assert-eq (^git -C $wt1 branch --show-current | str trim) "feat/demo-3" "reused worktree switched to feat/demo-3"

  # wt1 (feat/demo-3) and wt2 (feat/demo-2) are fresh branches with no commits: never free
  let wt4 = (^nu $ensure $main feat/demo-4 | str trim)
  assert-eq $wt4 $"($tmp)/demo-wt3" "a fresh, never-pushed branch is not free"

  git-commit $wt1 "work on demo-3"
  ^git -C $wt1 push --quiet -u origin feat/demo-3
  ^git -C $main merge --quiet --ff-only feat/demo-3
  ^git -C $main push --quiet origin main
  "dirty" | save $"($wt1)/dirty.txt"
  let wt5 = (^nu $ensure $main feat/demo-5 | str trim)
  assert-eq $wt5 $"($tmp)/demo-wt4" "dirty worktree is not reused even when its branch is merged"
  ^rm -f $"($wt1)/dirty.txt"
  let wt6 = (^nu $ensure $main feat/demo-6 | str trim)
  assert-eq $wt6 $wt1 "cleaned worktree is reused again"

  # remote branch deleted after merge (GitHub "delete head branches"): free even without a merge commit
  git-commit $wt2 "work on demo-2"
  ^git -C $wt2 push --quiet -u origin feat/demo-2
  ^git -C $wt2 push --quiet origin --delete feat/demo-2
  let wt7 = (^nu $ensure $main feat/demo-7 | str trim)
  assert-eq $wt7 $wt2 "worktree whose remote branch was deleted is free"

  # a worktree held by a ticket is not free, even once its branch is merged
  let held = (^nu $ensure $main feat/demo-8 --ticket DEMO-8 | str trim)
  assert-eq (open --raw (^git -C $held rev-parse --absolute-git-dir | str trim | path join agent-ticket) | str trim) "DEMO-8" "--ticket marks the worktree as held"
  assert-eq (^git -C $held status --porcelain | str trim) "" "the hold leaves the tree clean"
  git-commit $held "work on demo-8"
  ^git -C $held push --quiet -u origin feat/demo-8
  ^git -C $main merge --quiet --ff-only feat/demo-8
  ^git -C $main push --quiet origin main
  let other = (^nu $ensure $main feat/demo-9 | str trim)
  assert-eq ($other != $held) true "a held worktree is not given to another branch after its branch merges"
  let back = (^nu $ensure $main feat/demo-8-s2 --ticket DEMO-8 | str trim)
  assert-eq $back $held "the holding ticket gets its worktree back"
  assert-eq (^git -C $held branch --show-current | str trim) "feat/demo-8" "getting it back does not switch its branch"
  ^rm -f (^git -C $held rev-parse --absolute-git-dir | str trim | path join agent-ticket)
  let released = (^nu $ensure $main feat/demo-10 | str trim)
  assert-eq $released $held "a released worktree is free again"

  print "profile-key.nu"
  let pkey = $"($skill_dir)/profile-key.nu"
  let cache = $"($tmp)/profiles"
  let k1 = (^nu $pkey $main --dir $cache | from json)
  assert-eq $k1.fresh false "no cached profile yet"
  mkdir $cache
  $"<!-- profile-key: ($k1.key) -->\nREPO PROFILE" | save $k1.path
  assert-eq (^nu $pkey $main --dir $cache | from json | get fresh) true "cached profile with the current key is fresh"
  assert-eq (^nu $pkey $held --dir $cache | from json | get key) $k1.key "same key from a worktree path"
  git-commit $main "unrelated commit"
  ^git -C $main push --quiet origin main
  assert-eq (^nu $pkey $main --dir $cache | from json | get fresh) true "an unrelated commit keeps the profile fresh"
  "# rules" | save $"($main)/AGENTS.md"
  ^git -C $main add AGENTS.md
  git-commit $main "add AGENTS.md"
  ^git -C $main push --quiet origin main
  let k2 = (^nu $pkey $main --dir $cache | from json)
  assert-eq ($k2.key != $k1.key) true "changing AGENTS.md on the default branch changes the key"
  assert-eq $k2.fresh false "and makes the cached profile stale"

  print "pr-sweep.nu"
  assert-eq (^nu $sweep --parse-branch "florent/eng-123-add-thing-s2-schema" | str trim) "ENG-123" "ticket parsed from Linear-style branch"
  assert-eq (^nu $sweep --parse-branch "main" | str trim) "" "no ticket in main"

  print "config.nu"
  let cfg = (parse-config (open --raw $"($skill_dir)/../../agent-workflow/config.example.md"))
  assert-eq $cfg.max_parallel 3 "integers are parsed"
  assert-eq $cfg.auto_merge true "booleans are parsed"
  assert-eq $cfg.comment_marker "🤖 agent-workflow" "quotes are stripped"
  assert-eq ($cfg.reviewers? | default "absent") "absent" "an empty value with a comment is absent"
  assert-eq (resolve-repo $cfg.repos "Demo App" []) ("~/src/flovilmart/demo-app" | path expand) "repo by project"
  assert-eq (resolve-repo $cfg.repos null [infra]) ("~/src/flovilmart/infra" | path expand) "repo by label"
  assert-eq (resolve-repo $cfg.repos "Other" []) ("~/src/flovilmart/dotclaude" | path expand) "default repo"
  let ocfg = ($cfg | upsert linear_oauth_client_id "client-1")
  assert-eq (linear uses-oauth $cfg) false "API key auth when no OAuth client is configured"
  assert-eq (linear provider $ocfg | select client_id scope_sep port extra) {client_id: "client-1", scope_sep: ",", port: 8765, extra: {actor: "user"}} "Linear OAuth provider: public client on the loopback port, acting as the user"

  print "rules.nu"
  let now = ("2026-10-17T12:00:00Z" | into datetime)
  let busy = [{name: "DEMO-9", pid: 9, state: "working"}]
  let new = (decide $cfg $now [
    (issue DEMO-1 {priority: 3}) (issue DEMO-2 {priority: 1}) (issue DEMO-3 {priority: 0})
    (issue DEMO-5 {parent: "DEMO-9"}) (issue DEMO-6 {labels: [needs-spec]}) (issue DEMO-7 {cycle: {isActive: false, isNext: true}})
  ] $busy [] {})
  assert-eq (types $new.actions) ["dispatch DEMO-2" "dispatch DEMO-1" "queued DEMO-3"] "new tickets by priority within capacity; none-priority last; coordinator sub-issues, needs-spec and next cycle skipped"
  let exited = (decide $cfg $now [(issue DEMO-4)] [{name: "DEMO-4", pid: null, state: "done"}] [] {})
  assert-eq ($exited.actions.0 | select type msg) {type: wake, msg: "/ticket-workflow DEMO-4 dispatcher"} "a stopped coordinator of a Todo ticket is restarted"
  let cool = (decide $cfg $now [(issue DEMO-1)] [] [] {cooldown: {"DEMO-1": "2026-10-17T12:05:00Z"}})
  assert-eq $cool.actions [] "a ticket in cooldown gets no action"
  let later = (decide $cfg ($now + 10min) [(issue DEMO-1)] [] [] $cool.state)
  assert-eq (types $later.actions) ["dispatch DEMO-1"] "after the cooldown the ticket is acted on again"
  assert-eq $later.state.cooldown {} "and the ended cooldown is dropped"

  let q = {body: "🤖 agent-workflow · DEMO-6 · Plan for approval\n...", createdAt: "2026-10-02T00:00:00.000Z"}
  let waiting = (issue DEMO-6 {state: "In Progress", labels: [needs-plan-approval]})
  let live6 = [{name: "DEMO-6", pid: 6, state: "idle"}]
  assert-eq (comment-targets $cfg [$waiting (issue DEMO-1)] $live6 {}) ["DEMO-6"] "comments are fetched only where the rules need them"
  let unanswered = (decide $cfg $now [($waiting | upsert comments [$q])] $live6 [] {})
  assert-eq $unanswered.actions [] "an unanswered plan wakes nobody"
  let answered = ($waiting | upsert comments [$q {body: "approve", createdAt: "2026-10-02T01:00:00.000Z"}])
  let a1 = (decide $cfg $now [$answered] $live6 [] {})
  assert-eq ($a1.actions.0.msg) "Reply on the plan for DEMO-6: approve or revise, and continue /ticket-workflow" "an answered plan wakes its coordinator"
  assert-eq (decide $cfg $now [$answered] $live6 [] $a1.state | get actions) [] "and only once"
  let spec_q = {body: "🤖 agent-workflow · DEMO-8 · Clarifications needed\n1. ?", createdAt: "2026-10-02T00:00:00.000Z"}
  let edited = (issue DEMO-8 {state: "In Progress", labels: [needs-spec], hasSpec: true, updatedAt: "2026-10-03T00:00:00.000Z", comments: [$spec_q]})
  assert-eq (decide $cfg $now [$edited] [{name: "DEMO-8", pid: 8, state: "idle"}] [] {} | get actions | types $in) ["wake DEMO-8"] "a ## Spec edited after the questions counts as an answer"

  let p1 = (decide $cfg $now [] $live6 [(pr 7 DEMO-6 {ci: "fail"}) (pr 8 "") (pr 9 DEMO-99 {ci: "fail"})] {})
  assert-eq ($p1.actions | select type ticket msg) [{type: wake, ticket: "DEMO-6", msg: "PR #7 (f/demo-6-s1): CI failing"}] "PR events only for tickets with a coordinator"
  let p2 = (decide $cfg $now [] $live6 [(pr 7 DEMO-6 {ci: "fail", updatedAt: "t2"})] $p1.state)
  assert-eq $p2.actions.0.msg "PR #7: new activity, check comments" "the same failure is not repeated; a change without a new condition is activity"
  let p3 = (decide $cfg $now [] $live6 [(pr 7 DEMO-6 {ci: "pass", requested: [], review: "REVIEW_REQUIRED", updatedAt: "t3"})] $p2.state)
  assert-eq $p3.actions.0.msg "PR #7: out of draft, nobody requested (validated by the owner, or a comment-only review)" "owner validation is reported"
  let held = (decide $cfg $now [] $live6 [(pr 7 DEMO-6 {state: "merged", mergedAt: "m"})] ($p3.state | upsert cooldown {"DEMO-6": "2026-10-17T12:05:00Z"}))
  assert-eq ($held.actions | length) 0 "PR events wait while the ticket is in cooldown"
  assert-eq ($held.state.prs | get "https://gh/pr/7" | get conds) [out-of-draft] "and stay unseen until then"

  let gone = {|n| issue DEMO-10 {state: "In Progress", comments: (1..$n | each {|i| {body: $"🤖 agent-workflow · DEMO-10 · redispatched \(($i)/3\)", createdAt: "2026-10-02T00:00:00.000Z"} })} }
  assert-eq (decide $cfg $now [(do $gone 1)] [] [] {} | get actions.0 | select type n) {type: redispatch, n: 2} "a dead coordinator is redispatched, counted from Linear comments"
  assert-eq (decide $cfg $now [(do $gone 3)] [] [] {} | get actions.0.type) "stall" "after max_redispatch it stalls"

  let gcfg = ($cfg | upsert pre_spec_next_cycle true)
  let next = {|id| issue $id {cycle: {isActive: false, isNext: true}, comments: []} }
  let g1 = (decide $gcfg $now [(do $next DEMO-11) (do $next DEMO-12) (do $next DEMO-13)] [] [] {})
  assert-eq (types $g1.actions) ["spec-gate DEMO-11" "spec-gate DEMO-12"] "early spec gate, at most two per cycle"
  assert-eq (decide $gcfg $now [(do $next DEMO-11) (do $next DEMO-12) (do $next DEMO-13)] [] [] $g1.state | get actions | types $in) ["spec-gate DEMO-13"] "each ticket once"

  print "watch.nu (fake claude, fixtures)"
  let bin = $"($tmp)/bin"
  mkdir $bin
  let agents = $"($tmp)/agents.json"
  '[{"kind":"background","name":"DEMO-6","id":"s6","state":"idle","pid":66,"sessionId":"sess-6","cwd":"/tmp"}]' | save $agents
  [
    "#!/bin/sh"
    "case \"$1\" in"
    "  agents) cat \"$FAKE_AGENTS\" ;;"
    "  --bg) echo \"backgrounded · fake1234 · $3\" ;;"
    "  --resume) echo resumed ;;"
    "esac"
  ] | str join "\n" | save $"($bin)/claude"
  ^chmod +x $"($bin)/claude"
  let wcfg = $"($tmp)/config.local.md"
  open --raw $"($skill_dir)/../../agent-workflow/config.example.md"
  | str replace --regex '\| default +\|[^\n]*' $"| default | ($main) |" | save $wcfg
  {
    issues: [(issue DEMO-1) $waiting]
    comments: {"DEMO-6": [$q {body: "approve", createdAt: "2026-10-02T01:00:00.000Z"}]}
    sessions: [{name: "DEMO-6", pid: 66, state: "idle"}]
    prs: [(pr 7 DEMO-6 {draft: true})]
  } | to json | save $"($tmp)/fixtures.json"
  let watch = $"($skill_dir)/watch.nu"
  let wstate = $"($tmp)/wstate"
  let run = {|| with-env {PATH: ($env.PATH | prepend $bin), FAKE_AGENTS: $agents} { ^nu $watch --once --config $wcfg --fixtures $"($tmp)/fixtures.json" --state-dir $wstate | lines } }
  let out1 = (do $run)
  assert-eq ($out1 | length) 2 "first run: two events"
  assert-eq ($out1.0 | str starts-with "info: dispatched DEMO-1 (demo-wt") true "a new ticket is dispatched into a worktree"
  assert-eq $out1.1 "send DEMO-6: Reply on the plan for DEMO-6: approve or revise, and continue /ticket-workflow" "the answer is relayed to the running coordinator"
  let saved = (open $"($wstate)/watch-state.json")
  assert-eq ($saved.cooldown | columns) ["DEMO-1"] "the dispatched ticket is in cooldown"
  assert-eq (do $run) [] "second run: nothing new, nothing printed"
  assert-eq ($"($wstate)/watch.log" | path exists) true "actions are logged"

  print "follow.nu"
  let follow = $"($skill_dir)/follow.nu"
  let deliver = {|| ^nu $follow --once --state-dir $wstate | lines }
  "999999" | save --force $"($wstate)/watch.pid"
  let f1 = (do $deliver)
  assert-eq ($f1 | first 2) $out1 "events the watcher wrote are delivered"
  assert-eq ($f1 | last | str starts-with "tell: the agent-workflow watcher is not running") true "a dead watcher is reported"
  $nu.pid | into string | save --force $"($wstate)/watch.pid"   # this process stands in for a live watcher
  assert-eq (do $deliver) [] "nothing is delivered twice"
  "send DEMO-6: later\n" | save --append $"($wstate)/events.log"
  assert-eq (do $deliver) ["send DEMO-6: later"] "new lines are delivered once, across runs"
  "info: old\n" | save --append $"($wstate)/events.log"
  ^nu $follow --reset --state-dir $wstate
  assert-eq (do $deliver) [] "--reset skips old history"

  ^rm -rf $tmp

  print "nu/ shared modules (run-tests.nu)"
  let nu_tests = (^nu ($skill_dir | path join ../../../nu/run-tests.nu | path expand) | complete)
  let nu_summary = ($nu_tests.stdout | lines | where {|l| $l =~ '^nu tests:' } | str join)
  if $nu_tests.exit_code != 0 { print ($nu_tests.stdout | lines | where {|l| $l =~ 'FAIL' } | str join "\n") }
  assert-eq $nu_tests.exit_code 0 $"oauth.nu: PKCE, loopback callback, refresh rotation, token store \(($nu_summary | str replace 'nu tests: ' '')\)"

  print "workflows (node --test)"
  let tests = ($skill_dir | path join ../../../workflows/test | path expand)
  if (which node | is-empty) {
    print "  skip node not installed"
  } else {
    let files = (glob $"($tests)/*.test.mjs")
    let out = (do { ^node --test ...$files } | complete)
    let summary = ($out.stdout | lines | where {|l| $l =~ '^# (pass|fail) ' } | str replace '# ' '' | str join ", ")
    assert-eq $out.exit_code 0 $"plan.js and subtask.js regression tests \(($summary)\)"
  }
  print "selftest: all passed"
}
