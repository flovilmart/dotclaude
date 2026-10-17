# gha.nu — GitHub Actions output from nushell: annotations and the job summary.
#
#   use ~/.claude/nu/gha.nu
#   if (gha enabled) { print (gha annotation error "boom" --file src/x.nu --line 3 --title "a test") }
#   gha summary "### results\n| a | b |"        # appended to $GITHUB_STEP_SUMMARY; no-op elsewhere
#
# Annotations (`::error file=..,line=..,title=..::message`) show on the run page and, in a
# pull request, on the matching line of the diff. Outside GitHub Actions nothing is written.

export def enabled [] { ($env.GITHUB_ACTIONS? | default "") == "true" }

# Workflow-command escaping: the message keeps newlines as %0A; property values also escape : and ,
def escape-data [s: string] {
  $s | str replace --all '%' '%25' | str replace --all "\r" '%0D' | str replace --all "\n" '%0A'
}
def escape-property [s: string] {
  escape-data $s | str replace --all ':' '%3A' | str replace --all ',' '%2C'
}

# The annotation line for a level (error, warning, notice); print it to the job's stdout
export def annotation [level: string, message: string, --file: string, --line: int, --title: string] {
  let props = (
    [[key value]; [file $file] [line $line] [title $title]]
    | where {|p| $p.value != null }
    | each {|p| $"($p.key)=(escape-property ($p.value | into string))" }
    | str join ","
  )
  let head = if $props == "" { $"::($level)" } else { $"::($level) ($props)" }
  $"($head)::(escape-data $message)"
}

# Append Markdown to the job summary (only when GitHub Actions provides the file)
export def summary [markdown: string] {
  let f = ($env.GITHUB_STEP_SUMMARY? | default "")
  if $f != "" { $"($markdown)\n" | save --append $f }
}

# The first source location in a rendered nushell error (`,-[path:line:col]`) that is a file
# under root, as {file (relative to root), line}; null when there is none
export def error-location [error: string, root: string] {
  let root = ($root | path expand)
  $error
  | parse --regex ',-\[(?<path>[^\]\n]+?):(?<line>\d+):(?<col>\d+)\]'
  | each {|m| {path: ($m.path | path expand --no-symlink), line: ($m.line | into int)} }
  | where {|m| ($m.path | str starts-with $"($root)/") and ($m.path | path exists) }
  | each {|m| {file: ($m.path | path relative-to $root), line: $m.line} }
  | get 0?
}

# A Markdown table cell: pipes escaped, newlines flattened
export def cell [s] { $s | into string | str replace --all '|' '\|' | str replace --all "\n" ' ' }
