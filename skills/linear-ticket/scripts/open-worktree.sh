#!/usr/bin/env bash
# open-worktree.sh <worktree-path> <ticket-id>
# Moves the CURRENT (initiating) claude pane into a new tmux window laid out as:
#   nvim (left, full height) | claude (top-right) | shell (bottom-right)
# The running claude session is physically relocated — no resume, no context loss.

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

# Capture the initiating claude pane BEFORE switching windows
CLAUDE_PANE=$(tmux display-message -p "#{pane_id}")

# Create a new window; its single pane will become the nvim pane
tmux new-window -n "$TICKET_ID" -c "$WORKTREE_PATH"
NVIM_PANE=$(tmux display-message -p "#{pane_id}")
NEW_WINDOW=$(tmux display-message -p "#{window_id}")

# Move the claude pane into the new window as a right-side horizontal split.
# join-pane without -b places src to the RIGHT of the dst pane.
tmux join-pane -h -s "$CLAUDE_PANE" -t "$NVIM_PANE"

# Split the claude pane top/bottom to add the shell below it
tmux split-window -v -c "$WORKTREE_PATH" -t "$CLAUDE_PANE"

# Start nvim in the left pane
tmux send-keys -t "$NVIM_PANE" "nvim ." Enter

# Leave focus on claude (top-right)
tmux select-pane -t "$CLAUDE_PANE"
