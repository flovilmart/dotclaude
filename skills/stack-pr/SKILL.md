---
name: stack-pr
description: "Stacked pull requests mechanics for one ticket — create the stack, add a branch per slice, submit drafts, mark ready, sync after merges or review fixes. Uses GitHub's native `gh stack` when installed, else manual stacked branches with `gh pr create --base`. Use when the user says \"stack this\", \"open stacked PRs\", \"sync the stack\", or from /ticket-workflow."
argument-hint: "init <branch> | add <branch> | submit | ready <branch> | sync | view"
allowed-tools: [Bash, Read, Grep]
---

# Stacked PRs

Small, reversible changes land faster as a stack: one branch and one PR per slice, each PR based on the one below it, reviewed independently, merged bottom-up. This skill does the git and GitHub mechanics only. The repo's `AGENTS.md` / `CONTRIBUTING.md` wins over anything here (PR template, title format, required labels, whether drafts are used, which stacking tool).

## Pick the tool once per ticket

```
gh extension list | grep -i stack
```

- `github/gh-stack` present (or the repo docs say to use it) → **gh stack** mode. Read `gh stack --help` once; flags below are from the current docs and may differ from your installed version.
- A different tool named by the repo docs (Graphite `gt`, git-spice `gs`, …) → follow the docs; do not install anything else.
- Nothing → **manual** mode. Say once that `gh extension install github/gh-stack` would enable native stacks; do not install it yourself.

Record the choice in the ticket state file.

## Standalone or stacked

A subtask that depends on an unmerged subtask is stacked on that subtask's branch. A subtask with no unmerged dependency branches from the default branch and gets a standalone PR, even in the middle of a ticket. One ticket can therefore own several small stacks plus standalone PRs; each PR is attached to its Linear sub-issue. Stack only what truly depends.

## Naming

- Stack base = Linear's `gitBranchName` (already checked out in the worktree); it is slice 1's branch.
- Slice n branch = `<gitBranchName>-s<n>-<slug>` (config `slice_branch_pattern`). Keeping the issue key in every branch name lets Linear link every PR to the issue.
- PR title = repo convention, else `<Ticket>: <slice goal>` and, for n > 1, suffix ` (<n>/<total>)`.
- PR body = repo template if any; otherwise: what this slice does, how to verify, flag name and default, the slice's position in the stack, link to the Linear issue.

## gh stack mode

| action | command |
|--------|---------|
| init on existing base branch | `gh stack init <gitBranchName>` (adopts the existing branch; trunk = default branch) |
| add a dependent slice (run from the branch it depends on, the top of that stack) | `gh stack add <branch>` |
| start a standalone slice | `git switch -c <branch> origin/<default>`; it is its own one-branch stack (`gh stack init <branch>` when you later stack on it) |
| push + create/update draft PRs | `gh stack submit --auto` (drafts) |
| mark a slice ready | `gh pr ready <branch>` |
| after trunk moved or a lower PR merged | `gh stack sync` (fetch, fast-forward trunk, cascade rebase, push, relink PRs) |
| after review fixes on a lower slice | commit on that branch, then `gh stack rebase` (cascades upward) and `gh stack push` |
| show | `gh stack view --short` |

Conflicts during `sync` / `rebase`: stop, delegate resolution to an `implementer` with the conflict context, then `gh stack rebase --continue`. Never `--abort` silently; report.

## Manual mode

| action | command |
|--------|---------|
| init | nothing (base branch exists) |
| add slice n | `git switch -c <branch-n> <branch-n-1>` |
| push | `git push -u origin <branch>` |
| create PR | `gh pr create --draft --base <branch-n-1> --head <branch-n> --title "..." --body-file <tmp>` (slice 1: `--base <default branch>`) |
| mark ready | `gh pr ready <branch>` |
| sync after default branch moved | `git fetch origin`; rebase slice 1 on `origin/<default>`, then each slice on the previous (`git rebase --onto <new-prev> <old-prev> <branch>`); `git push --force-with-lease` each |
| after a lower PR merges | retarget the next PR: `gh pr edit <branch-n+1> --base <default>`; then rebase the rest as above |

Force-pushes are allowed only on the stack's own branches, always `--force-with-lease`, never on the default branch.

## Always

- Push and submit after every verified slice; do not batch the whole stack at the end. Early drafts give reviewers the shape of the change.
- Record `branch → PR URL` for each slice in the ticket state file and attach the PR links to the Linear issue (`save_issue` with `links`), one per PR.
- Before marking the last slice ready, run `sync`/`view` and confirm every PR's base is correct.
