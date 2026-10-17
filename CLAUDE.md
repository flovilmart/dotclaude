# Claude Code Configuration

## Who I Am
Head of Engineering at **tato**. Primary work is a large TypeScript monorepo with many subprojects.

---

## Shell & Terminal

| Tool         | Value                              |
|--------------|------------------------------------|
| Shell        | Nushell (`nu`) — **always use nu syntax** for any command the user will run in their shell; never suggest bash-only syntax |
| Terminal     | Ghostty                            |
| Prompt       | Starship                           |
| Multiplexer  | Tmux + tmuxinator                  |
| Editor       | Neovim (`nvim`)                    |
| Fuzzy finder | fzf                                |

---

## Primary Tech Stack

| Layer          | Tooling                                              |
|----------------|------------------------------------------------------|
| TypeScript/JS  | Node.js via **Volta**, package manager: **pnpm**     |
| Python         | **Poetry** + **uv**; static analysis via Pyright LSP |
| Go             | Homebrew-installed                                   |
| Ruby           | **rbenv**-managed                                    |
| Rust           | Cargo via Homebrew                                   |
| Java           | Amazon Corretto, multiple JDK versions via JAVA_HOME |

---

## Git Preferences

- Pull strategy: **rebase** with autosquash
- Editor: `nvim`
- PRs via **GitHub CLI** (`gh pr create`)
- Push to current branch by default
- Use `~./` paths, not absolute `/Users/...` paths in any suggestions

---

## MCP Integrations

| Integration       | Purpose               | Key Operations                                      |
|-------------------|-----------------------|-----------------------------------------------------|
| **Linear**        | Issue tracking        | list_teams, list_issues, save_issue, list_cycles    |
| **Notion**        | Knowledge base        | notion-search, notion-fetch, notion-create-pages    |
| **TypeScript LSP**| Code intelligence     | —                                                   |
| **Pyright LSP**   | Python type checking  | —                                                   |

---

## Infrastructure & Cloud

- **Kubernetes** — kubectl with custom nu shell aliases (`k`, `kgp`, `klogs`)
- **Docker** — via Rancher Desktop
- **Terraform** — version-managed with tfenv
- **Azure CLI** + **AWS** — both configured

---

## Notifications

- `~/.claude/hooks/notify.sh` fires on Claude stop/input-required events
- macOS `terminal-notifier` with tmux pane + git branch context
- Different sounds for completion vs. input needed

---

## Workflow Notes

- Secrets managed via **1Password CLI** (`op`)
- `oxfmt` used for code formatting
- tmux sessions managed with tmuxinator
- fzf used for interactive file/history selection

---

## Agent Workflow (Linear → worktree → stacked PRs)

Autonomous ticket pipeline for Linear issues **assigned to me** (never the whole team); full description in `~/.claude/docs/agent-workflow.md`.

```nu
claude --name dispatcher          # main session; stays free, only dispatches
/agent-workflow start             # onboarding on first run, then starts the watcher (tmux window aw-watcher) and follows its events
/agent-workflow status | stop | dispatch <id> | clarify <id> | report
claude agents                     # one coordinator session per ticket, in its own <repo>-wt<N> worktree
claude attach ENG-123             # talk to a coordinator; ← to detach
```

- Coordinators (`agents/ticket-coordinator.md`) run `/ticket-workflow`: background subagents for the human-facing steps (`repo-scout`, `spec-challenger`), and the saved workflows `workflows/plan.js` and `workflows/subtask.js` for the deterministic ones (`slice-planner` ⇄ `design-challenger`; `implementer` ⇄ `code-challenger` → `verifier` → `security-reviewer` + `smoke-tester`).
- Specs are written into the Linear task (`## Spec`); clarification questions are Linear comments prefixed `🤖 agent-workflow`.
- Every worker gets a brief (task, goal, guardrails, done-when) and refuses to work without one.
- Slices become Linear sub-issues, each with its own PR, picked up by priority; dependent ones are stacked via `gh stack` (`skills/stack-pr`); feature flags per the repo's `AGENTS.md`.
- Human gates: I approve the slice plan (`plan_approval`), I validate each draft PR (validation packet from `skills/ticket-workflow/pr-body.md`) by marking it ready, then a coworker is requested and approves. Agents never mark ready or approve.
- Gates before a draft reaches me: `verifier` (incl. slice size), `security-reviewer`, `smoke-tester`; every commit code-reviewed. The poll relays PR events (CI, reviews, validation, merges); auto-merge only after the coworker's approval via branch protection; sub-issues go to Done on merge.
- `workflows/test/` tests the saved workflows offline (`node --test`), run by `selftest.nu`.
- CI (`.github/workflows/ci.yml`): `selftest.nu` on Ubuntu with the oldest supported nushell (`MIN_NU`, 0.111.0) and the latest, and on macOS (BSD `nc`, Keychain). Nushell comes from the release tarball with a pinned SHA-256; bump the matrix and `MIN_NU` together. In Actions, `run-tests.nu` and `selftest.nu` annotate each failure at its line and write results tables to the job summary (`nu/gha.nu`).
- Poll: `skills/linear-poll/scripts/watch.nu` polls Linear (GraphQL; OAuth with PKCE via `linear-auth.nu login`, or an API key via `op read` of `linear_api_key_ref`) and GitHub every minute in working hours, dispatches itself, and writes a line to `events.log` only when the dispatcher is needed; `follow.nu` delivers those under Monitor; rules in `rules.nu`, tested by `selftest.nu`.
- Cost: dispatcher is a dedicated session (each watcher event re-sends its context); coordinator and mechanical stages on `sonnet`; verification scoped to affected packages; fixes carry blocking findings only; security/smoke only on slices the planner flags; repo profiles cached per repo (`profile-key.nu`).
- Hooks log every subagent run to `~/.claude/agent-workflow/log.jsonl`; `/agent-workflow report` summarises it; `nu ~/.claude/skills/agent-workflow/scripts/tui.nu` is a live terminal dashboard over it. `selftest.nu` tests the scripts offline.
- Config: `skills/agent-workflow/config.local.md` (gitignored; template `config.example.md`).
- Shared nushell modules live in `nu/` (e.g. `nu/oauth.nu`: OAuth 2.1 with PKCE, loopback callback via `nc`, refresh rotation, Keychain storage; reusable for any provider). Nushell tests use the standard library's markers (`use std/testing *`: `@test`, `@ignore`, `@before-each`, `@before-all`, `@after-each`, `@after-all`) in `**/tests/*.nu`; test names are plain words. `nu ~/.claude/nu/run-tests.nu` runs them (std/testing ships the markers, not a runner).
