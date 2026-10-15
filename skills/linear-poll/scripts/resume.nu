#!/usr/bin/env nu
# resume.nu <ticket> <message>
#
# Delivers <message> to the coordinator session named <ticket>:
#   - process alive  -> prints `running <id>`; the caller must use SendMessage
#                       (cross-session messaging) to reach it.
#   - process exited -> restarts it with `claude --resume <sessionId> --bg <message>`
#                       and prints `resumed <id>`.
#   - no session     -> prints `none`; the caller should dispatch afresh.

def main [ticket: string, message: string] {
  if "CLAUDECODE" in $env { hide-env CLAUDECODE }
  let skill_dir = ($env.CURRENT_FILE | path dirname)
  let rows = (^nu $"($skill_dir)/sessions.nu" $ticket --json | from json)
  if ($rows | length) == 0 {
    print "none"
    return
  }
  let s = ($rows | first)
  if $s.pid != null {
    print $"running ($s.id)"
    return
  }
  if $s.sessionId == "" {
    print "none"
    return
  }
  if $s.cwd != "" { cd $s.cwd }
  let out = (do { ^claude --resume $s.sessionId --bg $message } | complete)
  if $out.exit_code != 0 {
    error make { msg: $"claude --resume --bg failed: ($out.stderr | str trim)" }
  }
  print $"resumed ($s.id)"
}
