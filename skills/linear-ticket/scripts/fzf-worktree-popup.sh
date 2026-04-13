#!/usr/bin/env bash
# fzf-worktree-popup.sh <tmplist> <tmpsel>
# Runs fzf over the worktree list and writes the selected line to tmpsel.
# Executed inside a tmux display-popup — receives a real PTY.

fzf --ansi \
    --delimiter=$'\t' \
    --with-nth=2,3,4 \
    --prompt='Worktree > ' \
    --reverse \
    --info=hidden \
    < "$1" > "$2"
