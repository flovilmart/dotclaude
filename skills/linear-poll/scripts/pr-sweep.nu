#!/usr/bin/env nu
# pr-sweep.nu <repo-path> [--since <iso8601>] [--limit 100] [--parse-branch <name>]
#
# One JSON row per pull request of the connected GitHub user in <repo-path>:
# every open PR, plus PRs merged after --since. The ticket id is derived from
# the branch name (first "KEY-123" token, upper-cased), which is how the poll
# routes events to the coordinator session named after the ticket.
#
# Row: {number url title branch base ticket state draft ci review mergeable
#       autoMerge updatedAt mergedAt changed}
#   state:   open | merged
#   ci:      pass | fail | pending | none
#   review:  APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | ""
#   changed: updatedAt is after --since (new activity to look at)
#
# --parse-branch <name> only prints the ticket id for that branch name (used by selftest).

def ci-state [rollup] {
  let checks = ($rollup | default [])
  if ($checks | is-empty) { return "none" }
  let states = (
    $checks
    | each {|c| ($c.conclusion? | default ($c.state? | default "")) | str upcase }
  )
  if ($states | any {|s| $s in ["FAILURE" "ERROR" "TIMED_OUT" "CANCELLED" "ACTION_REQUIRED" "STARTUP_FAILURE"] }) {
    "fail"
  } else if ($states | any {|s| $s in ["PENDING" "IN_PROGRESS" "QUEUED" "EXPECTED" "WAITING" ""] }) {
    "pending"
  } else {
    "pass"
  }
}

def ticket-of [branch: string] {
  let m = ($branch | parse --regex '(?i)(?P<t>[a-z][a-z0-9]*-[0-9]+)')
  if ($m | is-empty) { "" } else { $m.0.t | str upcase }
}

def to-row [pr, state: string, since: string] {
  let updated = ($pr.updatedAt? | default "")
  {
    number: $pr.number
    url: $pr.url
    title: ($pr.title? | default "")
    branch: ($pr.headRefName? | default "")
    base: ($pr.baseRefName? | default "")
    ticket: (ticket-of ($pr.headRefName? | default ""))
    state: $state
    draft: ($pr.isDraft? | default false)
    ci: (ci-state ($pr.statusCheckRollup? | default []))
    review: ($pr.reviewDecision? | default "")
    mergeable: ($pr.mergeable? | default "")
    autoMerge: (($pr.autoMergeRequest? | default null) != null)
    updatedAt: $updated
    mergedAt: ($pr.mergedAt? | default "")
    changed: (if ($since == "") or ($updated == "") { true } else { ($updated | into datetime) > ($since | into datetime) })
  }
}

def main [repo_path?: string, --since: string = "", --limit: int = 100, --parse-branch: string = ""] {
  if $parse_branch != "" {
    print (ticket-of $parse_branch)
    return
  }
  if $repo_path == null {
    error make { msg: "usage: pr-sweep.nu <repo-path> [--since <iso8601>]" }
  }
  cd $repo_path
  let fields = "number,url,title,headRefName,baseRefName,isDraft,updatedAt,mergedAt,reviewDecision,mergeable,statusCheckRollup,autoMergeRequest"

  let open = (
    do { ^gh pr list --author "@me" --state open --limit $limit --json $fields } | complete
  )
  if $open.exit_code != 0 {
    error make { msg: $"gh pr list failed: ($open.stderr | str trim)" }
  }
  let open_rows = ($open.stdout | from json | default [] | each {|pr| to-row $pr "open" $since })

  let merged_rows = if $since == "" { [] } else {
    let merged = (
      do { ^gh pr list --author "@me" --state merged --limit 50 --json $fields } | complete
    )
    if $merged.exit_code != 0 { [] } else {
      $merged.stdout
      | from json
      | default []
      | where {|pr| (($pr.mergedAt? | default "") != "") and ((($pr.mergedAt? | default "") | into datetime) > ($since | into datetime)) }
      | each {|pr| to-row $pr "merged" $since }
    }
  }

  print ($open_rows | append $merged_rows | to json --raw)
}
