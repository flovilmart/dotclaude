# Tests for config.nu (config.local.yaml: loading, validation, migration from the old markdown),
# against the shipped config.example.yaml.
use std/testing *
use std/assert
use ../config.nu *

const HERE = path self .
def example-path [] { $HERE | path join ../../../agent-workflow/config.example.yaml }
def legacy-path [] { $HERE | path join fixtures/config.legacy.md }
def example [] { load-config (example-path) }

# Run nu code in a child process whose HOME is `home`: `~` follows the HOME a process starts with,
# so with-env inside this process wouldn't move it
def with-home [home: string, code: string] {
  let config_nu = ($HERE | path join ../config.nu | path expand | to json)
  with-env {HOME: $home} { do { ^nu --no-config-file -c $"use ($config_nu) *; ($code)" } | complete }
}

def yaml-config [text: string] {
  let f = (mktemp --suffix .yaml | str trim)
  $text | save --force $f
  $f
}

@test
def "the example config is valid and typed" [] {
  let cfg = (example)
  assert equal $cfg.max_parallel 3
  assert equal $cfg.auto_merge true
  assert equal $cfg.comment_marker "🤖 agent-workflow"
  assert equal $cfg.slice_branch_pattern "{linear_branch}-s{n}-{slug}"
  assert equal $cfg.watch_hours "8-19"
}

@test
def "the example config documents every key the schema knows" [] {
  let documented = (open --raw (example-path) | from yaml | columns)
  assert equal ($SCHEMA | columns | where {|k| $k not-in $documented }) []
}

@test
def "empty values are absent" [] {
  let cfg = (load-config (yaml-config "team_key: X\nmodel:\ndispatcher_name: ''\nrepos:\n  - match: default\n    repo: ~/a\n"))
  assert equal ($cfg.model? | default "absent") "absent"
  assert equal ($cfg.dispatcher_name? | default "absent") "absent"
}

@test
def "removed keys are dropped with a warning instead of failing" [] {
  let f = (yaml-config "team_key: X\nlinear_oauth_client_id: client-1\nlinear_oauth_port: 8765\nrepos:\n  - match: default\n    repo: ~/a\n")
  let r = (with-home $env.HOME $"load-config ($f | to json) | columns | to json")
  assert equal $r.exit_code 0
  assert ("linear_oauth_client_id" not-in ($r.stdout | from json))
  assert ($r.stderr | str contains "`linear_oauth_client_id` in")
  assert ($r.stderr | str contains "`linear_oauth_port` in")
  assert ($r.stderr | str contains "linear login")
}

@test
def "the api key reference must be a 1Password reference" [] {
  let f = (yaml-config "team_key: X\nlinear_api_key_ref: lin_api_0123\nrepos:\n  - match: default\n    repo: ~/a\n")
  let msg = (try { load-config $f; "loaded" } catch {|e| $e.msg })
  assert ($msg | str contains "`linear_api_key_ref` must look like op://<vault>/<item>/<field>")
}

@test
def "repo paths are expanded and resolve by project then label then default" [] {
  let repos = (example).repos
  assert equal (resolve-repo $repos "Demo App" []) ("~/src/flovilmart/demo-app" | path expand)
  assert equal (resolve-repo $repos null [infra]) ("~/src/flovilmart/infra" | path expand)
  assert equal (resolve-repo $repos "Other" []) ("~/src/flovilmart/dotclaude" | path expand)
}

@test
def "every problem is reported at once" [] {
  let f = (yaml-config "team_key: X\nteam_kee: Y\nmax_parallel: three\nwatch: often\nrepos:\n  - match: 'label: x'\n    repo: ~/a\n")
  let msg = (try { load-config $f; "loaded" } catch {|e| $e.msg })
  assert ($msg | str contains "unknown key `team_kee`")
  assert ($msg | str contains "`max_parallel` must be an int")
  assert ($msg | str contains "`watch` must be one of monitor, cron")
  assert ($msg | str contains "`repos` needs an entry with `match: default`")
}

@test
def "required keys are checked" [] {
  let msg = (try { load-config (yaml-config "max_parallel: 2\n"); "loaded" } catch {|e| $e.msg })
  assert ($msg | str contains "missing `team_key`")
  assert ($msg | str contains "missing `repos`")
}

@test
def "an old markdown config still loads and matches its migration" [] {
  let out = (mktemp -d | str trim | path join config.local.yaml)
  ^nu ($HERE | path join ../config.nu) migrate --from (legacy-path) --to $out | ignore
  assert equal (load-config $out) (load-config (legacy-path))
  assert (open --raw $out | str contains "repo: ~/src/flovilmart/demo-app")
}

@test
def "migrate refuses to overwrite without force" [] {
  let out = (yaml-config "team_key: KEEP\n")
  let r = (do { ^nu ($HERE | path join ../config.nu) migrate --from (legacy-path) --to $out } | complete)
  assert not equal $r.exit_code 0
  assert equal (open --raw $out) "team_key: KEEP\n"
}

@test
def "a comma separated reviewers value from the old format becomes a list" [] {
  assert equal (normalize {reviewers: "alice, bob"} | get reviewers) [alice bob]
}

@test
def "without a yaml config the old markdown one is read" [] {
  let home = (mktemp -d | str trim)
  mkdir $"($home)/.claude/skills/agent-workflow"
  cp (legacy-path) $"($home)/.claude/skills/agent-workflow/config.local.md"
  let r = (with-home $home "load-config | get team_key")
  assert equal ($r.stdout | str trim) "DEMO"
  assert ($r.stderr | str contains "reading the old")
}

@test
def "with neither config the error says how to create one" [] {
  let home = (mktemp -d | str trim)
  let r = (with-home $home "load-config")
  assert not equal $r.exit_code 0
  assert ($r.stderr | str contains "run /agent-workflow start")
}
