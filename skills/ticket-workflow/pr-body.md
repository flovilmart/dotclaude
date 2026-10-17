# PR body template

The coordinator fills this from the subtask workflow's READY result, the slice and the spec.
It has two parts:

- **Owner block**, between the `agent-workflow:owner` markers: what the owner needs to validate the
  feature and catch mistakes. Present while the PR is a draft.
- **Reviewer part**, below it: what a coworker with no context needs to approve the code.

When the owner marks the PR ready (= validated), the coordinator folds the owner block into a
collapsed `<details>` with a one-line verdict, keeping any boxes the owner ticked. It does not
delete the block.

If the repo has a PR template, keep its headings and put these sections inside them: owner block
first, the reviewer sections under the template's summary or description heading.

Rules for filling it:

- Every claim links to evidence: `path:line` for tests, artifact paths or response excerpts for smoke.
- An empty section says `none`. Never drop a section: an empty "Check first" tells the owner something.
- **Check first** comes from `uncertain` plus `deviations`, highest risk first. Don't soften them.
- **Open findings** come from `carried`. Findings already fixed in a review round are not listed.
- Keep the reviewer part under ~25 lines. The diff is the detail.

---

```markdown
<!-- agent-workflow:owner -->
## 🔎 Validate — @<owner>
Draft until you validate. **Mark "Ready for review" when you're satisfied**: that's your sign-off, and
it requests <coworker(s)>. Leave review comments for anything to change; each one gets a fix and a reply.

**Try it**: in your checkout `gh pr checkout <n>`, then `<run command from repo profile>`;
flag `<flag>` is off by default (turn on: `<how, from repo profile>`).
Or ask the coordinator: `/agent-workflow try <ticket> s<n>` (it runs the app in its worktree when idle).

### Acceptance criteria
| ok | criterion | proven by test | smoke: flag off → on |
|----|-----------|----------------|----------------------|
| [ ] | <criterion> | `<path:line>` or **none** | <off> → <on> · <evidence> |

### Check first: where the agent was least sure
- `<path:line>`: <decision or assumption, and why it was made>

### Deviations from the plan
- <deviation> | none

### Open findings (not blocking)
- SHOULD `<location>`: <issue>
- NIT `<location>`: <issue>
<!-- /agent-workflow:owner -->

## Summary
**Why**: <spec goal in one line>. [<ticket>](<linear url>) · slice <n>/<total> · <standalone | stacked on #<n>>
**What**:
- <2-4 bullets of behaviour, not file lists>

**Start reading at** `<entry file>` (`<function or component>`), then `<next file>`.
**Review focus**: <the one or two places where judgement was needed or the risk is highest>

**Verified**: format · lint · types · tests ✓ (`<commands>`) · security <PASS | disabled> · smoke <PASS | SKIPPED: reason> · <changedLines> lines changed excluding tests
**Rollout**: <flag `<name>` default off; enabled in slice <m> | no flag: additive and backward compatible>
**Revert**: <revert this PR alone | note on ordering with other slices>
```

After validation, the owner block becomes:

```markdown
<details><summary>✅ Validated by @<owner> on <date>: <k>/<n> criteria checked</summary>

<!-- agent-workflow:owner -->
...the original block, ticked boxes kept...
<!-- /agent-workflow:owner -->
</details>
```
