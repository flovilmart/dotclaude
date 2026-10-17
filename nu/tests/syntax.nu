# Every nushell file in the repo must parse with the nu running the tests: a script no test
# executes (tui.nu, report.nu) would otherwise break unnoticed on a nushell upgrade.
use std/testing *
use std/assert

const HERE = path self .

@test
def "every nu file in the repo parses" [] {
  let root = ($HERE | path join ../.. | path expand)
  let broken = (glob $"($root)/**/*.nu" | where {|f| not (nu-check $f) } | each {|f| $f | path relative-to $root })
  assert equal $broken [] $"these files don't parse with nu (version | get version): ($broken | str join ', ')"
}
