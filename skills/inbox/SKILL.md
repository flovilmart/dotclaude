---
name: inbox
description: Open every Claude session that is waiting on the user. Use when the user says "inbox", "open the sessions that need input", "what's blocked on me", "which agents are waiting", or "open all waiting sessions". Lists running sessions whose state is blocked and opens them in one tmux window split into a pane per session (or a window each), attached.
argument-hint: "[list | windows]"
allowed-tools: [Bash]
---

# Inbox: the sessions waiting on the user

The work is done by the `inbox` shell command (`~/.claude/nu/shell/inbox.nu`): it reads
`claude agents --json` and keeps running sessions (with a pid) whose `state` is `blocked`.

1. If the argument is `list`, or this session is not inside tmux (`$TMUX` is empty), only list them:

   ```bash
   nu -c 'use ~/.claude/nu/shell/inbox.nu; inbox | to md'
   ```

   Show the table and tell the user to run `inbox open` from their own shell (outside tmux it
   attaches them one after another; ← detaches and moves to the next). Never run `inbox open`
   outside tmux from here: `claude attach` needs the user's terminal.

2. Otherwise open them, adding `--windows` if the argument is `windows`:

   ```bash
   nu -c 'use ~/.claude/nu/shell/inbox.nu; inbox open'
   ```

   By default this opens one tmux window named `inbox`, split into tiled panes, one per session,
   each running `claude attach <id>` and labelled with the session name in its border; with
   `--windows`, a background window per session instead. Sessions already attached in a pane are
   not opened twice. Report how many were opened, by name. If nothing is waiting, say so.
