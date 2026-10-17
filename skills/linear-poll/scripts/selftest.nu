#!/usr/bin/env nu
# selftest.nu — offline checks for the linear-poll scripts.
#
# Builds a throwaway repo with a local "origin", then exercises
# ensure-worktree.nu (create, reuse, free-after-merge, worktree path as input,
# .worktreeinclude copy, ticket holds), profile-key.nu, pr-sweep.nu's branch → ticket parsing,
# watch.nu and follow.nu end to end with a fake claude; then the @test files (nu/run-tests.nu:
# oauth, the test runner, the poll rules, config) and the saved workflows' tests,
# then runs the saved workflows' regression tests (workflows/test) when node is installed.
# No network, no Linear, no claude. Prints ok/FAIL per check; exit code 1 on failure.
#
# Fails first when nu is older than MIN_NU: nushell still renames flags and
# commands between releases, and these scripts are tested on MIN_NU and later.

const MIN_NU = [0 111 0]   # tui.nu needs input listen --timeout (0.111); CI tests this and the latest release

# true when the running nu is at least `min` ([major minor patch])
def nu-at-least [min: list<int>] {
  let v = (version)
  let cur = [$v.major $v.minor $v.patch]
  let diff = ($cur | zip $min | each {|p| $p.0 - $p.1 } | where {|d| $d != 0 } | first 1)
  ($diff | is-empty) or ($diff.0 > 0)
}


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

  print "watch.nu (fake claude, fixtures)"
  let q = {body: "🤖 agent-workflow · DEMO-6 · Plan for approval\n...", createdAt: "2026-10-02T00:00:00.000Z"}
  let waiting = (issue DEMO-6 {state: "In Progress", labels: [needs-plan-approval]})
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

  print "nu tests (@test files in nu/tests and skills/*/scripts/tests, run-tests.nu)"
  let nu_tests = (^nu ($skill_dir | path join ../../../nu/run-tests.nu | path expand) | complete)
  let nu_summary = ($nu_tests.stdout | lines | where {|l| $l =~ '^nu tests:' } | str join)
  if $nu_tests.exit_code != 0 { print ($nu_tests.stdout | lines | where {|l| $l =~ 'FAIL' } | str join "\n") }
  assert-eq $nu_tests.exit_code 0 $"oauth, test runner, poll rules, config, syntax of every .nu file \(($nu_summary | str replace 'nu tests: ' '')\)"

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
