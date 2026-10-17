---
name: linear-poll
description: "One tick of the Linear poll loop. Finds Todo issues assigned to me in the current cycle, dispatches a background coordinator session (own worktree) for each new one, wakes coordinators whose clarification questions or plan approvals were answered, relays pull request events (CI, reviews, merges) to coordinators, and restarts coordinators that died mid-ticket. Run on a schedule with `/loop 10m /linear-poll` or via `/agent-workflow start`; can also be run once by hand."
argument-hint: "[--dry-run]"
allowed-tools: [Bash, Read, Write, Agent, ListAgents, SendMessage, mcp__plugin_linear_linear__list_issues, mcp__plugin_linear_linear__list_cycles, mcp__plugin_linear_linear__get_issue, mcp__plugin_linear_linear__list_comments]
---

# Linear poll — one tick

This runs between the user's turns in the main (dispatcher) session. It must be cheap and must never block: a handful of Linear reads, one script call per new ticket, and a one-line report. Do not fetch descriptions you do not need, do not read code, do not implement anything.

Config: `~/.claude/skills/agent-workflow/config.local.md`. If it does not exist, print one line telling the user to run `/agent-workflow start`, and stop.

`--dry-run` ($ARGUMENTS contains it): do everything except the side effects of steps 5 to 9; print what would happen.

## 1. Who am I

Call `ListAgents`. The first line names this session; use it as `<dispatcher>` when dispatching (so coordinators can message back). Fall back to `dispatcher_name` from the config.

## 2. Current cycle

`list_cycles` with `teamId: <team_id>`, `type: current`. Take the first cycle's `id`. No current cycle → report "no active cycle" and stop.

## 3. Candidates

Only issues **assigned to the connected Linear user** are ever picked up. Never widen this to the team.

`list_issues` with `assignee: "me"`, `team: <team_key>`, `cycle: <cycle id>`, `state: <todo_state>`, `limit: 50`, `fields: [id, title, gitBranchName, labels, assignee, assigneeId, project, url, priority, parentId]`.

Drop:
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

## 6. Human answers (clarifications and plan approvals)

Two waits, same mechanics:

| label | question comment contains | wake message |
|-------|---------------------------|--------------|
| `needs_spec_label` | `Clarifications needed` | `Answers posted on <ID>: re-run the spec gate and continue /ticket-workflow` |
| `needs_plan_label` | `Plan for approval` | `Reply on the plan for <ID>: approve or revise, and continue /ticket-workflow` |

For each label, `list_issues` with `assignee: "me"`, `team`, `label: <label>`, `fields: [id, updatedAt]` (no cycle filter for the plan label: a claimed ticket can outlive its cycle). For each issue:

1. `list_comments` for the issue, ordered by `createdAt`.
2. Find the newest comment whose body starts with `comment_marker` and contains the question text from the table, with its `createdAt`.
3. An answer exists if either: a later comment that does **not** start with `comment_marker`, or (spec only) the issue's `updatedAt` is later than the questions and `get_issue` shows a `## Spec` section in the description.
4. If an answer exists: run `nu .../resume.nu <ID> "<wake message>"`. If it prints `running <id>`, send that text with `SendMessage` to the session named `<ID>` instead. If `none`, dispatch it as in step 5.

Repeated nudges on later ticks are harmless (identical repeats are dropped by the receiver), but stop after the coordinator removes the label.

## 7. Pull request events

For each repo in the config's repo table (deduplicated), run
```
nu ~/.claude/skills/linear-poll/scripts/pr-sweep.nu <repo> --since <last tick time, ISO 8601>
```
Last tick time: keep it in `~/.claude/agent-workflow/last-tick.local` (write the current time at the end of every tick; if the file is missing use now minus twice the interval). Group rows by `ticket`; ignore rows with an empty ticket. For each ticket with a coordinator session (running or exited), build **one** message listing only actionable rows:

- `ci: fail` → `PR #N (<branch>): CI failing`
- `review: CHANGES_REQUESTED` → `PR #N: changes requested`
- `changed: true` and state open → `PR #N: new activity since <since>, check comments`
- `draft: false`, state open, `requested` empty, `review` not `APPROVED` and not `CHANGES_REQUESTED` → `PR #N: out of draft, nobody requested (validated by the owner, or a comment-only review)`
- `review: APPROVED`, `ci: pass`, `draft: false`, `autoMerge: false` → `PR #N: approved and green, enable auto-merge if config allows`
- `state: merged` → `PR #N (<branch>): merged at <mergedAt>, sync the stack and close its sub-issue`

Deliver with `resume.nu <ticket> "<message>"`; on `running <id>` use `SendMessage` to the session named `<ticket>`; on `none`, dispatch as in step 5 (the coordinator resumes from its state file and handles the events). Rows with no coordinator and no ticket in this cycle are ignored.

## 8. Stale coordinators

`list_issues` with `assignee: "me"`, `team`, `cycle`, `state: <in_progress_state>`, `fields: [id, labels]`. For each issue without `needs_spec_label`, `needs_plan_label` or `stalled_label` whose `sessions.nu <ID>` shows **no session at all** (not even an exited one; an exited one is handled by `resume.nu`):

1. `list_comments` and count comments starting with `<comment_marker> · <ID> · redispatched`.
2. Fewer than `max_redispatch` → dispatch it as in step 5 and post `<comment_marker> · <ID> · redispatched (<n+1>/<max_redispatch>)`.
3. Otherwise add `stalled_label` and post `<comment_marker> · <ID> · stalled: coordinator died <max_redispatch> times; needs a human (claude logs <ID>)`, and tell the user in the report.

A ticket whose session exists but has exited is resumed by step 4's **resume** path when it is still Todo, and by step 7 when PR events arrive; nothing else restarts it, so an idle finished coordinator stays idle.

## 9. Early spec gate (optional)

When `pre_spec_next_cycle` is true: `list_cycles` `type: next`; `list_issues` with `assignee: "me"`, `cycle: <next id>`, `state: <todo_state>`, `fields: [id, title, description, labels, project]`. For each issue whose description has no `## Spec`, no `needs_spec_label`, and no comment starting with `<comment_marker> · <ID> · Clarifications needed`:

- Delegate **spec-challenger** in the background with a brief (TASK: spec gate for <ID>; GOAL: find out before the cycle starts whether this is buildable; GUARDRAILS: read-only, worktree = the repo's main checkout resolved from the config table; DONE WHEN: SPEC VERDICT report). At most two per tick to keep the dispatcher light.
- On the report (it arrives as a completion notification in a later turn): `NEEDS_CLARIFICATION` → post the questions comment and add `needs_spec_label` exactly as a coordinator would; `READY` → append the draft as `## Spec` to the description. Either way the coordinator that later picks the ticket up re-runs the gate and finds it already answered.

## 10. Report

One line when nothing happened: `linear-poll: 0 new, N running, M waiting on spec, K PRs open`. Finish every tick by writing the current time to `~/.claude/agent-workflow/last-tick.local`. Otherwise up to one line per action:

```
linear-poll (cycle <name>): dispatched ENG-123 (monorepo-wt2, bg 7c5dcf5d), ENG-124 (platform-wt1, tmux: accept trust dialog); queued ENG-125 (capacity); resumed ENG-120; nudged ENG-118 (answers found); PR events → ENG-117 (CI failing #412), ENG-115 (#398 merged); redispatched ENG-119 (2/3)
```

Mention `tmux` dispatches explicitly: the user has to accept the trust dialog in that window once.
