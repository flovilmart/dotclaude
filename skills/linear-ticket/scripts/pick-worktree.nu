#!/usr/bin/env nu
# pick-worktree.nu <repo-path>
# Opens a tmux popup with fzf to pick a worktree from the <repo>-wt<N> pool.
# Prints the chosen worktree path to stdout, or '__new__' if the user selected
# the "create new worktree" option.

def main [repo_path: string] {
  if not ("TMUX" in $env) {
    error make { msg: "Error: must be run inside a tmux session" }
  }

  let main_path  = (^git -C $repo_path rev-parse --show-toplevel | str trim)
  let repo_name  = ($main_path | path basename)
  let skill_dir  = ($env.CURRENT_FILE | path dirname | path expand)

  let tmplist = (^mktemp /tmp/wt-list.XXXXXX | str trim)
  let tmpsel  = (^mktemp /tmp/wt-sel.XXXXXX  | str trim)

  # Fetch so merge-status reflects current remote state
  try { ^git -C $repo_path fetch origin --quiet } catch {}

  let default_branch = (
    try {
      ^git -C $repo_path symbolic-ref refs/remotes/origin/HEAD
        | str trim
        | str replace 'refs/remotes/origin/' ''
    } catch { "main" }
  )

  # Build tab-separated rows: path \t display-name \t branch \t status
  let rows = (
    ^git -C $repo_path worktree list
    | lines
    | each {|line|
        let cols       = ($line | str trim | split row ' ' | where { $in != "" })
        let wt_path    = $cols.0
        let branch_raw = ($cols | last)
        let branch     = ($branch_raw | str replace --all '[' '' | str replace --all ']' '')

        # Skip the main worktree, non-managed siblings, bare, and detached HEAD
        if ($wt_path == $main_path
            or not (($wt_path | path basename) | str starts-with $"($repo_name)-wt")
            or $branch_raw == "(bare)"
            or $branch == "detached") {
          null
        } else {
          let wt_name = ($wt_path | path basename)
          let merged  = (
            try {
              ^git -C $repo_path branch -r --merged $"origin/($default_branch)"
              | lines
              | any {|b| ($b | str trim) == $branch }
            } catch { false }
          )
          let status = if $merged {
            $"(ansi green)[free ✓](ansi reset)"
          } else {
            $"(ansi yellow)[occupied](ansi reset)"
          }
          $"($wt_path)\t($wt_name)\t($branch)\t($status)"
        }
      }
    | compact
  )

  if ($rows | is-empty) {
    error make { msg: $"No managed worktrees found \(expected paths like ~/src/<org>/($repo_name)-wt1\)" }
  }

  $rows | str join "\n" | save --force $tmplist

  # Determine next available index and append the "create new" sentinel
  let repo_parent = ($main_path | path dirname)
  mut next_idx = 1
  while ($"($repo_parent)/($repo_name)-wt($next_idx)" | path exists) {
    $next_idx += 1
  }
  let new_wt_name = $"($repo_name)-wt($next_idx)"
  $"\n__new__\t[+ ($new_wt_name)]\t—\t(ansi cyan)[new](ansi reset)"
    | save --append $tmplist

  ^tmux display-popup -E -w 85% -h 40% $"bash '($skill_dir)/fzf-worktree-popup.sh' '($tmplist)' '($tmpsel)'"

  let sel = (open $tmpsel | str trim)
  ^rm -f $tmplist $tmpsel

  if ($sel | is-empty) {
    error make { msg: "No worktree selected." }
  }

  # Return column 1 (path or '__new__') of the selected tab-separated line
  $sel | split column "\t" | get column1.0
}
