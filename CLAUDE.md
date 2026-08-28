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

## Allowed Bash Commands

These are pre-approved in `~/.claude/settings.json`:

```
ls, wc, node, nu, pnpm, npx oxfmt, gh pr create, grep, uv,
git add, git commit, git push, python3 -c
```

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
