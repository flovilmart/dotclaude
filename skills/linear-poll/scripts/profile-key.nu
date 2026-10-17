#!/usr/bin/env nu
# profile-key.nu <repo-path> [--dir <cache-dir>]
#
# Tells the coordinator whether the cached repo profile can be reused instead of
# running repo-scout again. Prints one JSON object: {repo, key, path, fresh}
#   path:  the cache file, <dir>/<repo>.md (default dir ~/.claude/agent-workflow/profiles)
#   key:   hash of the git ids of the files a profile is built from (agent docs,
#          workspace manifests, CI config) on origin/<default>, so it changes only
#          when one of those files changes on the default branch
#   fresh: the cache file exists and its first line is `<!-- profile-key: <key> -->`
#
# Package-level AGENTS.md files are not part of the key: agents read those
# themselves when they touch the package.

const SOURCES = [
  AGENTS.md CLAUDE.md CONTRIBUTING.md .claude/rules .worktreeinclude
  package.json pnpm-workspace.yaml turbo.json nx.json Makefile justfile
  pyproject.toml go.mod Cargo.toml .github/workflows
]

def main [repo_path: string, --dir: string = ""] {
  let main_path = (^git -C $repo_path rev-parse --path-format=absolute --git-common-dir | str trim | path dirname)
  let repo = ($main_path | path basename)
  let default_branch = (
    try {
      ^git -C $main_path symbolic-ref refs/remotes/origin/HEAD | str trim | str replace 'refs/remotes/origin/' ''
    } catch { "main" }
  )
  let ref = if ((do { ^git -C $main_path rev-parse --verify --quiet $"origin/($default_branch)" } | complete).exit_code == 0) {
    $"origin/($default_branch)"
  } else { "HEAD" }

  # "<mode> <type> <id>\t<path>" per existing source; a directory is listed as one tree id
  let listing = (^git -C $main_path ls-tree $ref -- ...$SOURCES | str trim)
  let key = ($listing | hash sha256 | str substring 0..<16)

  let cache_dir = if $dir != "" { $dir } else { $"($env.HOME)/.claude/agent-workflow/profiles" }
  let path = $"($cache_dir)/($repo).md"
  let fresh = (($path | path exists) and ((open --raw $path | lines | first 1 | str join) == $"<!-- profile-key: ($key) -->"))
  print ({repo: $repo, key: $key, path: $path, fresh: $fresh} | to json --raw)
}
