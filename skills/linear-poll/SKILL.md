---
name: linear-poll
description: "One tick of the Linear poll loop. Finds Todo issues in the team's current cycle, dispatches a background coordinator session (own worktree) for each new one, and wakes coordinators whose clarification questions were answered. Run on a schedule with `/loop 10m /linear-poll` or via `/agent-workflow start`; can also be run once by hand."
argument-hint: "[--dry-run]"
allowed-tools: [Bash, Read, ListAgents, SendMessage, mcp__plugin_linear_linear__list_issues, mcp__plugin_linear_linear__list_cycles, mcp__plugin_linear_linear__get_issue, mcp__plugin_linear_linear__list_comments]
---

# Linear poll — one tick

This runs between the user's turns in the main (dispatcher) session. It must be cheap and must never block: a handful of Linear reads, one script call per new ticket, and a one-line report. Do not fetch descriptions you do not need, do not read code, do not implement anything.

Config: `~/.claude/skills/agent-workflow/config.local.md`. If it does not exist, print one line telling the user to run `/agent-workflow start`, and stop.

`--dry-run` ($ARGUMENTS contains it): do everything except steps 5 and 6's side effects; print what would happen.

## 1. Who am I

Call `ListAgents`. The first line names this session; use it as `<dispatcher>` when dispatching (so coordinators can message back). Fall back to `dispatcher_name` from the config.

## 2. Current cycle

`list_cycles` with `teamId: <team_id>`, `type: current`. Take the first cycle's `id`. No current cycle → report "no active cycle" and stop.

## 3. Candidates

`list_issues` with `team: <team_key>`, `cycle: <cycle id>`, `state: <todo_state>`, `limit: 50`, `fields: [id, title, gitBranchName, labels, assignee, assigneeId, project, url, priority, parentId]`.

Apply `claim_filter`:
- `all`: keep everything.
- `unassigned-or-me`: keep issues with no assignee or assigned to me.
- `assignee:me`: keep only mine.
- `label:<name>`: keep issues carrying that label.

Also drop:
- issues that already carry `needs_spec_label` (mid-clarification, handled in step 6);
- sub-issues whose `parentId` names a ticket that has a coordinator session (any state) — the coordinator works its own subtasks by priority. A sub-issue whose parent has no coordinator is an ordinary ticket.

Order by priority (1 first), then creation. Priority is the only thing that decides who goes first when capacity is short.

## 4. Existing coordinators and capacity

Run `nu ~/.claude/skills/linear-poll/scripts/sessions.nu --json`. Build a map from session `name` → row.

For each candidate `<ID>`:
- No session named `<ID>` → **new**.
- Session with a live `pid` (any state) → **skip** (already working; it will claim the issue shortly).
- Session without `pid` (exited: done, stopped, failed) while the issue is still in `<todo_state>` → **resume** (something stopped it before it claimed).

Capacity = `max_parallel` minus the number of sessions with a live `pid` whose `state` is `working` or `blocked`. Dispatch at most that many new ones this tick; list the rest as "queued (capacity)".

## 5. Dispatch

For each **new** candidate, within capacity:

1. Resolve the repo: first config row matching `project:<name>` (issue `project`), then `label:<name>` (issue `labels`), then `default`.
2. Branch = `gitBranchName`.
3. Run
   ```
   nu ~/.claude/skills/linear-poll/scripts/dispatch.nu <repo> <ID> <branch> --dispatcher <dispatcher> --permission-mode <permission_mode> [--model <model>]
   ```
   and keep the JSON it prints.

For each **resume** candidate: `nu ~/.claude/skills/linear-poll/scripts/resume.nu <ID> "/ticket-workflow <ID> <dispatcher>"`.

Do not claim the issue in Linear here: the coordinator claims it (state → `in_progress_state`, assignment, start comment) as its first action. That keeps a failed dispatch from leaving a ghost "In Progress".

## 6. Clarifications answered

`list_issues` with `team`, `cycle`, `label: <needs_spec_label>`, `fields: [id, updatedAt]`. For each:

1. `list_comments` for the issue, ordered by `createdAt`.
2. Find the newest comment whose body starts with `comment_marker` and contains `Clarifications needed` (the questions), with its `createdAt`.
3. An answer exists if either: a later comment that does **not** start with `comment_marker`, or the issue's `updatedAt` is later than the questions and `get_issue` shows a `## Spec` section in the description.
4. If an answer exists: run `nu .../resume.nu <ID> "Answers posted on <ID>: re-run the spec gate and continue /ticket-workflow"`. If it prints `running <id>`, send that text with `SendMessage` to the session named `<ID>` instead. If `none`, dispatch it as in step 5.

Repeated nudges on later ticks are harmless (identical repeats are dropped by the receiver), but stop after the coordinator removes the label.

## 7. Report

One line when nothing happened: `linear-poll: 0 new, N running, M waiting on spec`. Otherwise up to one line per action:

```
linear-poll (cycle <name>): dispatched ENG-123 (monorepo-wt2, bg 7c5dcf5d), ENG-124 (platform-wt1, tmux: accept trust dialog); queued ENG-125 (capacity); resumed ENG-120; nudged ENG-118 (answers found)
```

Mention `tmux` dispatches explicitly: the user has to accept the trust dialog in that window once.
