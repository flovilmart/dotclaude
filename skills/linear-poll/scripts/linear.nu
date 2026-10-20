# linear.nu — the few Linear GraphQL calls the watcher and the `linear` shell command need.
#
#   use linear.nu
#   let auth = (linear auth $cfg)        # the API key, read from 1Password
#   linear my-issues $auth $cfg.team_key
#
# Linear access is a personal API key kept in 1Password at linear_api_key_ref (default
# op://Private/Linear API Key/credential); `linear login` stores it there. $env.LINEAR_API_KEY overrides
# it (a container or CI without `op`). The key goes in the Authorization header as is.
# Limits: 2,500 requests/hour per API key; the watcher makes 1-2 per cycle.

const API = "https://api.linear.app/graphql"
export const DEFAULT_KEY_REF = "op://Private/Linear API Key/credential"

# Where the key lives in 1Password
export def key-ref [cfg] { $cfg.linear_api_key_ref? | default $DEFAULT_KEY_REF }

# {vault item field} of an op://<vault>/<item>/<field> reference
export def parse-ref [ref: string] {
  let m = ($ref | parse --regex '^op://(?<vault>[^/]+)/(?<item>[^/]+)/(?<field>[^/]+)$')
  if ($m | is-empty) { error make { msg: $"a 1Password reference looks like op://<vault>/<item>/<field>, got ($ref)" } }
  $m.0
}

# The Authorization header value: the API key
export def auth [cfg] { api-key (key-ref $cfg) }

export def api-key [ref: string] {
  if ($env.LINEAR_API_KEY? | default "") != "" { return $env.LINEAR_API_KEY }
  let r = (do { ^op read $ref } | complete)
  if $r.exit_code != 0 {
    error make { msg: $"op read ($ref) failed: ($r.stderr | str trim) \(store the key with `linear login`\)" }
  }
  $r.stdout | str trim
}

# Store a key at an op:// reference: set the field on its API Credential item, or create that
# item. Any other kind of item (your Linear login, say) is left alone. The key reaches `op` as an
# assignment argument (as `op` expects): visible to this user's processes for an instant, never on disk.
export def store-key [ref: string, key: string] {
  let r = (parse-ref $ref)
  let found = (do { ^op item get $r.item --vault $r.vault --format json } | complete)
  let exists = ($found.exit_code == 0)
  if not $exists and not ($found.stderr =~ "isn't an item") {
    error make { msg: $"op couldn't look up ($ref): ($found.stderr | str trim)" }
  }
  if $exists {
    let category = ($found.stdout | from json | get category? | default "unknown")
    if $category != "API_CREDENTIAL" {
      let kind = ($category | str lowercase | str replace --all "_" " ")
      error make { msg: $"'($r.item)' in ($r.vault) is a ($kind) item, not an API Credential; set linear_api_key_ref to an item of its own, e.g. op://($r.vault)/Linear API Key/credential" }
    }
  }
  # an API Credential's own `credential` field is already concealed; any other field is made a password field
  let assignment = if $r.field == "credential" { $"credential=($key)" } else { $"($r.field)[password]=($key)" }
  let out = if $exists {
    do { ^op item edit $r.item --vault $r.vault $assignment } | complete
  } else {
    do { ^op item create --category "API Credential" --title $r.item --vault $r.vault $assignment } | complete
  }
  if $out.exit_code != 0 {
    error make { msg: $"op couldn't store the key at ($ref): ($out.stderr | str trim)" }
  }
  {ref: $ref, item: (if $exists { "updated" } else { "created" })}
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
