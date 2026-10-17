---
name: ticket-workflow
description: "The per-ticket pipeline run by a ticket-coordinator session inside the ticket's worktree — claim the Linear issue, build a repo profile, gate the spec (ask clarifications into the Linear task), plan a stack of small reversible slices, challenge the design, implement each slice XP-style with adversarial review and verification, open stacked PRs, update Linear. Use when a session is started with \"/ticket-workflow <ticket-id> [dispatcher-session]\" or when the user says \"work ticket ENG-123 end to end\"."
argument-hint: "<ticket-id> [dispatcher-session-name]"
allowed-tools: [Agent, Workflow, Bash, Read, Write, Edit, Glob, Grep, ListAgents, SendMessage, Skill, mcp__plugin_linear_linear__get_issue, mcp__plugin_linear_linear__list_issues, mcp__plugin_linear_linear__list_comments, mcp__plugin_linear_linear__save_issue, mcp__plugin_linear_linear__save_comment, mcp__plugin_linear_linear__list_issue_statuses]
---

# Ticket workflow — coordinator pipeline

Ticket = `$0`. Dispatcher session = `$1` (may be empty; then `ListAgents` finds the user's main session, or you simply rely on Linear comments).

You are the coordinator (see the `ticket-coordinator` agent for your contract). Every phase below that says **delegate** is a subagent launched with `run_in_background: true`; you then end your turn with a one-line status and continue when its completion notification arrives. Read the state file first if it exists: `~/.claude/agent-workflow/state/<ticket>.md`; resume from the recorded phase instead of restarting.

Config: `~/.claude/skills/agent-workflow/config.local.yaml` (state names, labels, marker, branch pattern, stack tool, human gates). Every Linear comment you write starts with `<comment_marker> · <ticket> · <phase>`.

## Human gates

The pipeline is autonomous between three human touchpoints. Make each one as cheap as possible for the person:

1. **Plan approval (owner)**, when `plan_approval: human` (the default): the owner approves the slice plan in Linear before any code is written.
2. **Validation (owner)**: every PR stays a draft with a validation packet (`pr-body.md`) until the owner marks it **Ready for review**. That's the owner's sign-off; GitHub doesn't let them approve a PR the agent opened under their account. Nobody else is requested before that.
3. **Approval (coworker)**: once the PR is validated, request the coworker. Auto-merge only after their approval.

Never mark a PR ready yourself, and never request the coworker on a draft.

Repo-specific rules come from the worktree's `AGENTS.md` / `CLAUDE.md` / `CONTRIBUTING.md`; subagents read them too. When they conflict with this skill, the repo wins.

## Delegation brief (every subagent, every time)

Workers refuse a brief that lacks a part (`NEEDS_BRIEF`). Each delegation prompt therefore contains:

```
TASK: <one concrete thing>
GOAL: <the outcome from ## Spec this serves>
GUARDRAILS: <spec Guardrails + repo rules + slice-specific limits + "stop and ask when ...">
DONE WHEN: <end condition + report format>
CONTEXT: <spec, repo profile, slice/sub-issue, branch, base branch, prior findings>
```

A worker that reports `MISALIGNED` stops the pipeline for that subtask until you adjust the brief or escalate to the human. Record the decision in the state file.

Two steps are deterministic and run as **saved workflows** instead of hand-dispatched subagents: the plan (`~/.claude/workflows/plan.js`) and each subtask's inner loop (`~/.claude/workflows/subtask.js`). Call them with the `Workflow` tool and `scriptPath` set to the absolute path (expand `~`). A workflow runs in the background and wakes you with one structured result, so you stay free; the scripts build the four-part brief for every agent from the `args` you pass. Record each run id in the state file: `Workflow({scriptPath, resumeFromRunId})` replays finished stages from cache after a crash.

---

## Phase 0 — Bootstrap and claim

1. `pwd` is the worktree; `git branch --show-current` should be the issue's `gitBranchName`. If not, stop and report (the dispatcher allocates worktrees; do not create one).
2. `get_issue <ticket>` with `fields: [id, title, description, url, gitBranchName, status, labels, assignee, project, attachments]` and `list_comments`. Keep title, description, comments, attachment titles and URLs.
3. If a `## Spec` section exists in the description, note it: it is the authoritative spec.
4. Claim: `save_issue` with `id: <ticket>`, `state: <in_progress_state>` (the issue is already assigned to the user; manual `dispatch` of an unassigned issue also sets `assignee: "me"`). Post comment: `<marker> · <ticket> · started` with the worktree path and `claude attach <ticket>` as the way in.
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
6. **Repo profile, cached per repo.** Run `nu ~/.claude/skills/linear-poll/scripts/profile-key.nu <worktree>`; it prints `{repo, key, path, fresh}`. `fresh: true` → read the profile from `path` (skip the first line) and go to Phase 1 without delegating. Otherwise delegate **repo-scout** (prompt: worktree path) and stop turn.

## Phase 1 — Repo profile

With the profile (from the cache, or from repo-scout's report, which you first write to the cache `path` with the first line `<!-- profile-key: <key> -->` so later tickets on this repo skip repo-scout until its agent docs, manifests or CI config change on the default branch): store it in the state file under "Repo profile". If it lists a setup command, run it now (install deps in the fresh worktree) and confirm the fast checks run. Then go to Phase 2.

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

1. Run the plan workflow and stop your turn:
   ```
   Workflow({ scriptPath: "<home>/.claude/workflows/plan.js",
              args: { ticket, worktree, spec, profile, baseBranch: <gitBranchName>, branchPattern: <slice_branch_pattern>, maxRounds: 2 } })
   ```
   It runs slice-planner, then design-challenger with up to two revision rounds, and returns `{ status, plan, review, rounds, reports }`.
2. On the result:
   - `APPROVED`: store `plan.report` and the slice table in the state file (status `todo` per slice). Go to step 3.
   - `NEEDS_HUMAN` with `openQuestions`: treat them like a clarification round (Phase 2 mechanics: comment, label, message), then re-run the workflow with the answers appended to `spec`.
   - `NEEDS_HUMAN` for any other reason, or `FAILED`: read `reports`, decide, and either re-run with an adjusted brief in `args` or escalate with the exact reason.
3. **Plan approval** (skip when `plan_approval: auto`):
   1. Post comment `<marker> · <ticket> · Plan for approval` with: the slice table (goal, priority, depends on, standalone or stacked, size estimate), the flag and its default, the risks, the design-challenger's open SHOULD findings, and the "not now" list. End with: "Reply **approve** to start implementation. Any other reply is feedback: the plan will be revised and posted again."
   2. `save_issue` → `addLabels: [<needs_plan_label>]`. If a dispatcher is known: `SendMessage` `<ticket>: plan ready for approval` + the slice table in short form.
   3. State file `phase: waiting-plan`, round n. **End your turn.** The poll or the dispatcher wakes you when a reply arrives.
   4. On wake: read the comments after the plan comment. A reply that approves (`approve`, `approved`, `go`, `lgtm`, `ship it`, a 👍 written as text) → remove the label and go to step 4. Anything else is feedback: re-run the plan workflow with `spec` + "Owner feedback on the plan: <reply>" and post the revised plan as round n+1 (back to 3.1), with a line saying what changed.
4. **Create one Linear sub-issue per slice** (when `create_subissues` is true, the default): `save_issue` with `team`, `parentId: <ticket>`, `title: "<ticket> s<n>: <slice goal>"`, `priority` from the plan, the same `cycle` as the parent, `state: <todo_state>`, `assignee: "me"`, and a description holding the slice details (goal, done-when, guardrails, tests first, flag impact, branch name, smoke flag). Add `blockedBy` for dependencies. Record `sub-issue id ↔ slice` in the state file. Post comment `<marker> · <ticket> · plan` on the parent with the slice table (including sub-issue ids) and the flag name.
5. Pick the stacking tool (`/stack-pr` → "Pick the tool once").

## Phase 4 — Work the subtasks by priority

Subtasks are not a fixed sequence. Each pick is a fresh decision, and you may stop between picks (a human may re-prioritise, pause you, or ask for something else).

**Pick.** Re-read the sub-issues (`get_issue` on each recorded id, or `list_issues` with `parentId: <ticket>`): candidates are in `<todo_state>` (or `blocked` in your state file with the blocker now resolved) and every `blockedBy` dependency has a PR (any of `awaiting-validation`, `in-review`; you stack on its branch) or is merged. Choose by Linear **priority** (1 first), then plan order. No candidate left → Phase 5. If every remaining candidate is blocked by an unmerged PR, post `<marker> · <ticket> · waiting on merges` once, update the state file, and end your turn; `/stack-pr sync` and a message ("PR merged") or the next poll nudge brings you back.

**Start.** `save_issue` on the sub-issue: `state: <in_progress_state>`. Branch per `/stack-pr`: if the subtask depends on an unmerged subtask, `add` it on top of that subtask's branch (stacked); otherwise branch from the default branch (standalone). Slice 1 uses the ticket's base branch. Record branch and status `in-progress`.

**Run the subtask workflow** and stop your turn:
```
Workflow({ scriptPath: "<home>/.claude/workflows/subtask.js",
           args: { ticket, branch, base: <previous subtask branch or default branch>, worktree,
                   slice: <slice details from the plan / sub-issue>, spec, profile, flag,
                   security: <security_review == always, or auto and slice.security>, smoke: <smoke_test == always, or auto and slice.smoke>,
                   maxRounds: <max_fix_rounds>, maxLines: <max_slice_lines>, fastModel: <fast_model>, verifyScope: <verify_scope> } })
```
It runs implementer → code-challenger (fix rounds) → verifier (fix rounds, size gate) → security-reviewer and smoke-tester in parallel (fix rounds) → code-challenger again on any fix made after the first review, every agent with a four-part brief, and returns one result:

- `READY`: `commits`, `rounds`, `security`, `smoke`, `reports`, plus the validation packet's inputs: `coverage` (criterion → test), `smokeCriteria` and `smokeEvidence`, `uncertain` and `deviations` (what the owner should check first), `carried` (SHOULD and NIT findings still open), `changedLines`. Go to **Ship**.
- `BLOCKED` (`question`, `stage`): the implementer needs a human decision. Comment on the sub-issue with the precise question, message the dispatcher, mark `blocked`, end turn. On the answer, re-run the workflow with the answer appended to `slice` (use `resumeFromRunId` so finished stages replay from cache).
- `NEEDS_HUMAN` with `stage: size`: the slice is too large to review. Re-plan it into two slices (slice-planner brief scoped to this slice, its commits as the starting point), update the sub-issues, and continue. Don't ship it whole.
- `NEEDS_HUMAN` (`reason`, `stage`, `open`): a gate stayed red after `max_fix_rounds`, or a worker reported `MISALIGNED`. Decide: adjust the brief in `args` and re-run, or escalate with the exact `open` findings or failures. Never ship a draft past an open BLOCKING security finding.
- `FAILED`: an agent returned nothing (API error). Re-run once with `resumeFromRunId`; then escalate.

**Ship.** `/stack-pr submit`: the PR is opened or updated as a **draft**, with the body built from `pr-body.md` (owner block + reviewer part) out of the READY result. Request nobody, and don't mark it ready: that's the owner's sign-off. Attach the PR to the **sub-issue** (`save_issue` with `links: [{url, title}]`) and to the parent. Sub-issue `state: <review_state>`. Slice table: `awaiting-validation` + PR URL. One log line. If a dispatcher is known: `SendMessage` `<ticket> s<n>: ready to validate` + PR URL + the "Check first" bullets.

Don't wait for validation before the next **Pick**: dependent subtasks stack on the draft as usual.

**Loop.** Check for messages (pause, priority change, review feedback). Then **Pick** again. Shipping a subtask and then being asked to do something else is normal; the state file and Linear hold everything needed to pick up later.

If the default branch moved (sync reports conflicts) or a lower PR merged, run `/stack-pr sync` before the next pick; conflicts go to an implementer with a brief.

## Phase 5 — Finalize

1. `/stack-pr sync` and `/stack-pr view`; confirm every PR has the right base. PRs the owner hasn't validated yet stay drafts.
2. `save_issue` → `state: <review_state>` on the parent. Post comment `<marker> · <ticket> · all slices shipped` with the PR list grouped by stack (standalone PRs first, then each stack bottom-up), each marked `to validate` or `in review`, plus the flag name and default.
3. When `auto_merge` is true and the bottom PR is already approved and green, enable auto-merge on it now (see **Approved and green**).
4. Message the dispatcher: `<ticket>: all slices shipped` + the PR list with the same markers.
5. State file: `phase: in-review`. End your turn. Stay alive for PR events and follow-ups; the ticket is done only when every PR is merged (see **Merged**).

## Pull request events (any time after a PR exists)

The poll relays PR events as one message per ticket; humans may also attach and ask. Handle each PR item in its own short cycle, then go back to **Pick** if subtasks remain:

- **Out of draft, nobody requested** (the poll's message for a non-draft PR with no review requested) → if the slice table says `awaiting-validation`, the owner just validated it:
  1. Fold the owner block of the PR body into the collapsed "✅ Validated by @<owner>" `<details>` (`pr-body.md`), keeping ticked boxes.
  2. Request the coworker: the CODEOWNERS for the changed paths, else config `reviewers` (`gh pr edit <n> --add-reviewer <login>`). Nobody found → message the dispatcher once and ask whom to request; set the slice table to `needs-reviewer` and ignore repeats of this event until the owner names someone.
  3. Once a reviewer is requested: slice table `in-review`. One log line.

  If the slice was already `in-review`, a reviewer just submitted a comment-only review: handle it as **Changes requested / new comments**.
- **CI failing** → `gh pr checks <n>` and `gh run view <run-id> --log-failed` for the failing job; delegate **implementer** with the verbatim failure (brief: GUARDRAILS = fix the cause, never skip or weaken the check), then **verifier**; push with `/stack-pr push`/`rebase`. On a PR the owner already validated, apply the cosmetic / behavioural rule from **Changes requested** to the fix. A failure that also fails on the default branch is not this PR's: say so once in a PR comment and move on.
- **Changes requested / new comments** → read every unresolved thread (`gh api repos/{owner}/{repo}/pulls/<n>/comments` and `gh pr view <n> --comments`). Comments from the owner on a draft are part of validation; comments from the coworker are review. Handle both the same way. Delegate **implementer** with the threads (brief: reply per finding `fixed | not fixed (why) | disagree (why)`, and classify each fix as `cosmetic` (rename, comment, formatting, test-only, no behaviour change) or `behavioural`), then **code-challenger** on the new diff, then **verifier**; push; reply on each thread with what changed and the commit sha. Don't resolve threads a human opened: the person who opened a thread resolves it. A disagreement goes to the human as a question, never as a silent skip. Then:
  - PR is a draft (owner validating): update the owner block (new "Check first" items for the fixes) and message the dispatcher `<ticket> s<n>: fixes pushed`.
  - PR was already validated and every fix is `cosmetic`: re-request the coworker (`gh pr edit <n> --add-reviewer <login>`).
  - PR was already validated and any fix is `behavioural`: the owner's validation no longer covers the code. Convert the PR back to draft (`gh pr ready <n> --undo`), restore the owner block with only the criteria the fix touches unticked and the fix listed under "Check first", post one PR comment for the coworker ("back to the owner to re-validate <criteria>; your review is requested again after that"), set the slice table to `awaiting-validation`, and message the dispatcher `<ticket> s<n>: re-validate <criteria>`.
- **Approved and green** → when `auto_merge` is true: `gh pr merge <n> --auto --<merge_method>` (repo docs win on method). Only on a PR the owner validated (not draft, slice table `in-review`). GitHub merges it only once branch protection is satisfied, so human approvals are never bypassed; without branch protection auto-merge would merge on green alone, so the coworker must have approved before you enable it (check `reviewDecision == APPROVED`). Never approve a PR yourself. For a stack, enable auto-merge on the bottom PR only; the next one is enabled after the bottom merges and the stack is synced.
- **Merged** → `/stack-pr sync` (retargets and rebases the PRs above); verify the next subtask still passes (verifier); move the sub-issue to `<done_state>` (`save_issue`); if every sub-issue is done, move the ticket to `<done_state>`, post `<marker> · <ticket> · done` with the merged PR list, release the worktree (`rm -f "$(git rev-parse --absolute-git-dir)/agent-ticket"`, so the allocator can reuse it), set the state file `phase: done`, and end. Otherwise, if a subtask was waiting on this merge, go to **Pick**.

## Follow-ups (messages after Phase 5)

- **Review feedback** pasted by a human: same handling as "changes requested" above.
- **Spec changed**: write the change into `## Spec`, re-run Phase 3 for the remaining (unmerged) slices only.
- **Priority changed / new subtask added by a human** (a sub-issue of this ticket appeared or moved): nothing special; the next **Pick** honours it. A human-added sub-issue without a slice definition gets a mini spec gate (spec-challenger brief scoped to that sub-issue) before implementation.
- **Try** (`try s<n>` from the dispatcher): if a workflow is running, reply that you're busy with s<m> and give the PR's "Try it" commands for the owner's own checkout. Otherwise, with a clean tree: switch to the slice branch, start the app with the repo profile's `Run` command in the background with the flag on, reply with the URL or command and how to flip the flag, and stop the app and switch back when the owner says done or before your next **Pick**.
- **Stop**: ensure the tree is clean and pushed, post `<marker> · <ticket> · paused` with the exact state, end turn.

## Reporting rules

- Every phase change: one line in the state file `## Log`, and the `phase:` field. Slice statuses: `todo` → `in-progress` → `awaiting-validation` ⇄ `in-review` → `merged` (plus `blocked`, and `needs-reviewer` between validation and review).
- Linear comments are for durable facts (questions, plan, PRs, pauses), not progress chatter. One comment per phase at most.
- When a human attaches and asks "where are we", answer from the state file in under ten lines.
- Wakes can repeat: the watcher and the dispatcher may both deliver the same news (an answer, a plan approval). Check it against the state file and Linear, and ignore what you already handled.
