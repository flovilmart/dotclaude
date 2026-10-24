# PR body and validation note

The coordinator fills both from the subtask workflow's READY result, the slice and the spec.

- **PR body**: for the coworker who reviews the code. Short.
- **Validation note**: for the owner only. A comment on the Linear **sub-issue**, never in the PR.

## PR body

Two or three sentences: what the change does, then its caveats (a flag, an ordering with other
slices, a known limit). Behaviour, not a file list. Then the ticket link.

Leave out: acceptance criteria, check-first items, deviations, findings, a reading guide, future
work, and what was verified (CI shows that).

If the repo has a PR template, put the sentences under its summary or description heading and
drop the other headings when the template allows it.

```markdown
<What the change does, in one or two sentences.> <Caveats: flag `<name>` off by default; stacked on #<n>; …>

[<ticket>](<linear url>) · slice <n>/<total>
```

## Validation note (Linear comment on the sub-issue)

Posted with `save_comment` on the sub-issue when the draft is opened, prefixed with the workflow
marker. After a fix round, post a new note listing only what changed.

- Every claim links to evidence: `path:line` for tests, artifact paths or response excerpts for smoke.
- An empty section says `none`. Never drop a section: an empty "Check first" tells the owner something.
- **Check first** comes from `uncertain` plus `deviations`, highest risk first. Don't soften them.
- **Open findings** come from `carried`. Findings already fixed in a review round are not listed.

```markdown
<marker> · <ticket> s<n> · ready to validate: <PR url>

Mark the PR "Ready for review" when you're satisfied: that's your sign-off, and it requests
<coworker(s)>. Leave review comments on the PR for anything to change.

**Try it**: `gh pr checkout <n>`, then `<run command from repo profile>`; flag `<flag>` is off by
default (turn on: `<how>`). Or `/agent-workflow try <ticket> s<n>`.

**Acceptance criteria**
- <criterion>: test `<path:line>` | **none** · smoke <off> → <on> · <evidence>

**Check first**
- `<path:line>`: <decision or assumption, and why it was made>

**Open findings (not blocking)**
- SHOULD `<location>`: <issue>
- NIT `<location>`: <issue>
```
