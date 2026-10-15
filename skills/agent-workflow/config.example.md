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
- model:                         # empty = your default model; or an alias such as sonnet
- max_parallel: 3                # never run more coordinators than this at once
- max_redispatch: 3              # automatic restarts of a coordinator that died mid-ticket before the ticket is labelled stalled
- dispatcher_name: dispatcher    # name of the main session (start it with `claude --name dispatcher`, or /rename)

## Poll
- interval: 10m                  # passed to the cron created by /agent-workflow start
- pre_spec_next_cycle: false     # also run the spec gate (questions only, no worktree) on my Todo issues in the NEXT cycle

## Pull requests
- auto_merge: true               # enable GitHub auto-merge on a PR once it is approved and green; merges only when branch protection (required human reviews) is satisfied
- merge_method: squash           # squash | merge | rebase, unless the repo's AGENTS.md says otherwise
- smoke_test: auto               # auto (slices the planner marks smoke-worthy) | always | never
- max_fix_rounds: 3              # fix rounds per gate (review, verify, security, smoke) inside the subtask workflow before a human is asked
- security_review: always        # always | never — gate before a PR leaves draft

## Conventions (defaults the coordinator uses when a repo's AGENTS.md is silent)
- stack_tool: auto               # auto (gh stack if installed) | gh-stack | manual
- slice_branch_pattern: {linear_branch}-s{n}-{slug}
- comment_marker: "🤖 agent-workflow"   # prefix of every Linear comment the workflow writes
