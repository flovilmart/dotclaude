# linear — Linear from your shell, with the agent workflow's config and API key.
#
#   linear login          store a personal API key in 1Password, at linear_api_key_ref
#   linear status         where the key is read from, and whether it can be read (never prints it)
#   linear me             who you are in Linear
#   linear issues         your open issues in the configured team, by priority
#
# Config: ~/.claude/skills/agent-workflow/config.local.yaml (team_key, linear_api_key_ref, default
# op://Private/Linear/credential), the same file the watcher reads. Loaded at shell start by autoload.nu.

use ../../skills/linear-poll/scripts/config.nu [load-config]
use ../../skills/linear-poll/scripts/linear.nu [key-ref store-key auth my-issues whoami]

const KEYS_PAGE = "https://linear.app/settings/account/security"

def cfg [config: string] { if $config == "" { load-config } else { load-config $config } }

# Create a personal API key in Linear and store it in 1Password at linear_api_key_ref
export def login [--config: string = ""] {
  let ref = (key-ref (cfg $config))
  print $"In Linear: Settings → Security & access → Personal API keys → New API key \(($KEYS_PAGE)\)."
  print "Give it read and write access to the workflow's team, then paste it here."
  if $nu.os-info.name == "macos" { try { ^open $KEYS_PAGE } }
  let key = (input --suppress-output "API key: " | str trim)
  print ""
  if $key == "" { error make { msg: "no key pasted; nothing stored" } }
  # check the key before storing it, so a typo doesn't replace a working one
  let me = (try { whoami $key } catch {|e| error make { msg: $"Linear refused that key: ($e.msg)" } })
  let stored = (store-key $ref $key)
  print $"($stored.item) ($ref): the key of ($me.name) <($me.email)>"
}

# Where the agent workflow reads the Linear API key, and whether it can (never prints the key)
export def status [--config: string = ""] {
  let ref = (key-ref (cfg $config))
  if ($env.LINEAR_API_KEY? | default "") != "" { return {source: "LINEAR_API_KEY", ref: $ref, readable: true} }
  let readable = ((which op | is-not-empty) and ((do { ^op read $ref } | complete).exit_code == 0))
  {source: "1Password", ref: $ref, readable: $readable}
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
