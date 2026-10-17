# config.nu — the agent-workflow config: ~/.claude/skills/agent-workflow/config.local.yaml
#
#   use config.nu *
#   let cfg = (load-config)            # validated record, `~` expanded in repos
#   let cfg = (load-config $path)
#
#   nu config.nu check [path]          # validate, and show what the scripts will read
#   nu config.nu migrate [--force]     # the old config.local.md → config.local.yaml
#
# Keys left empty in the YAML are absent from the record: read optional ones with
# `$cfg.key? | default <value>`. Validation names every problem at once: unknown keys
# (typos), missing required keys, wrong types and values outside a key's choices.
# Until you migrate, a config.local.md is still read, with a warning.

export const CONFIG_PATH = "~/.claude/skills/agent-workflow/config.local.yaml"
export const LEGACY_PATH = "~/.claude/skills/agent-workflow/config.local.md"

# Every key the workflow reads: its type (string, int, bool, list, repos), whether it is
# required, and for some the values it may take. Keep in step with config.example.yaml.
export const SCHEMA = {
  team_key: {type: string, required: true}
  team_id: {type: string}
  todo_state: {type: string}
  in_progress_state: {type: string}
  review_state: {type: string}
  done_state: {type: string}
  stalled_label: {type: string}
  needs_spec_label: {type: string}
  needs_plan_label: {type: string}
  create_subissues: {type: bool}
  repos: {type: repos, required: true}
  permission_mode: {type: string, choices: [auto acceptEdits default bypassPermissions]}
  model: {type: string}
  fast_model: {type: string}
  max_parallel: {type: int}
  max_redispatch: {type: int}
  dispatcher_name: {type: string}
  linear_oauth_client_id: {type: string}
  linear_oauth_port: {type: int}
  linear_oauth_host: {type: string}
  linear_oauth_redirect_uri: {type: string}
  linear_api_key_ref: {type: string}
  watch: {type: string, choices: [monitor cron]}
  watch_interval: {type: int}
  watch_hours: {type: string}
  watch_days: {type: string}
  poll_cron: {type: string}
  pre_spec_next_cycle: {type: bool}
  plan_approval: {type: string, choices: [human auto]}
  reviewers: {type: list}
  auto_merge: {type: bool}
  max_slice_lines: {type: int}
  merge_method: {type: string, choices: [squash merge rebase]}
  smoke_test: {type: string, choices: [auto always never]}
  verify_scope: {type: string, choices: [affected full]}
  max_fix_rounds: {type: int}
  security_review: {type: string, choices: [auto always never]}
  stack_tool: {type: string, choices: [auto gh-stack manual]}
  slice_branch_pattern: {type: string}
  comment_marker: {type: string}
}

def kind [v] {
  let d = ($v | describe)
  if ($d | str starts-with "list") or ($d | str starts-with "table") { "list" } else if ($d | str starts-with "record") { "record" } else { $d }
}

# Problems with a config record, as messages; empty when it is valid
export def validate [cfg: record] {
  let unknown = ($cfg | columns | where {|k| $k not-in ($SCHEMA | columns) } | each {|k| $"unknown key `($k)` \(a typo? see config.example.yaml\)" })
  let missing = ($SCHEMA | transpose key spec | where {|s| ($s.spec.required? | default false) and $s.key not-in ($cfg | columns) } | each {|s| $"missing `($s.key)`" })
  let typed = ($cfg | transpose key value | where {|kv| $kv.key in ($SCHEMA | columns) } | each {|kv|
    let spec = ($SCHEMA | get $kv.key)
    let got = (kind $kv.value)
    if $spec.type == "repos" {
      if $got != "list" { return [$"`repos` must be a list of {match, repo} entries, got ($got)"] }
      let bad = ($kv.value | enumerate | where {|e| (kind $e.item) != "record" or (($e.item.match? | kind $in) != "string") or (($e.item.repo? | kind $in) != "string") })
      let entries = ($bad | each {|e| $"`repos` entry ($e.index + 1) needs a `match` and a `repo` string" })
      let default = if ($kv.value | any {|r| ($r.match? | default "") == "default" }) { [] } else { ["`repos` needs an entry with `match: default`"] }
      $entries | append $default
    } else if $got != $spec.type {
      let article = if $spec.type == "int" { "an" } else { "a" }
      [$"`($kv.key)` must be ($article) ($spec.type), got ($got) \(($kv.value | to nuon)\)"]
    } else if ($spec.choices? | default []) != [] and $kv.value not-in $spec.choices {
      [$"`($kv.key)` must be one of ($spec.choices | str join ', '), got `($kv.value)`"]
    } else { [] }
  } | flatten)
  $unknown | append $missing | append $typed
}

# Empty values dropped, `~` expanded in repo paths, a comma-separated `reviewers` (old format) split
export def normalize [raw: record] {
  $raw
  | transpose key value
  | where {|kv| $kv.value != null and $kv.value != "" }
  | reduce --fold {} {|kv, acc| $acc | upsert $kv.key $kv.value }
  | if "reviewers" in ($in | columns) and (kind $in.reviewers) == "string" {
      update reviewers {|c| $c.reviewers | split row "," | each {|r| $r | str trim } | where {|r| $r != "" } }
    } else { $in }
  | if "repos" in ($in | columns) and (kind $in.repos) == "list" {
      update repos {|c| $c.repos | each {|r| if (kind $r) == "record" and (kind ($r.repo? | default null)) == "string" { $r | update repo ($r.repo | path expand) } else { $r } } }
    } else { $in }
}

# The old config.local.md format: `- key: value   # comment` lines and a `| match | repo |` table.
# Kept for reading an unmigrated config and for `migrate`; repo paths are left as written.
export def parse-markdown [text: string] {
  let lines = ($text | lines)
  let value = {|raw|
    let v = ($raw | str trim | str trim --char '"')
    if $v =~ '^-?[0-9]+$' { $v | into int } else if $v in ["true" "false"] { $v == "true" } else { $v }
  }
  let pairs = (
    $lines
    | where {|l| $l =~ '^- [a-z_]+:' }
    | each {|l|
        let kv = ($l | str replace --regex '^- ' '' | parse --regex '^(?<key>[a-z_]+):\s*(?<rest>.*)$' | first)
        # a "#" at the start or after a space opens a comment
        {key: $kv.key, value: (do $value ($kv.rest | str replace --regex '(^|\s)#.*$' ''))}
      }
  )
  let repos = (
    $lines
    | where {|l| $l =~ '^\|' }
    | each {|l| $l | str trim --char '|' | split row '|' | each {|c| $c | str trim } }
    | where {|cells| ($cells | length) == 2 and $cells.0 != "match" and not ($cells.0 =~ '^-+$') }
    | each {|cells| {match: $cells.0, repo: $cells.1} }
  )
  $pairs | reduce --fold {repos: $repos} {|p, acc| $acc | upsert $p.key $p.value }
}

def read-raw [p: string] {
  if ($p | str ends-with ".md") { parse-markdown (open --raw $p) } else { open --raw $p | from yaml | default {} }
}

# The validated config. Without a path: config.local.yaml, else the old config.local.md (with a warning).
export def load-config [path: string = ""] {
  let p = if $path != "" { $path | path expand } else { $CONFIG_PATH | path expand }
  let legacy = ($LEGACY_PATH | path expand)
  let source = if ($p | path exists) { $p } else if $path == "" and ($legacy | path exists) {
    print --stderr $"config.nu: reading the old ($LEGACY_PATH); convert it once with: nu ~/.claude/skills/linear-poll/scripts/config.nu migrate"
    $legacy
  } else {
    error make { msg: $"no config at ($p): run /agent-workflow start \(template: skills/agent-workflow/config.example.yaml\)" }
  }
  let cfg = (normalize (read-raw $source))
  let problems = (validate $cfg)
  if ($problems | is-not-empty) {
    let list = ($problems | each {|m| $"- ($m)" } | str join (char nl))
    error make { msg: $"invalid config ($source):\n($list)" }
  }
  $cfg
}

# First repo entry matching the issue's project, then its labels, then `default`.
export def resolve-repo [repos: list, project, labels: list] {
  let by_project = ($repos | where {|r| $project != null and $r.match == $"project: ($project)" })
  let by_label = ($repos | where {|r| ($labels | any {|l| $r.match == $"label: ($l)" }) })
  let fallback = ($repos | where {|r| $r.match == "default" })
  $by_project | append $by_label | append $fallback | get repo | first 1 | get 0?
}

# ── command line ────────────────────────────────────────────────────────────

def main [] {
  print "usage: config.nu check [path] | migrate [--from <config.local.md>] [--to <config.local.yaml>] [--force]"
}

# Validate a config and show what the scripts will read
def "main check" [path: string = ""] {
  let cfg = (load-config $path)
  print ($cfg | table --expand)
  print "config is valid"
}

# Convert the old config.local.md to config.local.yaml (comments aren't carried over: see config.example.yaml)
def "main migrate" [--from: string = "", --to: string = "", --force] {
  let src = (if $from == "" { $LEGACY_PATH } else { $from } | path expand)
  let dst = (if $to == "" { $CONFIG_PATH } else { $to } | path expand)
  if not ($src | path exists) { error make { msg: $"nothing to migrate: no ($src)" } }
  if ($dst | path exists) and not $force { error make { msg: $"($dst) already exists: pass --force to overwrite it" } }
  let raw = (parse-markdown (open --raw $src))
  # schema order, empty values dropped, comma lists split; repo paths stay as written (~ kept)
  let normalized = (normalize $raw)
  let cfg = if "repos" in ($normalized | columns) { $normalized | update repos $raw.repos } else { $normalized }
  let ordered = ($SCHEMA | columns | where {|k| $k in ($cfg | columns) } | reduce --fold {} {|k, acc| $acc | insert $k ($cfg | get $k) })
  let extra = ($cfg | reject ...($ordered | columns))
  let header = $"# Agent workflow config, migrated from ($src | path basename). Keys and comments: config.example.yaml\n"
  $"($header)($ordered | merge $extra | to yaml)" | save --force $dst
  print $"wrote ($dst)"
  let problems = (validate (normalize (read-raw $dst)))
  if ($problems | is-empty) { print "config is valid" } else {
    let list = ($problems | each {|m| $"- ($m)" } | str join (char nl))
    print $"fix these in ($dst | path basename):\n($list)"
  }
}
