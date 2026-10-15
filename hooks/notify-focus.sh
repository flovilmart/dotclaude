#!/bin/zsh
#
# Click action for notify.sh notifications: bring the Claude session forward.
#
#   notify-focus.sh pane <tmux-socket> <pane-id>   # interactive session in tmux
#   notify-focus.sh attach <session-id> <name>     # background job
#   notify-focus.sh app                            # just raise Ghostty

case "$1" in
pane)
    tmux -S "$2" switch-client -t "$3" \; select-window -t "$3" \; select-pane -t "$3"
    ;;
attach)
    claude=$(command -v claude)
    if tmux list-clients 2>/dev/null | grep -q .; then
        # Reuse a window already attached to this job, else open one.
        existing=$(tmux list-windows -a -F "#{window_name}	#{session_name}:#{window_index}" \
            | awk -F '\t' -v n="cc:$3" '$1 == n { print $2; exit }')
        if [[ -n $existing ]]; then
            tmux switch-client -t "$existing" \; select-window -t "$existing"
        else
            tmux new-window -n "cc:$3" "$claude attach $2"
        fi
    else
        open -na Ghostty --args -e "$claude" attach "$2"
        exit 0
    fi
    ;;
esac

open -a Ghostty
