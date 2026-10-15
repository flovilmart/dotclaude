# Agent workflow: Linear → worktree → stacked PRs

A Linear ticket in the current cycle's **Todo** column becomes, without anyone typing, a dedicated
coordinator session in its own git worktree, a spec gate that asks you only the questions that
matter, a plan of small reversible slices challenged before code exists, XP-style implementation with
an adversarial reviewer and a verifier per slice, and a stack of pull requests on GitHub. Your main
session only dispatches and relays, so it stays free.

```
 you ──▶ main session ("dispatcher")              one process, always free
            │  /loop 10m /linear-poll             cron fires between your turns
            │
            ├─▶ claude --bg --name ENG-123 --agent ticket-coordinator   (worktree monorepo-wt2)
            │        │ /ticket-workflow ENG-123 dispatcher
            │        ├─ repo-scout        → repo profile (commands, flags, conventions from AGENTS.md)
            │        ├─ spec-challenger   → READY | questions  ──▶ Linear comment + label + message to you
            │        ├─ slice-planner ⇄ design-challenger      → stack plan (Linear comment)
            │        └─ per slice: implementer ⇄ code-challenger → verifier → gh stack submit / pr ready
            │
            └─▶ claude --bg --name ENG-124 ...                           (worktree platform-wt1)
```

Each box under a coordinator is a background subagent. The coordinator's own turns are short:
dispatch, wait for the completion notification, decide, dispatch again. You can `claude attach ENG-123`
at any time and talk to it; it answers from its state file and resumes.

## Pieces

| Path | Role |
|------|------|
| `skills/agent-workflow/` | Control plane in the main session: `start`, `status`, `stop`, `dispatch <id>`, `clarify <id>`. Holds `config.example.md`; your copy is `config.local.md` (gitignored). |
| `skills/linear-poll/` | One poll tick (cheap). Scheduled by `/agent-workflow start` via a cron, or `/loop 10m /linear-poll`. |
| `skills/linear-poll/scripts/*.nu` | `ensure-worktree.nu` (sibling `<repo>-wt<N>` pool, same convention as `linear-ticket`), `dispatch.nu` (worktree + `claude --bg`), `sessions.nu` (wraps `claude agents --json --all`), `resume.nu` (wake a stopped coordinator). |
| `skills/ticket-workflow/` | The per-ticket pipeline the coordinator runs. |
| `skills/stack-pr/` | Stacked PR mechanics: GitHub native `gh stack` when installed, manual `gh pr create --base` otherwise. |
| `agents/ticket-coordinator.md` | Main agent of each coordinator session (`--agent ticket-coordinator`): orchestrates, never implements. |
| `agents/repo-scout.md` | Reads AGENTS.md / CLAUDE.md / manifests / CI → repo profile. |
| `agents/spec-challenger.md` | Definition of ready; drafts the `## Spec`; asks at most five questions with defaults. |
| `agents/slice-planner.md` | Ordered stack of small, independently revertable slices; tests first; flag strategy. |
| `agents/design-challenger.md` | Breaks the plan before code: reversibility, coupling, tests, flags, simpler design. |
| `agents/implementer.md` | One slice, red → green → refactor, tiny commits, repo checks before each commit. |
| `agents/code-challenger.md` | Adversarial diff review against spec and plan. |
| `agents/verifier.md` | Runs the repo's real quality gates and reports verbatim. |

All agents are generic. Repository specifics come from the repo's `AGENTS.md` (or `CLAUDE.md`,
`CONTRIBUTING.md`), which every agent reads first and which wins on conflict. Note that Claude Code
loads `AGENTS.md` automatically only when the repo has no `CLAUDE.md`; a `CLAUDE.md` containing
`@AGENTS.md` loads both.

## Setup

1. Start your main session with a stable name, from any directory:
   ```nu
   claude --name dispatcher
   ```
2. `/agent-workflow start`. First run asks a few questions (team, state names, which Todo issues to
   claim, repo paths, coordinator permission mode, poll interval) and writes
   `~/.claude/skills/agent-workflow/config.local.md`. It then creates the poll cron.
3. Optional but recommended: `gh extension install github/gh-stack` for native stacks.
4. First dispatch into a brand-new worktree directory may need the workspace trust dialog. The
   dispatcher then opens a tmux window with the coordinator running interactively; accept once, press
   `←` or `/background` to detach. Later dispatches to that worktree go straight to the background.

## Clarifications

When the spec-challenger finds the ticket under-specified, the coordinator posts a numbered list of
questions (each with why it matters and a proposed default) as a Linear comment, labels the issue
`needs-spec`, and messages the dispatcher. Answer either way:

- in Linear: reply in the thread or edit the issue. The next poll tick notices and wakes the coordinator.
- in the main session: just answer in prose, then `/agent-workflow clarify ENG-123` (or the dispatcher
  does it when it recognises the answer). It writes a `## Spec` section into the issue description,
  removes the label, and wakes the coordinator.

Either way the spec ends up **in the Linear task**, which is the only place the pipeline reads it from.
After three unanswered rounds the coordinator adopts the proposed defaults, records them as
assumptions in the spec, and continues.

## Day to day

```nu
claude agents                       # live view of every coordinator; Space to peek and reply
claude attach ENG-123               # take over a coordinator's terminal; ← to detach
claude logs ENG-123                 # recent output
/agent-workflow status              # in the dispatcher: coordinators, cron, tickets waiting on you
/agent-workflow dispatch ENG-130    # push one ticket through regardless of cycle or state
/agent-workflow stop                # remove the poll cron (coordinators keep running)
```

A coordinator that is idle and unattached for about an hour is stopped by the supervisor; its
conversation is kept, and the next poll tick (or `claude attach`) restarts it where it left off.

## Design choices and limits

- **State lives in Linear and git**, not in the dispatcher's memory. States (`Todo` → `In Progress` →
  `In Review`), the `needs-spec` label, comments prefixed with `🤖 agent-workflow`, and PR links are
  the record. A coordinator also keeps `~/.claude/agent-workflow/state/<ticket>.md` to survive
  compaction. Nothing else is persisted, so there is no ledger to corrupt.
- **The coordinator claims the issue, not the poller**, so a failed dispatch never leaves a ghost
  "In Progress" ticket.
- **Slices are sequential** inside a ticket because each one stacks on the previous. Parallelism comes
  from running several tickets at once (`max_parallel` in the config).
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
