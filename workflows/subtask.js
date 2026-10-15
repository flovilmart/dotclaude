// subtask.js — deterministic inner loop for ONE subtask (slice) of a ticket.
//
// Called by the ticket-coordinator (skills/ticket-workflow) with:
//   Workflow({ scriptPath: "~/.claude/workflows/subtask.js", args: {...} })
//
// args:
//   ticket        "ENG-123"
//   branch        branch checked out in the worktree for this subtask
//   base          branch the diff is reviewed against (previous subtask or default branch)
//   worktree      absolute path of the worktree (agents already run there)
//   slice         the slice definition (markdown or object): goal, done when, guardrails, tests first, flag impact, steps
//   spec          the ticket's ## Spec section (goal, acceptance criteria, guardrails)
//   profile       the repo profile from repo-scout
//   flag          feature flag name or null
//   security      boolean: run the security gate (config security_review)
//   smoke         boolean: run the smoke test (coordinator resolves config smoke_test auto/always/never)
//   maxRounds     fix rounds per gate before giving up (default 3)
//
// Returns one structured result; the coordinator ships the PR, updates Linear
// and decides what to do with status != READY. Linear is never touched here.

export const meta = {
  name: 'subtask',
  description: 'Implement, review, verify and gate one subtask on its branch',
  whenToUse: 'From /ticket-workflow for each Linear sub-issue; not for direct use',
  phases: [
    { title: 'Implement', detail: 'implementer, test first' },
    { title: 'Review', detail: 'code-challenger with bounded fix rounds' },
    { title: 'Verify', detail: 'verifier with bounded fix rounds' },
    { title: 'Gates', detail: 'security-reviewer and smoke-tester in parallel' },
  ],
}

const a = args || {}
const maxRounds = a.maxRounds || 3
const asText = (v) => (typeof v === 'string' ? v : JSON.stringify(v, null, 2))

// ---------- schemas (StructuredOutput) ----------
const IMPL = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['DONE', 'BLOCKED', 'PARTIAL', 'NEEDS_BRIEF', 'MISALIGNED'] },
    commits: { type: 'array', items: { type: 'string' } },
    tests: { type: 'array', items: { type: 'string' } },
    checks: { type: 'array', items: { type: 'string' } },
    deviations: { type: 'array', items: { type: 'string' } },
    question: { type: 'string' },
    findings: { type: 'array', items: { type: 'string' }, description: 'per review finding: "fixed | not fixed (why) | disagree (why): <finding>"' },
    report: { type: 'string' },
  },
  required: ['status', 'commits', 'report'],
}
const FINDING = {
  type: 'object',
  properties: { location: { type: 'string' }, issue: { type: 'string' }, fix: { type: 'string' } },
  required: ['location', 'issue'],
}
const REVIEW = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['APPROVE', 'REQUEST_CHANGES', 'NEEDS_BRIEF', 'MISALIGNED'] },
    blocking: { type: 'array', items: FINDING },
    should: { type: 'array', items: FINDING },
    nits: { type: 'array', items: FINDING },
    report: { type: 'string' },
  },
  required: ['verdict', 'blocking', 'should', 'nits', 'report'],
}
const VERIFY = {
  type: 'object',
  properties: {
    result: { type: 'string', enum: ['PASS', 'FAIL', 'NEEDS_BRIEF'] },
    failures: { type: 'string', description: 'verbatim, trimmed failing output' },
    formatterChanged: { type: 'array', items: { type: 'string' } },
    flaky: { type: 'array', items: { type: 'string' } },
    report: { type: 'string' },
  },
  required: ['result', 'report'],
}
const SECURITY = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['PASS', 'BLOCK', 'NEEDS_BRIEF'] },
    blocking: { type: 'array', items: FINDING },
    should: { type: 'array', items: FINDING },
    toolsRun: { type: 'array', items: { type: 'string' } },
    report: { type: 'string' },
  },
  required: ['verdict', 'blocking', 'should', 'report'],
}
const SMOKE = {
  type: 'object',
  properties: {
    result: { type: 'string', enum: ['PASS', 'FAIL', 'SKIPPED', 'NEEDS_BRIEF'] },
    reason: { type: 'string' },
    evidence: { type: 'array', items: { type: 'string' } },
    report: { type: 'string' },
  },
  required: ['result', 'report'],
}

// ---------- briefs (the four-part contract every worker expects) ----------
const context = () => `
CONTEXT
- Ticket: ${a.ticket}
- Worktree: ${a.worktree}   Branch: ${a.branch}   Base: ${a.base}   Flag: ${a.flag || 'none'}
- Spec:
${asText(a.spec)}
- Repo profile:
${asText(a.profile)}
- Slice:
${asText(a.slice)}`

const guardrails = (extra) => `
GUARDRAILS: the Guardrails of the spec and of the slice; the repository's AGENTS.md / CLAUDE.md; stay on branch ${a.branch}; touch only this slice's area; ${a.flag ? `new behaviour stays behind flag ${a.flag}, default off` : 'no flag: keep every change additive and backward compatible'}; never weaken or skip a check; stop and ask (status BLOCKED with a precise question) when a decision would change a public API, the data model or user-visible behaviour.${extra ? ' ' + extra : ''}`

const implementBrief = () => `TASK: implement this slice on branch ${a.branch} using red → green → refactor, committing after each green state.
GOAL: ${a.slice && a.slice.goal ? a.slice.goal : 'the part of the spec this slice covers (see Slice and Spec in CONTEXT)'}
${guardrails()}
DONE WHEN: the slice's "done when" holds, the scoped fast checks pass, the tree is clean, and you return the SLICE REPORT as structured output (status DONE | BLOCKED | PARTIAL).
${context()}`

const fixBrief = (kind, items, extra) => `TASK: apply these ${kind} findings on branch ${a.branch}; for each one answer "fixed | not fixed (why) | disagree (why)" in the findings field. Commit per repo convention.
GOAL: same slice goal; the findings exist to make the slice correct, not to widen it.
${guardrails('Do not re-litigate approved design; a disagreement is reported, not silently skipped.')}
DONE WHEN: every finding has an answer, scoped fast checks pass, tree clean; return the SLICE REPORT as structured output.
FINDINGS:
${asText(items)}
${extra ? '\nADDITIONAL:\n' + extra : ''}
${context()}`

const reviewBrief = () => `TASK: adversarially review the diff of ${a.branch} against ${a.base} (git diff ${a.base}...HEAD) for exactly this slice.
GOAL: only correct, tested, in-scope, reversible code reaches the PR.
GUARDRAILS: read-only (you may run scoped tests); judge against the spec, the slice and the repo's AGENTS.md, not personal taste; a finding needs evidence (path:line or a scenario).
DONE WHEN: you return the CODE REVIEW as structured output (verdict APPROVE | REQUEST_CHANGES with blocking / should / nits).
${context()}`

const verifyBrief = () => `TASK: run the repository's full quality gates on branch ${a.branch} exactly as the repo profile and CI define them.
GOAL: the PR is green on CI the first time.
GUARDRAILS: never edit source; you may run the formatter in write mode and report changed files; re-run a failing test once to detect flakiness; leave the tree as you found it apart from formatter output.
DONE WHEN: you return the VERIFICATION as structured output (PASS | FAIL with verbatim failures).
${context()}`

const securityBrief = () => `TASK: security review of ${a.branch} against ${a.base}: dependency audit, secret scan, and a diff review for authz, injection, data exposure and unsafe defaults.
GOAL: nothing exploitable or data-exposing leaves draft.
GUARDRAILS: read-only; run the repo's own tools where present; report, do not fix; a finding needs an attack path.
DONE WHEN: you return the SECURITY REVIEW as structured output (PASS | BLOCK).
${context()}`

const smokeBrief = () => `TASK: start the app or service the way the repo documents and exercise this slice's acceptance criteria end to end, with ${a.flag ? `flag ${a.flag} off and on` : 'the new behaviour'}.
GOAL: the slice works outside the unit tests.
GUARDRAILS: never edit code or flip the flag by editing source; stop everything you start; if you cannot run at all, return SKIPPED with the exact reason and command.
DONE WHEN: you return the SMOKE TEST as structured output (PASS | FAIL | SKIPPED) with evidence paths or response excerpts.
${context()}`

// ---------- helpers ----------
const carried = { should: [], nits: [] }
const result = (status, extra) => ({
  status, // READY | BLOCKED | NEEDS_HUMAN | FAILED
  ticket: a.ticket, branch: a.branch, base: a.base,
  commits: [], rounds: { review: 0, verify: 0, security: 0, smoke: 0 },
  carried, reports: {},
  ...extra,
})
const stop = (impl) => impl && (impl.status === 'BLOCKED' || impl.status === 'NEEDS_BRIEF' || impl.status === 'MISALIGNED')

// ---------- Implement ----------
phase('Implement')
let impl = await agent(implementBrief(), { agentType: 'implementer', schema: IMPL, phase: 'Implement', label: `implement ${a.branch}` })
if (!impl) return result('FAILED', { reason: 'implementer returned nothing' })
const commits = [...(impl.commits || [])]
const reports = { implement: impl.report }
if (stop(impl)) return result('BLOCKED', { commits, reports, question: impl.question || impl.report, stage: 'implement', implStatus: impl.status })
if (impl.status === 'PARTIAL') log(`implementer reported PARTIAL: ${impl.report.slice(0, 200)}`)

// ---------- Review ----------
phase('Review')
let review = null
let reviewRounds = 0
while (true) {
  review = await agent(reviewBrief(), { agentType: 'code-challenger', schema: REVIEW, phase: 'Review', label: `review r${reviewRounds + 1}` })
  if (!review) return result('FAILED', { commits, reports, reason: 'code-challenger returned nothing' })
  reports[`review${reviewRounds + 1}`] = review.report
  carried.should.push(...(review.should || []))
  carried.nits.push(...(review.nits || []))
  if (review.verdict === 'NEEDS_BRIEF' || review.verdict === 'MISALIGNED') return result('NEEDS_HUMAN', { commits, reports, reason: review.report, stage: 'review' })
  if (review.verdict === 'APPROVE' || (review.blocking || []).length === 0) break
  reviewRounds++
  if (reviewRounds > maxRounds) return result('NEEDS_HUMAN', { commits, reports, reason: `review still blocking after ${maxRounds} fix rounds`, stage: 'review', open: review.blocking })
  log(`review round ${reviewRounds}: ${review.blocking.length} blocking finding(s)`)
  impl = await agent(fixBrief('review', { blocking: review.blocking, should: review.should }), { agentType: 'implementer', schema: IMPL, phase: 'Review', label: `fix review r${reviewRounds}` })
  if (!impl) return result('FAILED', { commits, reports, reason: 'implementer returned nothing' })
  commits.push(...(impl.commits || []))
  reports[`fixReview${reviewRounds}`] = impl.report
  if (stop(impl)) return result('BLOCKED', { commits, reports, question: impl.question || impl.report, stage: 'review-fix' })
}

// ---------- Verify ----------
phase('Verify')
let verify = null
let verifyRounds = 0
while (true) {
  verify = await agent(verifyBrief(), { agentType: 'verifier', schema: VERIFY, phase: 'Verify', label: `verify r${verifyRounds + 1}` })
  if (!verify) return result('FAILED', { commits, reports, reason: 'verifier returned nothing' })
  reports[`verify${verifyRounds + 1}`] = verify.report
  if (verify.result === 'NEEDS_BRIEF') return result('NEEDS_HUMAN', { commits, reports, reason: verify.report, stage: 'verify' })
  const formatter = verify.formatterChanged || []
  if (verify.result === 'PASS' && formatter.length === 0) break
  verifyRounds++
  if (verifyRounds > maxRounds) return result('NEEDS_HUMAN', { commits, reports, reason: `checks still failing after ${maxRounds} fix rounds`, stage: 'verify', failures: verify.failures })
  const ask = verify.result === 'PASS'
    ? `commit the formatter changes to: ${formatter.join(', ')}`
    : `make the checks pass without weakening them. Verbatim failure:\n${verify.failures || verify.report}`
  log(`verify round ${verifyRounds}: ${verify.result}`)
  impl = await agent(fixBrief('verification', [ask]), { agentType: 'implementer', schema: IMPL, phase: 'Verify', label: `fix verify r${verifyRounds}` })
  if (!impl) return result('FAILED', { commits, reports, reason: 'implementer returned nothing' })
  commits.push(...(impl.commits || []))
  reports[`fixVerify${verifyRounds}`] = impl.report
  if (stop(impl)) return result('BLOCKED', { commits, reports, question: impl.question || impl.report, stage: 'verify-fix' })
}

// ---------- Gates: security + smoke in parallel, each with bounded fix rounds ----------
phase('Gates')
let security = null
let smoke = null
let securityRounds = 0
let smokeRounds = 0
const runGates = async () => parallel([
  () => (a.security === false ? Promise.resolve({ verdict: 'PASS', blocking: [], should: [], report: 'security review disabled by config' })
    : agent(securityBrief(), { agentType: 'security-reviewer', schema: SECURITY, phase: 'Gates', label: `security r${securityRounds + 1}` })),
  () => (a.smoke === false ? Promise.resolve({ result: 'SKIPPED', reason: 'smoke test not requested for this slice', report: 'smoke test skipped by config' })
    : agent(smokeBrief(), { agentType: 'smoke-tester', schema: SMOKE, phase: 'Gates', label: `smoke r${smokeRounds + 1}` })),
])
while (true) {
  const [sec, smk] = await runGates()
  security = sec || { verdict: 'BLOCK', blocking: [], should: [], report: 'security-reviewer returned nothing' }
  smoke = smk || { result: 'FAIL', report: 'smoke-tester returned nothing' }
  reports[`security${securityRounds + 1}`] = security.report
  reports[`smoke${smokeRounds + 1}`] = smoke.report
  carried.should.push(...(security.should || []))
  if (security.verdict === 'NEEDS_BRIEF' || smoke.result === 'NEEDS_BRIEF') return result('NEEDS_HUMAN', { commits, reports, reason: 'a gate asked for a better brief', stage: 'gates' })
  const secBlock = security.verdict === 'BLOCK'
  const smokeFail = smoke.result === 'FAIL'
  if (!secBlock && !smokeFail) break
  if (secBlock) securityRounds++
  if (smokeFail) smokeRounds++
  if (securityRounds > maxRounds || smokeRounds > maxRounds) {
    return result('NEEDS_HUMAN', { commits, reports, reason: `gates still failing after ${maxRounds} fix rounds`, stage: 'gates', open: { security: security.blocking, smoke: smoke.report } })
  }
  const items = []
  if (secBlock) items.push({ security: security.blocking })
  if (smokeFail) items.push({ smoke: smoke.report, evidence: smoke.evidence || [] })
  log(`gates: ${secBlock ? 'security BLOCK ' : ''}${smokeFail ? 'smoke FAIL' : ''}`)
  impl = await agent(fixBrief('gate', items, 'Security findings take the safer fix.'), { agentType: 'implementer', schema: IMPL, phase: 'Gates', label: 'fix gates' })
  if (!impl) return result('FAILED', { commits, reports, reason: 'implementer returned nothing' })
  commits.push(...(impl.commits || []))
  reports[`fixGates${securityRounds + smokeRounds}`] = impl.report
  if (stop(impl)) return result('BLOCKED', { commits, reports, question: impl.question || impl.report, stage: 'gates-fix' })
  // re-verify after a gate fix, once, before re-running the gates
  const reverify = await agent(verifyBrief(), { agentType: 'verifier', schema: VERIFY, phase: 'Gates', label: 'verify after gate fix' })
  if (!reverify || reverify.result !== 'PASS') return result('NEEDS_HUMAN', { commits, reports, reason: 'checks failed after a gate fix', stage: 'gates', failures: reverify ? reverify.failures : '' })
}

return result('READY', {
  commits,
  rounds: { review: reviewRounds, verify: verifyRounds, security: securityRounds, smoke: smokeRounds },
  verification: 'PASS',
  security: security.verdict,
  smoke: smoke.result,
  smokeReason: smoke.reason || '',
  reports,
})
