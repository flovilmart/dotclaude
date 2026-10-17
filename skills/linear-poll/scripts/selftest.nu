#!/usr/bin/env nu
# selftest.nu — offline checks for the linear-poll scripts.
#
# Builds a throwaway repo with a local "origin", then exercises
# ensure-worktree.nu (create, reuse, free-after-merge, worktree path as input,
# .worktreeinclude copy, ticket holds) and pr-sweep.nu's branch → ticket parsing,
# then runs the saved workflows' regression tests (workflows/test) when node is installed.
# No network, no Linear, no claude. Prints ok/FAIL per check; exit code 1 on failure.

def assert-eq [actual, expected, label: string] {
  if $actual == $expected {
    print $"  ok   ($label)"
  } else {
    print $"  FAIL ($label): expected '($expected)', got '($actual)'"
    error make { msg: $"selftest failed: ($label)" }
  }
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

  print "pr-sweep.nu"
  assert-eq (^nu $sweep --parse-branch "florent/eng-123-add-thing-s2-schema" | str trim) "ENG-123" "ticket parsed from Linear-style branch"
  assert-eq (^nu $sweep --parse-branch "main" | str trim) "" "no ticket in main"

  ^rm -rf $tmp

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
