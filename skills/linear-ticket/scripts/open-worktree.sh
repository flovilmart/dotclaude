#!/usr/bin/env bash
# open-worktree.sh <worktree-path> <ticket-id>
# Opens a new tmux window laid out as:
#   nvim (left, full height) | claude (top-right) | shell (bottom-right)
# A new Claude session is launched in the top-right pane, resumed from the
# current session when CLAUDE_SESSION_ID is set (i.e. invoked from within claude).

set -euo pipefail

WORKTREE_PATH="${1:?Usage: open-worktree.sh <worktree-path> <ticket-id>}"
TICKET_ID="${2:?Usage: open-worktree.sh <worktree-path> <ticket-id>}"

if [ -z "${TMUX:-}" ]; then
  echo "Error: must be run inside a tmux session" >&2
  exit 1
fi

if [ ! -d "$WORKTREE_PATH" ]; then
  echo "Error: worktree path does not exist: $WORKTREE_PATH" >&2
  exit 1
fi

# Resume the current session if invoked from within claude, otherwise start fresh
if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
  CLAUDE_CMD="claude --resume ${CLAUDE_SESSION_ID}"
else
  CLAUDE_CMD="claude"
fi

# Create a new window; its single pane will become the nvim pane
tmux new-window -n "$TICKET_ID" -c "$WORKTREE_PATH"
NVIM_PANE=$(tmux display-message -p "#{pane_id}")

# Split right: top-right becomes the claude pane
tmux split-window -h -c "$WORKTREE_PATH" -t "$NVIM_PANE"
CLAUDE_PANE=$(tmux display-message -p "#{pane_id}")

# Split the claude pane top/bottom to add the shell below it
tmux split-window -v -c "$WORKTREE_PATH" -t "$CLAUDE_PANE"

# Start nvim in the left pane
tmux send-keys -t "$NVIM_PANE" "nvim ." Enter

# Start claude in the top-right pane
tmux send-keys -t "$CLAUDE_PANE" "$CLAUDE_CMD" Enter

# Leave focus on claude (top-right)
tmux select-pane -t "$CLAUDE_PANE"
