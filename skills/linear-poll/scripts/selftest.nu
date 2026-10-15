#!/usr/bin/env nu
# selftest.nu — offline checks for the linear-poll scripts.
#
# Builds a throwaway repo with a local "origin", then exercises
# ensure-worktree.nu (create, reuse, free-after-merge, worktree path as input,
# .worktreeinclude copy) and pr-sweep.nu's branch → ticket parsing.
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
  let tmp = (^mktemp -d | str trim)
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

  "dirty" | save $"($wt1)/dirty.txt"
  let wt4 = (^nu $ensure $main feat/demo-4 | str trim)
  assert-eq $wt4 $"($tmp)/demo-wt3" "dirty worktree is not reused"

  print "pr-sweep.nu"
  assert-eq (^nu $sweep --parse-branch "florent/eng-123-add-thing-s2-schema" | str trim) "ENG-123" "ticket parsed from Linear-style branch"
  assert-eq (^nu $sweep --parse-branch "main" | str trim) "" "no ticket in main"

  ^rm -rf $tmp
  print "selftest: all passed"
}
