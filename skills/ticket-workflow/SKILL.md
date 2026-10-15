---
name: ticket-workflow
description: "The per-ticket pipeline run by a ticket-coordinator session inside the ticket's worktree — claim the Linear issue, build a repo profile, gate the spec (ask clarifications into the Linear task), plan a stack of small reversible slices, challenge the design, implement each slice XP-style with adversarial review and verification, open stacked PRs, update Linear. Use when a session is started with \"/ticket-workflow <ticket-id> [dispatcher-session]\" or when the user says \"work ticket ENG-123 end to end\"."
argument-hint: "<ticket-id> [dispatcher-session-name]"
allowed-tools: [Agent, Bash, Read, Write, Edit, Glob, Grep, ListAgents, SendMessage, Skill, mcp__plugin_linear_linear__get_issue, mcp__plugin_linear_linear__list_comments, mcp__plugin_linear_linear__save_issue, mcp__plugin_linear_linear__save_comment, mcp__plugin_linear_linear__list_issue_statuses]
---

# Ticket workflow — coordinator pipeline

Ticket = `$0`. Dispatcher session = `$1` (may be empty; then `ListAgents` finds the user's main session, or you simply rely on Linear comments).

You are the coordinator (see the `ticket-coordinator` agent for your contract). Every phase below that says **delegate** is a subagent launched with `run_in_background: true`; you then end your turn with a one-line status and continue when its completion notification arrives. Read the state file first if it exists: `~/.claude/agent-workflow/state/<ticket>.md`; resume from the recorded phase instead of restarting.

Config: `~/.claude/skills/agent-workflow/config.local.md` (state names, label, marker, branch pattern, stack tool). Every Linear comment you write starts with `<comment_marker> · <ticket> · <phase>`.

Repo-specific rules come from the worktree's `AGENTS.md` / `CLAUDE.md` / `CONTRIBUTING.md`; subagents read them too. When they conflict with this skill, the repo wins.

---

## Phase 0 — Bootstrap and claim

1. `pwd` is the worktree; `git branch --show-current` should be the issue's `gitBranchName`. If not, stop and report (the dispatcher allocates worktrees; do not create one).
2. `get_issue <ticket>` with `fields: [id, title, description, url, gitBranchName, status, labels, assignee, project, attachments]` and `list_comments`. Keep title, description, comments, attachment titles and URLs.
3. If a `## Spec` section exists in the description, note it: it is the authoritative spec.
4. Claim: `save_issue` with `id: <ticket>`, `state: <in_progress_state>`, and `assignee: "me"` when `assign_on_claim` is true. Post comment: `<marker> · <ticket> · started` with the worktree path and `claude attach <ticket>` as the way in.
5. Write the state file:
   ```
   # <ticket> — <title>
   phase: bootstrap
   worktree: <path>   base_branch: <gitBranchName>   default_branch: <main>
   dispatcher: <name>
   ## Spec verdict
   ## Repo profile (summary)
   ## Plan
   ## Slices
   | # | branch | status | PR |
   ## Log
   - <timestamp> claimed
   ```
6. Delegate **repo-scout** (prompt: worktree path, ticket title, the area the ticket points at). Stop turn.

## Phase 1 — Repo profile

On repo-scout's report: store the full report in the state file under "Repo profile". If it lists a setup command, run it now (install deps in the fresh worktree) and confirm the fast checks run. Then go to Phase 2.

## Phase 2 — Spec gate

Delegate **spec-challenger** with: the issue (title, description, all comments, attachment list), the repo profile, the worktree path. Stop turn.

On its report:

- **NEEDS_CLARIFICATION**:
  1. Post comment `<marker> · <ticket> · Clarifications needed` with the numbered questions, each with "why it matters" and "proposed default", followed by "Reply here, or edit the `## Spec` section of this issue. Defaults apply if you say 'go with defaults'."
  2. `save_issue` → `addLabels: [<needs_spec_label>]`.
  3. If a dispatcher is known: `SendMessage` to it: `<ticket>: needs clarification` + the questions (short form) + "answer in your session (/agent-workflow clarify <ticket>) or in Linear".
  4. Update state (`phase: waiting-spec`, round n). **End your turn.** You will be woken by a message ("Spec updated…" / "Answers posted…") or by the user attaching.
  5. On wake: re-fetch the issue and comments; if answers are in comments but not yet in the description, write the `## Spec` section yourself from the draft spec plus the answers (`save_issue` with `patch` append or replace of the existing `## Spec` range). Remove the label (`removeLabels`). Re-run the spec gate (back to the top of Phase 2). After three rounds, stop asking: adopt the proposed defaults, write them as `Assumptions:` in the spec, post a comment saying so, and continue.
- **READY**: if the description has no `## Spec`, append the draft spec as `## Spec` (specs live in the task). Record `spec: READY` in the state file. Go to Phase 3.

## Phase 3 — Plan and challenge

1. Delegate **slice-planner** with the spec, the repo profile, the worktree path, and the branch pattern. Stop turn.
2. On the plan: delegate **design-challenger** with the plan, the spec, the repo profile. Stop turn.
3. On the review:
   - **REVISE**: delegate **slice-planner** again with the blocking findings ("revise the plan to address these; keep what was not challenged"). Then design-challenger again. At most two revision rounds; after that, you decide and record why.
   - **APPROVE**: store the final plan in the state file (the slice table becomes the `## Slices` table with status `todo`). Post comment `<marker> · <ticket> · plan` with the slice table and the flag name. If the plan lists "Open questions for the human (blocking)", treat them like a clarification round (Phase 2 mechanics) before implementing.
4. Pick the stacking tool (`/stack-pr` → "Pick the tool once") and run its `init` on the base branch.

## Phase 4 — Implement the stack, one slice at a time

For slice n = 1..N (sequential; each slice builds on the previous one):

1. **Branch.** Slice 1 uses the base branch. For n > 1: `/stack-pr add <gitBranchName>-s<n>-<slug>` from the top of the stack. Record the branch in the slice table, status `in-progress`.
2. **Implement.** Delegate **implementer** with: the slice definition, the spec, the repo profile, the branch name, the flag name, and "commit on this branch only". Stop turn.
   - `BLOCKED` → relay the precise question to the user (comment on the issue + message dispatcher), mark the slice `blocked`, end turn. On the answer, re-delegate with the answer.
3. **Challenge.** Delegate **code-challenger** with the branch, its base branch (previous slice or default), the spec, the slice definition. Stop turn.
   - `REQUEST_CHANGES` → delegate **implementer** with the BLOCKING and SHOULD findings ("apply these review findings on branch X; reply per finding"). Then code-challenger again on the new diff. Up to three rounds; after that, you decide which findings are truly blocking, record the decision, and continue. NITs are carried into the slice's next push, never a reason to loop.
4. **Verify.** Delegate **verifier** with the branch and the repo profile. Stop turn.
   - `FAIL` → delegate **implementer** with the verbatim failure ("make the checks pass without weakening them"). Then verifier again. Up to three rounds, then escalate to the human with the exact failing output.
   - Formatter changed files → implementer commits them.
5. **Ship the slice.** `/stack-pr submit` (draft), then `/stack-pr ready <branch>`. Attach the PR link to the Linear issue (`save_issue` with `links: [{url, title: "<n>/<N> <slug>"}]`). Slice table: status `pr-open`, PR URL. Log line.
6. Next slice.

If the default branch moved under you (sync reports conflicts) or a lower PR merged mid-way, run `/stack-pr sync` before the next slice; conflicts go to an implementer.

## Phase 5 — Finalize

1. `/stack-pr sync` and `/stack-pr view`; confirm every PR has the right base and is ready (not draft).
2. `save_issue` → `state: <review_state>`. Post comment `<marker> · <ticket> · ready for review` with the ordered PR list, flag name and default, and "merge bottom-up; run `gh stack sync` (or ask me) after each merge".
3. Message the dispatcher: `<ticket>: ready` + the PR list.
4. State file: `phase: in-review`. End your turn. Stay alive for follow-ups.

## Follow-ups (messages after Phase 5)

- **Review feedback** ("address comments on PR 2", or a pasted review): delegate implementer on that slice's branch with the findings, then code-challenger, verifier, `/stack-pr rebase`/`push` (cascade), and reply on the Linear issue with what changed.
- **Spec changed**: write the change into `## Spec`, re-run Phase 3 for the remaining (unmerged) slices only.
- **Lower PR merged**: `/stack-pr sync`; verify the next slice still passes; report.
- **Stop**: ensure the tree is clean and pushed, post `<marker> · <ticket> · paused` with the exact state, end turn.

## Reporting rules

- Every phase change: one line in the state file `## Log`, and the `phase:` field.
- Linear comments are for durable facts (questions, plan, PRs, pauses), not progress chatter. One comment per phase at most.
- When a human attaches and asks "where are we", answer from the state file in under ten lines.
