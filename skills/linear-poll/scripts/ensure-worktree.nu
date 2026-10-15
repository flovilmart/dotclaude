#!/usr/bin/env nu
# ensure-worktree.nu <repo-path> <branch>
#
# Non-interactive sibling-worktree allocator. Prints the absolute path of a
# `<repo>-wt<N>` worktree checked out on <branch>:
#   1. a worktree already on <branch>, else
#   2. a free worktree (branch merged into the default branch, clean tree),
#      switched to <branch>, else
#   3. a new `<repo>-wt<N>` with the next index.
# <branch> is created from origin/<default> when it exists neither locally nor
# on origin. Layout matches the linear-ticket skill: ~/src/<org>/<repo>-wt<N>.

def checkout-branch [wt: string, branch: string, default_branch: string] {
  let local_exists = ((^git -C $wt branch --list $branch | str trim) != "")
  let remote_exists = ((^git -C $wt branch -r --list $"origin/($branch)" | str trim) != "")
  if $local_exists {
    ^git -C $wt switch --quiet $branch
  } else if $remote_exists {
    ^git -C $wt switch --quiet --track $"origin/($branch)"
  } else {
    ^git -C $wt switch --quiet -c $branch $"origin/($default_branch)"
  }
}

def main [repo_path: string, branch: string] {
  # Resolve the main checkout even when repo_path is itself a linked worktree
  let main_path = (^git -C $repo_path rev-parse --path-format=absolute --git-common-dir | str trim | path dirname)
  let repo_name = ($main_path | path basename)
  let parent = ($main_path | path dirname)

  try { ^git -C $main_path fetch origin --quiet --prune } catch { }

  let default_branch = (
    try {
      ^git -C $main_path symbolic-ref refs/remotes/origin/HEAD
        | str trim
        | str replace 'refs/remotes/origin/' ''
    } catch { "main" }
  )

  # Managed sibling worktrees: path, branch
  let rows = (
    ^git -C $main_path worktree list
    | lines
    | each {|line|
        let cols = ($line | str trim | split row ' ' | where {|c| $c != "" })
        let raw = ($cols | last)
        {
          path: $cols.0
          raw: $raw
          branch: ($raw | str replace --all '[' '' | str replace --all ']' '')
        }
      }
    | where {|r|
        # last column is "[branch]" for normal rows; bare, detached and prunable rows differ
        (
          (($r.path | path basename) | str starts-with $"($repo_name)-wt")
          and ($r.raw | str starts-with "[")
        )
      }
  )

  # 1. already checked out somewhere
  let same = ($rows | where branch == $branch)
  if ($same | length) > 0 {
    print ($same | first | get path)
    return
  }

  # 2. a free worktree: branch merged into origin/<default> and clean tree
  let merged = (
    ^git -C $main_path branch --merged $"origin/($default_branch)" --format '%(refname:short)'
    | lines
    | each {|b| $b | str trim }
  )
  let free = (
    $rows
    | where {|r|
        let is_merged = ($merged | any {|m| $m == $r.branch })
        let st = (do { ^git -C $r.path status --porcelain } | complete)
        let is_clean = (($st.exit_code == 0) and (($st.stdout | str trim) == ""))
        $is_merged and $is_clean
      }
  )
  if ($free | length) > 0 {
    let wt = ($free | first | get path)
    checkout-branch $wt $branch $default_branch
    print $wt
    return
  }

  # 3. create the next index
  mut idx = 1
  while ($"($parent)/($repo_name)-wt($idx)" | path exists) {
    $idx += 1
  }
  let wt = $"($parent)/($repo_name)-wt($idx)"
  let local_exists = ((^git -C $main_path branch --list $branch | str trim) != "")
  let remote_exists = ((^git -C $main_path branch -r --list $"origin/($branch)" | str trim) != "")
  if $local_exists {
    ^git -C $main_path worktree add --quiet $wt $branch
  } else if $remote_exists {
    ^git -C $main_path worktree add --quiet --track -b $branch $wt $"origin/($branch)"
  } else {
    ^git -C $main_path worktree add --quiet -b $branch $wt $"origin/($default_branch)"
  }
  print $wt
}
