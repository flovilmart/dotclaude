# Tests for names.nu: coordinator session names.
use std/testing *
use std/assert
use ../names.nu *

@test
def "a session is named after its ticket and a short title" [] {
  assert equal (session-name "PROD-4079" "Fix A and clarify user grants display") "PROD-4079 · Fix A and clarify user grants display"
  assert equal (session-name "ENG-1" "") "ENG-1"
}

@test
def "a short title drops tags the ticket prefix and colons" [] {
  assert equal (short-title "[FE] [Bug]  PROD-12: Login redirect loops" "PROD-12") "Login redirect loops"
  assert equal (short-title "Auth: fix redirect") "Auth - fix redirect"
}

@test
def "a long title is cut at a word boundary" [] {
  let t = (short-title "Evaluate Claude web search instead of Cloudflare with zero retention")
  assert equal $t "Evaluate Claude web search instead of…"
  assert (($t | str length) <= 40)
  assert equal (short-title ("y" | fill --width 60 --character "y")) $"("y" | fill --width 39 --character "y")…"
}

@test
def "the ticket is the first word of a session name" [] {
  assert equal (ticket-of "PROD-4079 · Fix grants display") "PROD-4079"
  assert equal (ticket-of "ENG-1") "ENG-1"
  assert equal (ticket-of "") ""
}
