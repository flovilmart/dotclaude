#!/usr/bin/env nu
# sessions.nu [ticket] [--json]
#
# Lists background coordinator sessions (from `claude agents --json --all`),
# optionally filtered to the sessions of one ticket id (named "<ticket> · <title>", or the bare ticket).
# Columns: name ticket id state status waitingFor pid sessionId cwd

use names.nu ticket-of

def main [ticket?: string, --json] {
  let raw = (do { ^claude agents --json --all } | complete)
  if $raw.exit_code != 0 {
    error make { msg: $"claude agents failed: ($raw.stderr | str trim)" }
  }
  let rows = (
    $raw.stdout
    | from json
    | default []
    | where {|s| ($s.kind? | default "") == "background" }
    | each {|s|
        {
          name: ($s.name? | default "")
          ticket: (ticket-of ($s.name? | default ""))
          id: ($s.id? | default "")
          state: ($s.state? | default "")
          status: ($s.status? | default "")
          waitingFor: ($s.waitingFor? | default "")
          pid: $s.pid?
          sessionId: ($s.sessionId? | default "")
          cwd: ($s.cwd? | default "")
        }
      }
  )
  let rows = if $ticket == null { $rows } else { $rows | where ticket == $ticket }
  if $json { $rows | to json } else { $rows }
}
