f="$HOME/.claude/settings.automode.local.json"
if [ -f "$f" ]; then jq --indent 2 --slurpfile a "$f" '. + {autoMode: $a[0]}'; else cat; fi
