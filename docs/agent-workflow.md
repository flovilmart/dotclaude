# Agent workflow: Linear → worktree → stacked PRs

A Linear ticket **assigned to you** in the current cycle's **Todo** column becomes, without anyone typing, a dedicated
coordinator session in its own git worktree, a spec gate that asks you only the questions that
matter, a plan of small reversible slices challenged before code exists, XP-style implementation with
an adversarial reviewer and a verifier per slice, and a stack of pull requests on GitHub. Your main
session only dispatches and relays, so it stays free.

It's autonomous between three human touchpoints, and it's built to make each one fast:

| when | who | what you get | your action |
|------|-----|--------------|-------------|
| before any code | you | the slice plan as a Linear comment | reply `approve`, or feedback to revise it |
| each slice is done | you | a **draft** PR, and a validation note on the Linear sub-issue: acceptance criteria → test → smoke evidence, "check first" items where the agent was unsure, commands to try it | review comments if needed, then **mark it Ready for review** (your sign-off) |
| after your validation | coworker | the coworker is requested on a PR whose body says in 2-3 sentences what it does and its caveats | approve → GitHub auto-merges |

You validate by marking the PR ready because GitHub doesn't let you approve a PR the agent opened
under your account. A coworker fix that changes behaviour sends the PR back to you for re-validation
of just the affected criteria. `/agent-workflow status` lists everything **waiting on you**, oldest first.

```
 you ──▶ main session ("dispatcher")              one process, always free
            │  Monitor ← follow.nu ← events.log ← watch.nu (tmux window aw-watcher)
            │        nushell: polls Linear + GitHub every minute, dispatches itself,
            │        and writes a line only when the dispatcher is needed
            │
            ├─▶ claude --bg --name ENG-123 --agent ticket-coordinator   (worktree monorepo-wt2)
            │        │ /ticket-workflow ENG-123 dispatcher
            │        ├─ repo-scout        → repo profile (commands, flags, conventions from AGENTS.md)
            │        ├─ spec-challenger   → READY | questions  ──▶ Linear comment + label + message to you
            │        ├─ slice-planner ⇄ design-challenger      → stack plan ──▶ you approve ──▶ Linear sub-issues
            │        └─ per subtask: implementer ⇄ code-challenger → verifier → security-reviewer + smoke-tester → re-review of late fixes
            │                        → draft PR + validation note ──▶ you mark ready ──▶ coworker requested ──▶ approves → auto-merge → sub-issue Done
            │
            └─▶ claude --bg --name ENG-124 ...                           (worktree platform-wt1)
```

The coordinator's own turns are short: dispatch, wait for the completion notification, decide,
dispatch again. Steps that involve humans or Linear (claim, spec gate, sub-issues, PR events) are
background subagents it steers; the two deterministic steps, planning and the per-subtask inner loop,
are saved workflows (`workflows/plan.js`, `workflows/subtask.js`) that return one structured result
each, with retries and parallel gates as code rather than as model decisions. You can `claude attach ENG-123`
at any time and talk to it; it answers from its state file and resumes.

## Pieces

| Path | Role |
|------|------|
| `skills/agent-workflow/` | Control plane in the main session: `start`, `status`, `stop`, `dispatch <id>`, `clarify <id>`. Holds `config.example.yaml` (every key, commented); your copy is `config.local.yaml` (gitignored), validated by `skills/linear-poll/scripts/config.nu check`; `config.nu migrate` converts an old `config.local.md`. |
| `skills/linear-poll/` | Handles the watcher's events in the dispatcher: relay to a coordinator, early spec gate, tell you. |
| `skills/linear-poll/scripts/watch.nu` | The poll, in nushell: Linear (GraphQL, key via `op read`), sessions and PRs every minute in working hours; acts through `dispatch.nu` / `resume.nu`; writes `send` / `spec-gate` / `tell` / `info` lines to stdout and `events.log`, and `waiting.json` (what each ticket waits on, `rules.nu ticket-waits`). Runs on its own in a tmux window (default) or once per cron tick (`--once`). `--check` tests the key and queries; `--dry-run` shows what it would do. |
| `skills/linear-poll/scripts/follow.nu` | Under the Monitor tool: delivers each new line of `events.log` to the dispatcher exactly once (a cursor survives re-arms), and says when the watcher has stopped. |
| `skills/linear-poll/scripts/rules.nu`, `config.nu`, `linear.nu` | The poll's rules as pure functions (tested), the config reader, the Linear GraphQL calls and auth. |
| `nu/shell/linear.nu` | The `linear` shell command (autoloaded): `login` checks a personal API key you paste and stores it in 1Password at `linear_api_key_ref` (an API Credential item, created or updated with `op item`); `status` says whether the key can be read, never printing it; `me`, `issues`. |
| `nu/shell/inbox.nu`, `skills/inbox` | The `inbox` shell command (autoloaded) and `/inbox`: running sessions with what each waits on — **needs input** (a question: Linear clarifications, a `blocked` slice, a permission prompt), **needs plan validation**, **draft ready**, **waiting review** (a coworker's turn) — from the watcher's `waiting.json` and the state files. `inbox open` opens those waiting on you (`--all`: also waiting review) in one tmux window `inbox`, a tiled pane each labelled `<name> · <waiting>` (`--windows`: a window each); never twice; outside tmux it attaches them one after another. |
| `skills/control-center` | A mod (auto-loaded from the skills folder): `/control` opens a live **Agents** pane in the session (the dispatcher's), refreshed every 15 s from `inbox board`: every running background agent grouped needs input → needs plan validation → draft ready → working → waiting review → done, with age, detail and PR links. Pressing an agent brings it up in tmux (`inbox attach`), `o` opens everything on you (`inbox open`), `r` refreshes; the status line keeps `agents: 2 input · 1 plan · 3 draft`, and a toast says when an agent starts waiting on you. `claude plugin test skills/control-center` runs its tests. Claude's own `claude agents` view can't carry custom labels (fixed columns, no status API), hence this pane. |
| `skills/linear-poll/scripts/*.nu` | `ensure-worktree.nu` (sibling `<repo>-wt<N>` pool, same convention as `linear-ticket`), `dispatch.nu` (worktree + `claude --bg`, named `<ticket> · <short title>` by `names.nu`), `sessions.nu` (wraps `claude agents --json --all`), `resume.nu` (wake a stopped coordinator). |
| `skills/ticket-workflow/` | The per-ticket pipeline the coordinator runs. `pr-body.md`: the short PR body for the coworker, and the owner's validation note (a Linear comment). |
| `skills/stack-pr/` | Stacked PR mechanics: GitHub native `gh stack` when installed, manual `gh pr create --base` otherwise. |
| `workflows/plan.js`, `workflows/subtask.js` | Saved workflows the coordinator runs with the `Workflow` tool: the plan with bounded design-challenge rounds, and each subtask's implement → review → verify (with a slice size gate) → security + smoke loop with bounded fix rounds, ending with a code review of every fix made after the first review. One structured result per run; resumable from cache. `workflows/test/` runs both offline against scripted agents (`node --test`). |
| `agents/ticket-coordinator.md` | Main agent of each coordinator session (`--agent ticket-coordinator`): orchestrates, never implements. |
| `agents/repo-scout.md` | Reads AGENTS.md / CLAUDE.md / manifests / CI → repo profile. |
| `agents/spec-challenger.md` | Definition of ready; drafts the `## Spec`; asks at most five questions with defaults. |
| `agents/slice-planner.md` | Ordered stack of small, independently revertable slices; tests first; flag strategy. |
| `agents/design-challenger.md` | Breaks the plan before code: reversibility, coupling, tests, flags, simpler design. |
| `agents/implementer.md` | One slice, red → green → refactor, tiny commits, repo checks before each commit. |
| `agents/code-challenger.md` | Adversarial diff review against spec and plan. |
| `agents/verifier.md` | Runs the repo's real quality gates and reports verbatim. |
| `agents/security-reviewer.md` | Dependency audit, secret scan, diff review for authz/injection/exposure; blocks a PR leaving draft. |
| `agents/smoke-tester.md` | Starts the app the repo's way and exercises the slice's acceptance criteria, flag off and on, with evidence. |
| `skills/linear-poll/scripts/profile-key.nu` | Whether the cached repo profile (`~/.claude/agent-workflow/profiles/<repo>.md`) is still valid: a key over the agent docs, manifests and CI config on the default branch. A fresh profile skips repo-scout. |
| `skills/linear-poll/scripts/pr-sweep.nu` | Open and recently merged PRs by ticket with CI, review and auto-merge state; feeds PR events to coordinators. |
| `skills/linear-poll/scripts/selftest.nu` | Offline scenario tests (temp repo, no network): worktree allocator and holds, profile key, branch parsing, the watcher and follow.nu end to end with a fake `claude`; then runs the `@test` files and the workflow tests (when node is installed). |
| `.github/workflows/ci.yml` | Runs `selftest.nu` on every push to main and every PR: Ubuntu with the oldest supported nushell (`MIN_NU`) and the latest, and macOS. Failures are annotated at their line (in PRs, on the diff) and each job's summary has a table per test file and per selftest section. |
| `nu/gha.nu` | GitHub Actions output from nushell: annotations with workflow-command escaping, the job summary, and a failure's file and line from a rendered nushell error. No-op outside Actions. |
| `nu/run-tests.nu`, `**/tests/*.nu` | Unit tests in nushell's standard style: `@test` commands (with `@ignore`, `@before-each`/`@before-all`, `@after-each`/`@after-all`) from `std/testing`, which ships the markers but no runner; `run-tests.nu` finds them with `scope commands` and runs each file in its own process. Covers the poll rules, the config reader, the Linear key handling (with a fake `op`), the shell commands and the runner itself. |
| `hooks/agent-log.sh` + `skills/agent-workflow/scripts/report.nu` | One JSON line per subagent start/stop and session end; `/agent-workflow report` turns it into per-ticket, per-agent run counts and minutes. |

All agents are generic. Repository specifics come from the repo's `AGENTS.md` (or `CLAUDE.md`,
`CONTRIBUTING.md`), which every agent reads first and which wins on conflict. Note that Claude Code
loads `AGENTS.md` automatically only when the repo has no `CLAUDE.md`; a `CLAUDE.md` containing
`@AGENTS.md` loads both.

## Setup

1. Start a **dedicated** dispatcher session with a stable name, in its own tmux window, from any directory:
   ```nu
   claude --name dispatcher
   ```
   Don't do other work in it: every watcher event re-sends the whole conversation, so a long working
   session makes every event expensive. Talk to it only for workflow commands.
2. `/agent-workflow start`. First run asks a few questions (team, state names, repo paths,
   coordinator permission mode and model, poll schedule). Only issues assigned to you are ever polled and writes
   `~/.claude/skills/agent-workflow/config.local.yaml`. It then creates the poll cron.
3. Optional but recommended: `gh extension install github/gh-stack` for native stacks.
4. First dispatch into a brand-new worktree directory may need the workspace trust dialog. The
   dispatcher then opens a tmux window with the coordinator running interactively; accept once, press
   `←` or `/background` to detach. Later dispatches to that worktree go straight to the background.

## Clarifications

When the spec-challenger finds the ticket under-specified, the coordinator posts a numbered list of
questions (each with why it matters and a proposed default) as a Linear comment, labels the issue
`needs-spec`, and messages the dispatcher. Answer either way:

- in Linear: reply in the thread or edit the issue. The watcher notices within a minute and wakes the coordinator.
- in the main session: just answer in prose, then `/agent-workflow clarify ENG-123` (or the dispatcher
  does it when it recognises the answer). It writes a `## Spec` section into the issue description,
  removes the label, and wakes the coordinator.

Either way the spec ends up **in the Linear task**, which is the only place the pipeline reads it from.
After three unanswered rounds the coordinator adopts the proposed defaults, records them as
assumptions in the spec, and continues.

## Closing the loop

- **PR events.** Every other watcher cycle (about every 2 minutes) runs `pr-sweep.nu` per repo and sends each
  coordinator one message with what newly changed on its PRs (each condition is reported once): CI failing, merge conflicts, changes requested, new comments, approved and green, merged. The
  coordinator fixes CI from the failing job's log, rebases and resolves merge conflicts right away, applies review threads and replies on each, re-requests
  the reviewer, and after a merge syncs the stack and moves the Linear sub-issue to Done. When every
  sub-issue is merged the ticket goes to Done.
- **Human review stays, in two steps.** The coordinator never marks a PR ready and never approves one. You
  validate each draft (mark it ready); then the coworker from CODEOWNERS or config `reviewers` is requested.
  With `auto_merge: true` the coordinator enables GitHub auto-merge on a validated, approved, green PR
  (bottom of the stack first); GitHub merges only once branch
  protection, including your required reviews, is satisfied. Put required reviews in branch protection
  on each repo, or leave `auto_merge: false`.
- **Gates before you see a draft**: verifier (lint, types, tests, slice size), security-reviewer (audit, secrets,
  diff review, `/security-review` when available) and, for user-visible or integration slices, a
  smoke-tester that runs the app and exercises the acceptance criteria with the flag off and on. Every
  commit has passed an approving code-challenger review, including fixes made for the verifier or the gates.
- **Dead coordinators.** A ticket In Progress with no session at all is re-dispatched (the coordinator
  resumes from its state file), up to `max_redispatch` times, then labelled `agent-stalled` with a comment.
- **Observability.** Hooks append every subagent start/stop and session end to
  `~/.claude/agent-workflow/log.jsonl`; `/agent-workflow report` summarises runs and minutes per ticket
  and agent, so review churn and slow steps are visible. For a live view in a terminal, run
  `nu ~/.claude/skills/agent-workflow/scripts/tui.nu` (overview, agents, worktrees, timeline, recent and
  running agents; `w` cycles the time window, `q` quits). Token cost is not in the hook payload; use
  `/cost` in a coordinator or your usage dashboard for that.
- **Tests.** `/agent-workflow start` runs `selftest.nu` once (temp repo, no network). It fails first on a
  nu older than `MIN_NU`, since nushell still makes breaking changes between releases. Run it after any
  change to the scripts and after upgrading nushell. The pipeline itself is best dry-run on a sandbox repo with
  `/agent-workflow dispatch <demo ticket>`.
- **Early spec gate** (`pre_spec_next_cycle: true`): the poll also runs the spec-challenger on your Todo
  issues in the next cycle, so clarification questions reach you before the cycle starts.
- **Worktree holds**: a dispatched ticket holds its worktree (`agent-ticket` in the worktree's git dir) until
  the ticket is done, so a merged slice never makes a busy worktree look free. A ticket that is abandoned
  or stalled keeps its hold; delete that file to free the worktree.
- **Fresh worktrees**: `ensure-worktree.nu` honours the repo's `.worktreeinclude` (copies gitignored
  files such as `.env` into a new worktree). A worktree is reused only when its tree is clean and its
  branch is finished: the remote branch is merged into the default branch, or it was pushed and GitHub
  has since deleted it. Turn on "Automatically delete head branches" in each repo so squash-merged
  branches free their worktree.

## Day to day

```nu
claude agents                       # live view of every coordinator; Space to peek and reply
claude attach ENG-123               # take over a coordinator's terminal; ← to detach
claude logs ENG-123                 # recent output
/agent-workflow status              # in the dispatcher: waiting on you (validate, approve plan, answer), then coordinators, cron, PRs
/agent-workflow approve ENG-123     # approve the plan (or: approve ENG-123 merge slices 2 and 3)
/agent-workflow try ENG-123 s2      # the coordinator runs the slice's app with the flag on for you to click through
/agent-workflow dispatch ENG-130    # push one ticket through regardless of cycle or state
/agent-workflow stop                # remove the poll cron (coordinators keep running)
/usage                              # in the dispatcher: Loops shows what the poll costs
```

A coordinator that is idle and unattached for about an hour is stopped by the supervisor; its
conversation is kept, and the watcher (when there is news for it) or `claude attach` restarts it where it left off.

## Briefs, subtasks and priority

- **Every worker needs a brief** with Task, Goal, Guardrails and Done-when, or it answers `NEEDS_BRIEF`
  and does nothing. The coordinator writes the brief from the ticket's `## Spec` (which has its own
  `Guardrails:` line, asked for at the spec gate) plus the repo's rules. A worker that sees the task
  drift from the goal reports `MISALIGNED` instead of improvising.
- **Slices are Linear sub-issues.** After the plan is approved the coordinator creates one sub-issue per
  slice under the ticket (priority, dependencies, slice details in the description). Each sub-issue gets
  its own branch and PR, attached to the sub-issue.
- **Work is picked by priority, not in a fixed sequence.** After each subtask ships, the coordinator
  re-reads the sub-issues and picks the highest-priority unblocked one. You can re-prioritise or add
  sub-issues in Linear at any time; nothing has to be finished in one go. Subtasks that depend on an
  unmerged subtask are stacked; independent ones branch from the default branch as standalone PRs.
- Across tickets, the poll loop dispatches by Linear priority within `max_parallel`.

## Cost and speed

Where the tokens and the minutes go, and what keeps them down:

- **The poll costs no tokens** while nothing happens: `watch.nu` polls Linear and GitHub in nushell and
  wakes the dispatcher only for a line it must act on. The `follow.nu` Monitor is re-armed every 30
  minutes, a small turn; the watcher itself keeps running and reads the API key once. Keep the dispatcher session dedicated anyway: every event and re-arm re-sends its context.
  Linear allows 2,500 requests an hour per API key; the watcher uses about 60–120.
- **Models by stage**: the coordinator and the mechanical stages (verify, smoke, formatter fixes) run on
  `sonnet` at low effort (`model`, `fast_model`); judgement stages (spec, plan, design challenge,
  implement, code review, fixes for failing checks, security) inherit your default model.
- **Verification is scoped** to the packages changed since the base (`verify_scope: affected`); CI runs
  the full suite on the PR, and failures come back through the poll.
- **Fix rounds carry blocking findings only**; SHOULD and NIT go to your validation note.
- **Gates where they matter**: the planner flags slices for smoke and security; the second
  `/security-review` pass runs only on request.
- **Repo profiles are cached** per repo until agent docs, manifests or CI config change.

## Design choices and limits

- **State lives in Linear and git**, not in the dispatcher's memory. States (`Todo` → `In Progress` →
  `In Review`), the `needs-spec` label, comments prefixed with `🤖 agent-workflow`, and PR links are
  the record. A coordinator also keeps `~/.claude/agent-workflow/state/<ticket>.md` to survive
  compaction. Nothing else is persisted, so there is no ledger to corrupt.
- **The coordinator claims the issue, not the poller**, so a failed dispatch never leaves a ghost
  "In Progress" ticket.
- **One subtask at a time per ticket** (a coordinator runs one implementer at a time so a ticket's PRs
  stay coherent). Parallelism comes from running several tickets at once (`max_parallel`).
- **Coordinators run in `auto` permission mode by default** so they do not stall on prompts. Use
  `acceptEdits` if auto mode is unavailable; then pre-approve the repo's commands in that project's
  `.claude/settings.json` or expect `Needs input` rows in `claude agents`.
- **Cross-session messaging** carries coordinator → dispatcher notices. `settings.json` sets
  `crossSessionInbound: accept` so those messages are delivered rather than held; a message from another
  session is never treated as your approval for anything.
- **Keep agent teams off** (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` unset). With teams enabled, named
  subagents become teammates, which cannot run background subagents and would make coordinators block.
- The Linear MCP tool names in the skills are the `linear@claude-plugins-official` ones
  (`mcp__plugin_linear_linear__*`). With a differently named Linear server, adjust the
  `allowed-tools` lists.
