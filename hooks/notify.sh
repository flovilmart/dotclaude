#!/bin/zsh
#
# Notify only when a session is blocked on me; clicking the notification
# brings that session up (tmux pane, or `claude attach` for background jobs).
#
# Usage (hook command, payload on stdin):
#   notify.sh input_required   # Notification hook (permission / elicitation)
#   notify.sh stop             # Stop hook: only fires for background jobs
#                              # whose last message has a `needs input:` line

kind="$1"
payload=$(cat)

session_id=$(jq -r '.session_id // empty' <<<"$payload")
cwd=$(jq -r '.cwd // empty' <<<"$payload")
[[ -z $cwd ]] && cwd=$PWD

if [[ $kind = "stop" ]]; then
    # Interactive sessions: a finished turn isn't news, skip.
    [[ -z $CLAUDE_JOB_DIR ]] && exit 0
    ask=$(jq -r '.last_assistant_message // empty' <<<"$payload" \
        | grep -i -m1 -A2 '^needs input:')
    [[ -z $ask ]] && exit 0
    message=${${ask#*:}# }
else
    message=$(jq -r '.message // "Input required"' <<<"$payload")
fi

here=${${cwd:t}:-session}
branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
[[ -n $branch ]] && here+=" · $branch"

# The click runs under launchd's bare PATH; hand ours over.
focus_sh=~/.claude/hooks/notify-focus.sh
focus="PATH=${(q)PATH} ${(q)focus_sh}"
if [[ -n $CLAUDE_JOB_DIR && -n $session_id ]]; then
    # Background job: attach to it. Name it after the session if we can.
    name=$(claude agents --json 2>/dev/null \
        | jq -r --arg id "$session_id" '.[] | select(.sessionId == $id) | .name // empty')
    [[ -n $name ]] && here="$name · $here"
    click="$focus attach ${(q)session_id} ${(q)${name:-claude}}"
elif [[ -n $TMUX && -n $TMUX_PANE ]]; then
    tmux_info=$(tmux display-message -p -t "$TMUX_PANE" '#S:#I #W')
    here="$tmux_info · $here"
    click="$focus pane ${(q)${TMUX%%,*}} ${(q)TMUX_PANE}"
else
    click="$focus app"
fi

# One notification per session: a newer one replaces the older one.
terminal-notifier \
    -title "Claude Code needs input" \
    -subtitle "$here" \
    -message "$message" \
    -group "claude-${session_id:-$here}" \
    -contentImage ~/.claude/hooks/claude.png \
    -sound Frog \
    -execute "$click" >/dev/null 2>&1 &!

exit 0
