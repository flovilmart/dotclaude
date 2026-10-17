---
name: inbox
description: Open the Claude sessions that are waiting on the user, and say what each waits on (needs input, needs plan validation, draft ready, waiting review). Use when the user says "inbox", "open the sessions that need input", "what's blocked on me", "which agents are waiting", or "open all waiting sessions". Opens them in one tmux window split into a pane per session (or a window each), attached.
argument-hint: "[list | all | windows]"
allowed-tools: [Bash]
---

# Inbox: the sessions waiting on the user

The work is done by the `inbox` shell command (`~/.claude/nu/shell/inbox.nu`). It lists running
sessions with a `waiting` column, most urgent first:

- **needs input**: a question to answer (a Linear comment, a blocked slice, a permission prompt)
- **needs plan validation**: the slice plan is posted in Linear for approval
- **draft ready**: a draft PR waits for the user's validation
- **waiting review**: PRs are with a coworker; not on the user

It reads the watcher's `~/.claude/agent-workflow/waiting.json` (refreshed each minute while the watcher
runs) and the coordinators' state files; a session Claude marks blocked with neither is "needs input".

1. If the argument is `list`, or this session is not inside tmux (`$TMUX` is empty), only list them:

   ```bash
   nu -c 'use ~/.claude/nu/shell/inbox.nu; inbox | to md'
   ```

   Show the table grouped by `waiting` and tell the user to run `inbox open` from their own shell
   (outside tmux it attaches them one after another; ← detaches and moves to the next). Never run
   `inbox open` outside tmux from here: `claude attach` needs the user's terminal.

2. Otherwise open them, adding `--all` if the argument is `all` and `--windows` if it is `windows`:

   ```bash
   nu -c 'use ~/.claude/nu/shell/inbox.nu; inbox open'
   ```

   By default this opens the sessions waiting on the user (not `waiting review`) in one tmux window
   named `inbox`, split into tiled panes, each running `claude attach <id>` and labelled
   `<name> · <waiting>` in its border; `--windows` opens a background window per session instead.
   Sessions already attached in a pane are not opened twice. Report how many were opened, by name and
   what they wait on. If nothing is waiting, say so.
