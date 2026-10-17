---
name: inbox
description: Open every Claude session that is waiting on the user. Use when the user says "inbox", "open the sessions that need input", "what's blocked on me", "which agents are waiting", or "open all waiting sessions". Lists running sessions whose state is blocked and opens each in its own tmux window attached to it.
argument-hint: "[list]"
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

2. Otherwise open them:

   ```bash
   nu -c 'use ~/.claude/nu/shell/inbox.nu; inbox open'
   ```

   Each session gets a background tmux window named after it, running `claude attach <id>`;
   sessions already attached in a window are not opened twice, and focus moves to the oldest one.
   Report how many were opened, by name. If nothing is waiting, say so.
