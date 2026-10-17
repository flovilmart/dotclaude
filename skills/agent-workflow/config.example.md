# Agent Workflow — Local Config

Copy this file to `~/.claude/skills/agent-workflow/config.local.md` (gitignored) or run
`/agent-workflow start` and answer the onboarding questions. Every key is read by the
`linear-poll`, `ticket-workflow` and `agent-workflow` skills; scripts receive values as arguments.

## Linear
- team_key: DEMO
- team_id: 00000000-0000-0000-0000-000000000000      # from list_teams; cached so polls skip the lookup
- todo_state: Todo                                   # state name whose issues get picked up
- in_progress_state: In Progress                     # set on claim
- review_state: In Review                            # set when the stack is ready
- done_state: Done                                   # set on a sub-issue when its PR merges, on the ticket when all are merged
- stalled_label: agent-stalled                       # added after max_redispatch automatic restarts of a dead coordinator
- needs_spec_label: needs-spec                       # added while waiting for clarifications
- needs_plan_label: needs-plan-approval              # added while the slice plan waits for your approval
# Only issues assigned to the connected Linear user are ever polled (never the whole team).
- create_subissues: true                             # one Linear sub-issue per slice, each with its own PR; priority is picked up from Linear

## Repos
Map issues to a checkout. First matching row wins; `default` is required.
Match on Linear `project:<name>`, `label:<name>`, or `default`.

| match                  | repo              |
|------------------------|-------------------|
| project: Demo App      | ~/src/flovilmart/demo-app |
| label: infra           | ~/src/flovilmart/infra    |
| default                | ~/src/flovilmart/dotclaude |

## Coordinators
- permission_mode: auto          # auto | acceptEdits | default — mode of each background coordinator session
- model: sonnet                  # coordinator model: it routes and judges results while workers do the deep work; empty = your default model
- fast_model: sonnet             # workers' mechanical stages (verify, smoke, formatter fixes); judgement stages inherit your default model
- max_parallel: 3                # never run more coordinators than this at once
- max_redispatch: 3              # automatic restarts of a coordinator that died mid-ticket before the ticket is labelled stalled
- dispatcher_name: dispatcher    # name of the main session (start it with `claude --name dispatcher`, or /rename)

## Poll
- poll_cron: "*/15 8-19 * * 1-5"  # when the poll runs (local time): every 15 min, 8:00-19:59, Mon-Fri. Each tick re-sends the dispatcher's context, so keep it sparse
- pre_spec_next_cycle: false     # also run the spec gate (questions only, no worktree) on my Todo issues in the NEXT cycle

## Human gates
Two people see every change: you validate the feature and review it for mistakes, then a coworker approves the PR.
- plan_approval: human           # human (you approve the slice plan before any code) | auto (implementation starts after the design challenge)
- reviewers:                     # coworker GitHub logins requested once you validate, when CODEOWNERS names nobody; e.g. alice, bob
# You validate a PR by marking it Ready for review (GitHub does not let you approve your own PR; the agent opens PRs as you).

## Pull requests
- auto_merge: true               # enable GitHub auto-merge once the coworker approved and CI is green; merges only when branch protection (required human reviews) is satisfied
- max_slice_lines: 800           # changed lines per slice (excluding tests and generated code) above which the subtask stops and asks to split
- merge_method: squash           # squash | merge | rebase, unless the repo's AGENTS.md says otherwise
- smoke_test: auto               # auto (slices the planner marks smoke-worthy) | always | never
- verify_scope: affected         # affected (packages changed since the base; CI runs the full suite on the PR) | full
- max_fix_rounds: 3              # fix rounds per gate (review, verify, security, smoke) inside the subtask workflow before a human is asked
- security_review: auto          # auto (slices the planner flags: deps, auth, inputs, secrets, user data, infra) | always | never

## Conventions (defaults the coordinator uses when a repo's AGENTS.md is silent)
- stack_tool: auto               # auto (gh stack if installed) | gh-stack | manual
- slice_branch_pattern: {linear_branch}-s{n}-{slug}
- comment_marker: "🤖 agent-workflow"   # prefix of every Linear comment the workflow writes
