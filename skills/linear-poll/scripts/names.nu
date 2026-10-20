# names.nu — what a coordinator session is called, and which ticket a session name belongs to.
#
# A coordinator is named "<ticket> · <short title>" (e.g. "PROD-4079 · Clarify user grants display"), so
# `claude agents` reads as a list of work, not of ids. The ticket stays the first word: `claude attach PROD-4079`
# still finds it (part of the name works), and sessions named with the bare ticket (before titles) still match.
# nu/shell/inbox.nu keeps its own copy of `ticket-of` (a test keeps the two equal).

const MAX_TITLE = 40

# A Linear title, short enough for a list: tags like "[FE]" and a leading "<ticket>:" dropped, no colons
# (SendMessage relay lines are "send <name>: <message>"), cut at a word boundary
export def short-title [title: string, ticket: string = ""] {
  let t = (
    $title
    | str replace --all --regex '\[[^\]]*\]' ''
    | str replace --regex $'^\s*($ticket)\s*[:\-–—]?' ''
    | str replace --all ':' ' -'
    | str replace --all --regex '\s+' ' '
    | str trim
    | str trim --char '-'
    | str trim
  )
  if ($t | str length) <= $MAX_TITLE { return $t }
  let words = ($t | split row ' ')
  let fit = ($words | reduce --fold '' {|w, acc|
    let next = (if $acc == '' { $w } else { $"($acc) ($w)" })
    if ($next | str length) <= ($MAX_TITLE - 1) { $next } else { $acc }
  })
  let cut = (if $fit == '' { $t | str substring 0..<($MAX_TITLE - 1) } else { $fit })
  $"($cut)…"
}

# "<ticket> · <short title>", or the bare ticket without a title
export def session-name [ticket: string, title: string = ""] {
  let t = (short-title $title $ticket)
  if $t == '' { $ticket } else { $"($ticket) · ($t)" }
}

# The ticket a session name belongs to: its first word
export def ticket-of [name: string] { $name | str trim | split row ' ' | get 0? | default '' }
