#!/usr/bin/env nu
# ensure-worktree.nu <repo-path> <branch> [--ticket <id>]
#
# Non-interactive sibling-worktree allocator. Prints the absolute path of a
# `<repo>-wt<N>` worktree checked out on <branch>:
#   1. a worktree already on <branch>, else
#   2. with --ticket, the worktree that ticket already holds (left on whatever
#      slice branch its coordinator had checked out), else
#   3. a free worktree, switched to <branch>: not held by a ticket, its tree is clean and its branch
#      is finished, meaning origin/<branch> is an ancestor of origin/<default>
#      (merged), or the branch once tracked origin/<branch> and that remote
#      branch is gone (GitHub deleted it after the merge). A fresh branch that
#      was never pushed is never free, even though it has no commits of its
#      own. Squash-merged branches become free once GitHub deletes them, so
#      enable "automatically delete head branches" on the repo. Else
#   4. a new `<repo>-wt<N>` with the next index.
# <branch> is created from origin/<default> when it exists neither locally nor
# on origin. Layout matches the linear-ticket skill: ~/src/<org>/<repo>-wt<N>.
#
# --ticket writes the ticket id to <worktree git dir>/agent-ticket (outside the
# working tree, so the tree stays clean). A coordinator keeps working in its
# worktree across slices, and a merged, clean slice branch must not make the
# worktree look free while the ticket has slices left. The coordinator deletes
# the file when the ticket is done:  rm -f "$(git rev-parse --absolute-git-dir)/agent-ticket"

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

# Copy gitignored files listed in <main>/.worktreeinclude (gitignore syntax,
# plain paths and * globs) into a freshly created worktree, like Claude Code
# does for the worktrees it creates itself.
def copy-worktreeinclude [main_path: string, wt: string] {
  let inc = $"($main_path)/.worktreeinclude"
  if not ($inc | path exists) { return }
  let patterns = (
    open --raw $inc
    | lines
    | each {|l| $l | str trim }
    | where {|l| ($l != "") and (not ($l | str starts-with "#")) and (not ($l | str starts-with "!")) }
  )
  for pat in $patterns {
    let clean = ($pat | str trim --left --char "/" | str replace --regex '/$' '/**')
    let matches = (try { do { cd $main_path; glob --no-dir $clean } } catch { [] } | default [])
    for src in $matches {
      let rel = ($src | path relative-to $main_path)
      let ignored = ((do { ^git -C $main_path check-ignore -q $rel } | complete).exit_code == 0)
      if $ignored {
        let dest = $"($wt)/($rel)"
        mkdir ($dest | path dirname)
        cp $src $dest
      }
    }
  }
}

def lock-file [wt: string] {
  $"(^git -C $wt rev-parse --absolute-git-dir | str trim)/agent-ticket"
}

# Ticket id holding the worktree, or "" when none
def holder [wt: string] {
  let f = (lock-file $wt)
  if ($f | path exists) { open --raw $f | str trim } else { "" }
}

def hold [wt: string, ticket: string] {
  if $ticket != "" { $ticket | save --force (lock-file $wt) }
}

# A branch is finished when its remote copy is merged into origin/<default>,
# or when it was pushed with upstream tracking and the remote copy is gone.
def branch-finished [main_path: string, branch: string, default_branch: string] {
  let remote_ref = $"refs/remotes/origin/($branch)"
  let remote_exists = ((do { ^git -C $main_path rev-parse --verify --quiet $remote_ref } | complete).exit_code == 0)
  if $remote_exists {
    ((do { ^git -C $main_path merge-base --is-ancestor $remote_ref $"origin/($default_branch)" } | complete).exit_code == 0)
  } else {
    let merge = ((do { ^git -C $main_path config --get $"branch.($branch).merge" } | complete).stdout | str trim)
    $merge == $"refs/heads/($branch)"
  }
}

def main [repo_path: string, branch: string, --ticket: string = ""] {
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
    let wt = ($same | first | get path)
    hold $wt $ticket
    print $wt
    return
  }

  # 2. the worktree this ticket already holds
  if $ticket != "" {
    let held = ($rows | where {|r| (holder $r.path) == $ticket })
    if ($held | length) > 0 {
      print ($held | first | get path)
      return
    }
  }

  # 3. a free worktree: held by no ticket, finished branch (see branch-finished) and clean tree
  let free = (
    $rows
    | where {|r|
        if (holder $r.path) != "" { return false }
        let finished = (branch-finished $main_path $r.branch $default_branch)
        let st = (do { ^git -C $r.path status --porcelain } | complete)
        let is_clean = (($st.exit_code == 0) and (($st.stdout | str trim) == ""))
        ($finished and $is_clean)
      }
  )
  if ($free | length) > 0 {
    let wt = ($free | first | get path)
    checkout-branch $wt $branch $default_branch
    hold $wt $ticket
    print $wt
    return
  }

  # 4. create the next index
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
  copy-worktreeinclude $main_path $wt
  hold $wt $ticket
  print $wt
}
