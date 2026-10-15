# Agent Workflow — Local Config

Copy this file to `~/.claude/skills/agent-workflow/config.local.md` (gitignored) or run
`/agent-workflow start` and answer the onboarding questions. Every key is read by the
`linear-poll`, `ticket-workflow` and `agent-workflow` skills; scripts receive values as arguments.

## Linear
- team_key: ENG
- team_id: 2eae57c8-857d-4322-8904-bc972ffe7c96      # from list_teams; cached so polls skip the lookup
- todo_state: Todo                                   # state name whose issues get picked up
- in_progress_state: In Progress                     # set on claim
- review_state: In Review                            # set when the stack is ready
- needs_spec_label: needs-spec                       # added while waiting for clarifications
- claim_filter: unassigned-or-me                     # all | unassigned-or-me | assignee:me | label:<name>
- assign_on_claim: true                              # assign the issue to me when claimed
- create_subissues: true                             # one Linear sub-issue per slice, each with its own PR; priority is picked up from Linear

## Repos
Map issues to a checkout. First matching row wins; `default` is required.
Match on Linear `project:<name>`, `label:<name>`, or `default`.

| match                  | repo              |
|------------------------|-------------------|
| project: Platform      | ~/src/tato/platform |
| label: infra           | ~/src/tato/infra  |
| default                | ~/src/tato/monorepo |

## Coordinators
- permission_mode: auto          # auto | acceptEdits | default — mode of each background coordinator session
- model:                         # empty = your default model; or an alias such as sonnet
- max_parallel: 3                # never run more coordinators than this at once
- dispatcher_name: dispatcher    # name of the main session (start it with `claude --name dispatcher`, or /rename)

## Poll
- interval: 10m                  # passed to the cron created by /agent-workflow start

## Conventions (defaults the coordinator uses when a repo's AGENTS.md is silent)
- stack_tool: auto               # auto (gh stack if installed) | gh-stack | manual
- slice_branch_pattern: {linear_branch}-s{n}-{slug}
- comment_marker: "🤖 agent-workflow"   # prefix of every Linear comment the workflow writes
