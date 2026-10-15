#!/usr/bin/env nu
# dispatch.nu <repo-path> <ticket-id> <branch> [--dispatcher <session-name>]
#             [--permission-mode auto] [--model <alias>] [--skill ticket-workflow]
#
# 1. Allocates a sibling worktree for <ticket-id> on <branch> (ensure-worktree.nu).
# 2. Starts a background coordinator session there:
#      claude --bg --name <ticket-id> --agent ticket-coordinator "/ticket-workflow <ticket-id> <dispatcher>"
# 3. Prints one JSON object: {ticket, worktree, branch, mode, session}
#
# If the worktree directory has never been trusted, `claude --bg` refuses to
# start ("Workspace not trusted"). In that case, when running inside tmux, a
# window is opened instead with the same session started interactively so the
# user can accept the trust dialog once (mode = "tmux"). Later dispatches to
# that worktree go straight to the background.

def main [
  repo_path: string
  ticket: string
  branch: string
  --dispatcher: string = ""
  --permission-mode: string = "auto"
  --model: string = ""
  --skill: string = "ticket-workflow"
] {
  if "CLAUDECODE" in $env { hide-env CLAUDECODE }
  let skill_dir = ($env.CURRENT_FILE | path dirname)
  let wt = (^nu $"($skill_dir)/ensure-worktree.nu" $repo_path $branch | str trim)
  if $wt == "" {
    error make { msg: "ensure-worktree.nu returned no path" }
  }

  let prompt = ($"/($skill) ($ticket) ($dispatcher)" | str trim)
  mut args = ["--name" $ticket "--agent" "ticket-coordinator" "--permission-mode" $permission_mode]
  if $model != "" { $args = ($args | append ["--model" $model]) }

  cd $wt
  let bg_args = (["--bg"] | append $args | append [$prompt])
  let out = (do { ^claude ...$bg_args } | complete)

  if $out.exit_code == 0 {
    # output looks like: "backgrounded · 7c5dcf5d · ENG-123"
    let line = ($out.stdout | lines | where {|l| $l | str contains "backgrounded" } | append [""] | first)
    let id = ($line | split row "·" | each {|p| $p | str trim } | append ["" ""] | get 1)
    {
      ticket: $ticket
      worktree: $wt
      branch: $branch
      mode: "bg"
      session: $id
    } | to json --raw
    return
  }

  let err = ($out.stderr + $out.stdout)
  let untrusted = ($err | str downcase | str contains "not trusted")
  if $untrusted and ("TMUX" in $env) {
    let quoted = ($args | append [$prompt] | each {|a| $"'($a)'" } | str join " ")
    ^tmux new-window -n $ticket -c $wt $"claude ($quoted)"
    {
      ticket: $ticket
      worktree: $wt
      branch: $branch
      mode: "tmux"
      session: ""
      note: "worktree not trusted yet: accept the trust dialog in the new tmux window; the session then continues there (press ← or /background to detach it)"
    } | to json --raw
    return
  }

  error make { msg: $"claude --bg failed in ($wt): ($err | str trim)" }
}
