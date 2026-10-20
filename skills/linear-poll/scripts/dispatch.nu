#!/usr/bin/env nu
# dispatch.nu <repo-path> <ticket-id> <branch> [--title <linear title>] [--dispatcher <session-name>]
#             [--permission-mode auto] [--model <alias>] [--skill ticket-workflow]
#
# 1. Allocates a sibling worktree for <ticket-id> on <branch> and marks it as held
#    by the ticket (ensure-worktree.nu --ticket).
# 2. Starts a background coordinator session there:
#      claude --bg --name "<ticket-id> · <short title>" --agent ticket-coordinator "/ticket-workflow <ticket-id> <dispatcher>"
#    (names.nu session-name; the bare ticket id without --title)
# 3. Prints one JSON object: {ticket, name, worktree, branch, mode, session}
#
# If the worktree directory has never been trusted, `claude --bg` refuses to
# start ("Workspace not trusted"). In that case, when running inside tmux, a
# window is opened instead with the same session started interactively so the
# user can accept the trust dialog once (mode = "tmux"). Later dispatches to
# that worktree go straight to the background.

use names.nu session-name

def main [
  repo_path: string
  ticket: string
  branch: string
  --title: string = ""
  --dispatcher: string = ""
  --permission-mode: string = "auto"
  --model: string = ""
  --skill: string = "ticket-workflow"
] {
  if "CLAUDECODE" in $env { hide-env CLAUDECODE }
  let skill_dir = ($env.CURRENT_FILE | path dirname)
  let wt = (^nu $"($skill_dir)/ensure-worktree.nu" $repo_path $branch --ticket $ticket | str trim)
  if $wt == "" {
    error make { msg: "ensure-worktree.nu returned no path" }
  }

  let prompt = ($"/($skill) ($ticket) ($dispatcher)" | str trim)
  let name = (session-name $ticket $title)
  mut args = ["--name" $name "--agent" "ticket-coordinator" "--permission-mode" $permission_mode]
  if $model != "" { $args = ($args | append ["--model" $model]) }

  cd $wt
  let bg_args = (["--bg"] | append $args | append [$prompt])
  # Redirect to files rather than pipes so a detached session can never hold
  # the dispatcher's stdout/stderr open.
  let tmp_out = (^mktemp | str trim)
  let tmp_err = (^mktemp | str trim)
  let exit_code = (try { ^claude ...$bg_args out> $tmp_out err> $tmp_err; 0 } catch { 1 })
  let stdout = (open --raw $tmp_out | into string)
  let stderr = (open --raw $tmp_err | into string)
  ^rm -f $tmp_out $tmp_err

  if $exit_code == 0 {
    # output looks like: "backgrounded · 7c5dcf5d · ENG-123 · Fix login redirect"
    let line = ($stdout | lines | where {|l| $l | str contains "backgrounded" } | append [""] | first)
    let id = ($line | split row "·" | each {|p| $p | str trim } | append ["" ""] | get 1)
    print ({
      ticket: $ticket
      name: $name
      worktree: $wt
      branch: $branch
      mode: "bg"
      session: $id
    } | to json --raw)
    return
  }

  let err = ($stderr + $stdout)
  let untrusted = ($err | str lowercase | str contains "not trusted")
  if $untrusted and ("TMUX" in $env) {
    let quoted = ($args | append [$prompt] | each {|a| $"'($a)'" } | str join " ")
    ^tmux new-window -n $ticket -c $wt $"claude ($quoted)"
    print ({
      ticket: $ticket
      name: $name
      worktree: $wt
      branch: $branch
      mode: "tmux"
      session: ""
      note: "worktree not trusted yet: accept the trust dialog in the new tmux window; the session then continues there (press ← or /background to detach it)"
    } | to json --raw)
    return
  }

  error make { msg: $"claude --bg failed in ($wt): ($err | str trim)" }
}
