# linear — Linear from your shell, with the agent workflow's config and sign-in.
#
#   linear login          sign in once (OAuth with PKCE; opens the browser)
#   linear status         how the workflow authenticates, and whether it's signed in
#   linear me             who you are in Linear
#   linear issues         your open issues in the configured team, by priority
#   linear logout         revoke the OAuth token and forget it
#
# Config: ~/.claude/skills/agent-workflow/config.local.yaml (team_key, linear_oauth_client_id or
# linear_api_key_ref), the same file the watcher reads. Loaded at shell start by autoload.nu.

use ../oauth.nu
use ../../skills/linear-poll/scripts/config.nu [load-config CONFIG_PATH]
use ../../skills/linear-poll/scripts/linear.nu [provider uses-oauth auth my-issues whoami]

def cfg [config: string] { if $config == "" { load-config } else { load-config $config } }

def oauth-provider [cfg] {
  if not (uses-oauth $cfg) {
    error make { msg: "set linear_oauth_client_id in config.local.yaml (the client ID of your Linear OAuth application)" }
  }
  provider $cfg
}

# Sign in to Linear with OAuth (opens the browser once; --manual: paste the redirected URL)
export def login [--manual, --config: string = ""] {
  oauth login (oauth-provider (cfg $config)) --manual=$manual
}

# Revoke the OAuth token at Linear and delete it locally
export def logout [--config: string = ""] {
  oauth logout (oauth-provider (cfg $config))
}

# How the agent workflow authenticates to Linear, and whether it's ready (never prints a token)
export def status [--config: string = ""] {
  let c = (cfg $config)
  if (uses-oauth $c) {
    {method: "oauth"} | merge (oauth status (provider $c))
  } else {
    let ref = ($c.linear_api_key_ref? | default "")
    {method: "api-key", source: (if ($env.LINEAR_API_KEY? | default "") != "" { "LINEAR_API_KEY" } else if $ref != "" { $ref } else { "not configured" })}
  }
}

# Who you are in Linear
export def me [--config: string = ""] {
  whoami (auth (cfg $config))
}

# Your open issues in the configured team, most urgent first
export def issues [--config: string = ""] {
  let c = (cfg $config)
  my-issues (auth $c) $c.team_key
  | insert rank {|i| if $i.priority == 0 { 5 } else { $i.priority } }
  | sort-by rank createdAt
  | each {|i| {
      id: $i.identifier
      title: $i.title
      state: $i.state
      priority: (["none" "urgent" "high" "medium" "low"] | get $i.priority)
      labels: ($i.labels | str join ", ")
      cycle: (if ($i.cycle?.isActive? | default false) { "current" } else if ($i.cycle?.isNext? | default false) { "next" } else { "" })
    } }
}
