---
name: linear-ticket
description: This skill should be used when the user wants to "work on a linear ticket", "start a ticket", "open a ticket", "pick up a linear issue", or "start working on a Linear issue". It fetches the ticket from Linear, selects or creates a git worktree, and sets up a tmux workspace with nvim, claude, and a shell.
argument-hint: <ticket-id>
allowed-tools: [Bash, Read, Glob, mcp__plugin_linear_linear__get_issue, mcp__plugin_linear_linear__list_issues, mcp__plugin_linear_linear__list_teams]
---

# Working on a Linear Ticket

## Overview

Set up a full dev workspace for a Linear ticket: fetch the issue, wire up the right git worktree, and open a tmux window with nvim (left), claude (top-right), and a shell (bottom-right).

---

## Step 1 — Identify the Ticket

If a ticket ID was passed as an argument (e.g. `ENG-123`), use it directly.

If no ticket ID was given, prompt:
> Which Linear ticket do you want to work on? (e.g. ENG-123)

Once you have the ID, fetch the issue with `mcp__plugin_linear_linear__get_issue` to get:
- Title (used for context and the tmux window name)
- Branch name (`branchName` field — Linear auto-generates this)
- Status and description (for context)

---

## Step 2 — Choose the Repo

Ask the user which repo to work in if not obvious from context:
> Which repo should I open this in?

The user's repos live under `~/src/<org>/`. List repos if helpful:
```bash
ls ~/src/
```

Resolve the full repo root path: `~/src/<org>/<repo>`.
The GitHub org is `<org>` and the repo name is `<repo>` — you'll need both.

---

## Step 3 — Select or Create a Worktree

Worktrees follow the naming convention `<repo>-wt<N>` and live alongside the main repo:
```
~/src/<org>/<repo>        ← main worktree
~/src/<org>/<repo>-wt1   ← worktree 1
~/src/<org>/<repo>-wt2   ← worktree 2
...
```

### 3a — Pick a worktree via tmux popup

Run the bundled picker script. It fetches remote state, checks each `<repo>-wt<N>` worktree's branch for merge status, and opens an interactive fzf picker inside a tmux popup:

```bash
selected_wt=$(nu ~/.claude/skills/linear-ticket/scripts/pick-worktree.nu ~/src/<org>/<repo>)
```

The popup shows:
```
  repo-wt1   feat/ENG-99-old-thing   [free ✓]
  repo-wt2   feat/ENG-87-other       [occupied]
  repo-wt3   feat/ENG-55-stuff       [free ✓]
```

The user picks with arrow keys and Enter. The script prints the absolute worktree path, **or the sentinel value `__new__`** if the user selected "Create new worktree".

If `selected_wt` is `__new__`, skip to step **3c** to create a fresh worktree.

If the script exits with an error (not in tmux, no worktrees found), surface the message and stop.

### 3b — Set up the branch in the chosen worktree

```bash
git -C <worktree-path> fetch origin
```

Then check whether the Linear branch already exists locally:

```bash
git -C <worktree-path> branch --list <linear-branch-name>
```

- **Branch exists** → switch to it: `git -C <worktree-path> switch <linear-branch-name>`
- **Branch does not exist** → create it from `origin/main`: `git -C <worktree-path> switch -c <linear-branch-name> origin/main`

### 3c — Create a new worktree if none are free

If all `<repo>-wt*` worktrees are occupied, add the next index, also from `origin/main`:

```bash
# Determine next index (e.g. wt1 and wt2 exist → create wt3)
git -C ~/src/<org>/<repo> worktree add \
  ~/src/<org>/<repo>-wt<N> \
  -b <linear-branch-name> origin/main
```

Confirm the final worktree path before proceeding.

---

## Step 4 — Open the Tmux Workspace

Run the bundled script with the resolved worktree path and ticket ID:

```bash
bash ~/.claude/skills/linear-ticket/scripts/open-worktree.sh \
  "<absolute-worktree-path>" \
  "<ticket-id>"
```

This opens a new tmux window named after the ticket with:
- **Left pane (full height):** `nvim .` — editor in the worktree root
- **Top-right pane:** `claude --resume <session-id>` — resumes the current Claude session in the worktree (or starts fresh if not invoked from within claude)
- **Bottom-right pane:** shell at the worktree root

The script must be run inside an active tmux session. If not in tmux, warn the user.

---

## Error Cases

- **Not in tmux:** Print a clear error — the script requires `$TMUX` to be set.
- **join-pane fails:** The current pane may already be the only pane in a window with no room to join; surface the tmux error and ask the user to run from a normal pane.
- **Dirty working tree / branch conflict:** Surface the git error and ask the user how to proceed.
- **Linear ticket not found:** Tell the user the ID wasn't found and ask them to double-check.
