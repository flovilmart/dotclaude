#!/usr/bin/env bash
# agent-log.sh — append one JSON line per hook event to ~/.claude/agent-workflow/log.jsonl
# Wired to SubagentStart, SubagentStop and SessionEnd in settings.json.
# The hook input (session_id, cwd, agent_type, agent_id, ...) is stored verbatim
# under "event"; report.nu turns the log into per-ticket, per-agent metrics.
set -u
input=$(cat)
dir="$HOME/.claude/agent-workflow"
mkdir -p "$dir"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"ts":"%s","event":%s}\n' "$ts" "${input:-null}" >> "$dir/log.jsonl"
exit 0
