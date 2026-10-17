# config.nu — read the agent-workflow config (config.local.md) into a record.
#
#   use config.nu *
#   let cfg = (load-config)            # ~/.claude/skills/agent-workflow/config.local.md
#   let cfg = (load-config $path)
#
# Keys come from `- key: value   # comment` lines; integers and booleans are
# converted, quotes stripped. The repo table (`| match | repo |`) becomes
# `repos: [{match, repo}]` with `~` expanded. A missing key is absent, not null:
# read optional keys with `$cfg.key? | default <value>`.

export const CONFIG_PATH = "~/.claude/skills/agent-workflow/config.local.md"

def parse-value [raw: string] {
  let v = ($raw | str trim | str trim --char '"')
  if $v =~ '^-?[0-9]+$' { $v | into int } else if $v in ["true" "false"] { $v == "true" } else { $v }
}

export def parse-config [text: string] {
  let lines = ($text | lines)
  let pairs = (
    $lines
    | where {|l| $l =~ '^- [a-z_]+:' }
    | each {|l|
        let kv = ($l | str replace --regex '^- ' '' | parse --regex '^(?<key>[a-z_]+):\s*(?<rest>.*)$' | first)
        # a "#" at the start or after a space opens a comment
        let value = ($kv.rest | str replace --regex '(^|\s)#.*$' '' | str trim)
        {key: $kv.key, value: (parse-value $value)}
      }
    | where {|p| $p.value != "" }
  )
  let repos = (
    $lines
    | where {|l| $l =~ '^\|' }
    | each {|l| $l | str trim --char '|' | split row '|' | each {|c| $c | str trim } }
    | where {|cells| ($cells | length) == 2 and $cells.0 != "match" and not ($cells.0 =~ '^-+$') }
    | each {|cells| {match: $cells.0, repo: ($cells.1 | path expand)} }
  )
  $pairs | reduce --fold {repos: $repos} {|p, acc| $acc | upsert $p.key $p.value }
}

export def load-config [path: string = $CONFIG_PATH] {
  let p = ($path | path expand)
  if not ($p | path exists) {
    error make { msg: $"no config at ($p): run /agent-workflow start" }
  }
  parse-config (open --raw $p)
}

# First repo row matching the issue's project, then its labels, then `default`.
export def resolve-repo [repos: list, project, labels: list] {
  let by_project = ($repos | where {|r| $project != null and $r.match == $"project: ($project)" })
  let by_label = ($repos | where {|r| ($labels | any {|l| $r.match == $"label: ($l)" }) })
  let fallback = ($repos | where {|r| $r.match == "default" })
  $by_project | append $by_label | append $fallback | get repo | first 1 | get 0?
}
