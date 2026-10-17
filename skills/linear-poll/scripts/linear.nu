# linear.nu — the few Linear GraphQL calls watch.nu needs.
#
#   use linear.nu
#   let auth = (linear auth $cfg)        # the Authorization header value
#   linear my-issues $auth $cfg.team_key
#
# Two ways to authenticate:
#   - OAuth (linear_oauth_client_id set): authorization code + PKCE through ~/.claude/nu/oauth.nu.
#     Sign in once with linear-auth.nu login; access tokens last 24h and refresh themselves.
#     The header is "Bearer <token>".
#   - a personal API key (linear_api_key_ref, read with `op read`, or $env.LINEAR_API_KEY),
#     sent as is, without "Bearer".
# Limits: 2,500 requests/hour per API key; watch.nu makes 1-2 per cycle.

use ../../../nu/oauth.nu

const API = "https://api.linear.app/graphql"

export def uses-oauth [cfg] { ($cfg.linear_oauth_client_id? | default "") != "" }

# Linear as an oauth.nu provider: a public client (PKCE, no secret) acting as the user
export def provider [cfg] {
  {
    name: "linear"
    authorize_url: "https://linear.app/oauth/authorize"
    token_url: "https://api.linear.app/oauth/token"
    revoke_url: "https://api.linear.app/oauth/revoke"
    client_id: $cfg.linear_oauth_client_id
    scopes: [read write]
    scope_sep: ","
    port: ($cfg.linear_oauth_port? | default 8765)
    host: ($cfg.linear_oauth_host? | default "127.0.0.1")
    extra: {actor: "user"}
  }
}

# The Authorization header value for the configured method
export def auth [cfg] {
  if (uses-oauth $cfg) {
    $"Bearer (oauth token (provider $cfg))"
  } else {
    if ($cfg.linear_api_key_ref? | default "") == "" and ($env.LINEAR_API_KEY? | default "") == "" {
      error make { msg: "set linear_oauth_client_id (OAuth) or linear_api_key_ref (API key) in config.local.md" }
    }
    api-key ($cfg.linear_api_key_ref? | default "")
  }
}

export def api-key [ref: string] {
  if ($env.LINEAR_API_KEY? | default "") != "" { return $env.LINEAR_API_KEY }
  let r = (do { ^op read $ref } | complete)
  if $r.exit_code != 0 {
    error make { msg: $"op read ($ref) failed: ($r.stderr | str trim)" }
  }
  $r.stdout | str trim
}

export def gql [auth: string, query: string, variables: record = {}] {
  let resp = (
    http post --full --allow-errors --content-type application/json --headers [Authorization $auth]
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
export def my-issues [auth: string, team_key: string] {
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
  gql $auth $q {team: $team_key} | get viewer.assignedIssues.nodes | each {|n| normalize-issue $n }
}

# {identifier: [{body createdAt}]} for the given issue ids (uuids)
export def comments-for [auth: string, ids: list] {
  if ($ids | is-empty) { return {} }
  let q = '
    query($ids: [ID!]) {
      issues(first: 50, filter: { id: { in: $ids } }) {
        nodes { identifier comments(first: 100) { nodes { body createdAt } } }
      }
    }'
  gql $auth $q {ids: $ids} | get issues.nodes
  | reduce --fold {} {|n, acc| $acc | upsert $n.identifier $n.comments.nodes }
}

export def comment [auth: string, issue_id: string, body: string] {
  let q = 'mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success } }'
  gql $auth $q {input: {issueId: $issue_id, body: $body}} | ignore
}

export def add-label [auth: string, issue_id: string, team_key: string, name: string] {
  let find = '
    query($team: String!, $name: String!) {
      issueLabels(first: 1, filter: { name: { eq: $name }, or: [{ team: { key: { eq: $team } } }, { team: { null: true } }] }) {
        nodes { id }
      }
    }'
  let label = (gql $auth $find {team: $team_key, name: $name} | get issueLabels.nodes | get 0?)
  if $label == null {
    error make { msg: $"Linear label '($name)' not found in team ($team_key) or workspace" }
  }
  let q = 'mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }'
  gql $auth $q {id: $issue_id, input: {addedLabelIds: [$label.id]}} | ignore
}

export def whoami [auth: string] {
  gql $auth 'query { viewer { name email } }' {} | get viewer
}
