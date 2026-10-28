# Every nushell file in the repo must parse with the nu running the tests: a script no test
# executes (tui.nu, report.nu) would otherwise break unnoticed on a nushell upgrade.
use std/testing *
use std/assert

const HERE = path self .

@test
def "every nu file in the repo parses" [] {
  let root = ($HERE | path join ../.. | path expand)
  # files that `use ~/.claude/...` (nu/shell/autoload.nu) must resolve to this checkout,
  # not to whatever is installed: check from a HOME whose .claude is the repo
  let home = (mktemp -d --tmpdir | str trim)
  ^ln -s $root $"($home)/.claude"
  let files = (glob $"($root)/**/*.nu" | to json --raw)
  let broken = (
    with-env {HOME: $home} { $files | ^nu --no-config-file --stdin -c 'from json | where {|f| not (nu-check $f) } | to json --raw' }
    | from json | each {|f| $f | path relative-to $root }
  )
  rm --recursive --force $home
  assert equal $broken [] $"these files don't parse with nu (version | get version): ($broken | str join ', ')"
}
