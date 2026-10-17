# linear.nu — the few Linear GraphQL calls watch.nu needs.
#
#   use linear.nu
#   let key = (linear api-key $cfg.linear_api_key_ref)   # op read, or $env.LINEAR_API_KEY
#   linear my-issues $key $cfg.team_key
#
# A personal API key goes in the Authorization header as is (no "Bearer").
# Limits: 2,500 requests/hour per API key; watch.nu makes 1-2 per cycle.

const API = "https://api.linear.app/graphql"

export def api-key [ref: string] {
  if ($env.LINEAR_API_KEY? | default "") != "" { return $env.LINEAR_API_KEY }
  let r = (do { ^op read $ref } | complete)
  if $r.exit_code != 0 {
    error make { msg: $"op read ($ref) failed: ($r.stderr | str trim)" }
  }
  $r.stdout | str trim
}

export def gql [key: string, query: string, variables: record = {}] {
  let resp = (
    http post --full --allow-errors --content-type application/json --headers [Authorization $key]
      $API ({query: $query, variables: $variables} | to json)
  )
  let errors = ($resp.body.errors? | default [])
  if $resp.status != 200 or ($errors | is-not-empty) {
    let msg = if ($errors | is-empty) { $"HTTP ($resp.status)" } else { $errors | each {|e| $e.message } | str join "; " }
    error make { msg: $"Linear API: ($msg)" }
  }
  $resp.body.data
}

def normalize-issue [n] {
  let description = ($n.description? | default "")
  {
    id: $n.id
    identifier: $n.identifier
    title: $n.title
    branchName: $n.branchName
    priority: ($n.priority? | default 0)
    createdAt: $n.createdAt
    updatedAt: $n.updatedAt
    state: $n.state.name
    labels: ($n.labels.nodes | each {|l| $l.name })
    project: ($n.project?.name? | default null)
    parent: ($n.parent?.identifier? | default null)
    cycle: ($n.cycle? | default null)
    hasSpec: ($description =~ '(?m)^## Spec\b')
    comments: null
  }
}

# My open issues (not completed or canceled) in the team, as the rules expect them
export def my-issues [key: string, team_key: string] {
  let q = '
    query($team: String!) {
      viewer {
        assignedIssues(first: 100, filter: {
          team: { key: { eq: $team } }
          state: { type: { nin: ["completed", "canceled"] } }
        }) {
          nodes {
            id identifier title branchName priority createdAt updatedAt description
            state { name }
            labels { nodes { name } }
            cycle { isActive isNext }
            parent { identifier }
            project { name }
          }
        }
      }
    }'
  gql $key $q {team: $team_key} | get viewer.assignedIssues.nodes | each {|n| normalize-issue $n }
}

# {identifier: [{body createdAt}]} for the given issue ids (uuids)
export def comments-for [key: string, ids: list] {
  if ($ids | is-empty) { return {} }
  let q = '
    query($ids: [ID!]) {
      issues(first: 50, filter: { id: { in: $ids } }) {
        nodes { identifier comments(first: 100) { nodes { body createdAt } } }
      }
    }'
  gql $key $q {ids: $ids} | get issues.nodes
  | reduce --fold {} {|n, acc| $acc | upsert $n.identifier $n.comments.nodes }
}

export def comment [key: string, issue_id: string, body: string] {
  let q = 'mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success } }'
  gql $key $q {input: {issueId: $issue_id, body: $body}} | ignore
}

export def add-label [key: string, issue_id: string, team_key: string, name: string] {
  let find = '
    query($team: String!, $name: String!) {
      issueLabels(first: 1, filter: { name: { eq: $name }, or: [{ team: { key: { eq: $team } } }, { team: { null: true } }] }) {
        nodes { id }
      }
    }'
  let label = (gql $key $find {team: $team_key, name: $name} | get issueLabels.nodes | get 0?)
  if $label == null {
    error make { msg: $"Linear label '($name)' not found in team ($team_key) or workspace" }
  }
  let q = 'mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }'
  gql $key $q {id: $issue_id, input: {addedLabelIds: [$label.id]}} | ignore
}

export def whoami [key: string] {
  gql $key 'query { viewer { name email } }' {} | get viewer
}
