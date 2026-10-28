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
//   maxLines      changed lines (excluding tests and generated code) above which the slice must be split (default 800)
//   fastModel     model for mechanical stages: verify, smoke, formatter-only fixes (default 'sonnet');
//                 judgement stages (implement, review, review and check fixes, security) inherit the session model
//   verifyScope   'affected' (default: packages changed since base; CI runs the full suite on the PR) | 'full'
//
// Every commit that reaches READY has been through an approving code review:
// fixes made for the verifier or the gates are reviewed again at the end.
//
// Returns one structured result; the coordinator ships the PR, updates Linear
// and decides what to do with status != READY. Linear is never touched here.
// The READY result carries what the owner's validation note needs:
// coverage, smokeCriteria, uncertain, deviations, carried, changedLines.

export const meta = {
  name: 'subtask',
  description: 'Implement, review, verify and gate one subtask on its branch',
  whenToUse: 'From /ticket-workflow for each Linear sub-issue; not for direct use',
  phases: [
    { title: 'Implement', detail: 'implementer, test first' },
    { title: 'Review', detail: 'code-challenger with bounded fix rounds' },
    { title: 'Verify', detail: 'verifier with bounded fix rounds, slice size gate' },
    { title: 'Gates', detail: 'security-reviewer and smoke-tester in parallel' },
    { title: 'Final review', detail: 'code-challenger on fixes made after the first review' },
  ],
}

const a = args || {}
const maxRounds = a.maxRounds || 3
const maxLines = a.maxLines || 800
const FAST = { model: a.fastModel || 'sonnet', effort: 'low' }
const fullVerify = a.verifyScope === 'full'
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
    uncertain: { type: 'array', items: { type: 'string' }, description: 'decisions made without explicit guidance, assumptions, and code you are least sure about (path:line — why); the owner reviews these first' },
    question: { type: 'string' },
    findings: { type: 'array', items: { type: 'string' }, description: 'per review finding: "fixed | not fixed (why) | disagree (why): <finding>"' },
    report: { type: 'string' },
  },
  required: ['status', 'commits', 'uncertain', 'report'],
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
    coverage: {
      type: 'array',
      description: 'one row per acceptance criterion of the slice: the test that proves it, or "none"',
      items: { type: 'object', properties: { criterion: { type: 'string' }, test: { type: 'string' } }, required: ['criterion', 'test'] },
    },
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
    changedLines: { type: 'integer', description: 'added + removed lines in git diff --numstat <base>...HEAD, excluding tests, lockfiles and generated files' },
    report: { type: 'string' },
  },
  required: ['result', 'changedLines', 'report'],
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
    criteria: {
      type: 'array',
      description: 'one row per acceptance criterion exercised',
      items: {
        type: 'object',
        properties: { criterion: { type: 'string' }, how: { type: 'string' }, flagOff: { type: 'string' }, flagOn: { type: 'string' }, evidence: { type: 'string' } },
        required: ['criterion', 'how', 'evidence'],
      },
    },
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

// The verifier runs package suites, affected checks and the build; the implementer stays on focused checks.
const FOCUSED = 'the focused checks (test files by path, lint and format on changed files, one typecheck at the end; never a whole package suite, turbo run, the affected checks or a build)'

const implementBrief = () => `TASK: implement this slice on branch ${a.branch} using red → green → refactor, committing after each green state.
GOAL: ${a.slice && a.slice.goal ? a.slice.goal : 'the part of the spec this slice covers (see Slice and Spec in CONTEXT)'}
${guardrails()}
DONE WHEN: the slice's "done when" holds, ${FOCUSED} pass, the tree is clean, and you return the SLICE REPORT as structured output (status DONE | BLOCKED | PARTIAL), listing under "uncertain" every decision a human should double-check.
${context()}`

const fixBrief = (kind, items, extra) => `TASK: apply these ${kind} findings on branch ${a.branch}; for each one answer "fixed | not fixed (why) | disagree (why)" in the findings field. Commit per repo convention.
GOAL: same slice goal; the findings exist to make the slice correct, not to widen it.
${guardrails('Do not re-litigate approved design; a disagreement is reported, not silently skipped.')}
DONE WHEN: every finding has an answer, ${FOCUSED} pass, tree clean; return the SLICE REPORT as structured output.
FINDINGS:
${asText(items)}
${extra ? '\nADDITIONAL:\n' + extra : ''}
${context()}`

// fixes: commits added after the last approving review, or null for the whole slice
const reviewBrief = (fixes) => `TASK: adversarially review ${fixes
  ? `only the commits added to ${a.branch} after the last approved review: ${fixes.join('; ')} (git show each one; read git diff ${a.base}...HEAD for context only)`
  : `the diff of ${a.branch} against ${a.base} (git diff ${a.base}...HEAD) for exactly this slice`}.
GOAL: only correct, tested, in-scope, reversible code reaches the PR.
GUARDRAILS: read-only (you may run scoped tests); judge against the spec, the slice and the repo's AGENTS.md, not personal taste; a finding needs evidence (path:line or a scenario).
DONE WHEN: you return the CODE REVIEW as structured output (verdict APPROVE | REQUEST_CHANGES with blocking / should / nits, and coverage: for each acceptance criterion of the slice, the test that proves it as path:line, or "none").
${context()}`

const verifyBrief = () => `TASK: run the repository's quality gates on branch ${a.branch} as the repo profile and CI define them, ${fullVerify
  ? 'the full suite'
  : `scoped to the packages affected since ${a.base} (the profile's "Affected checks"; CI runs the full suite on the PR)`}, and measure the slice size.
GOAL: the PR is green on CI the first time, and small enough for a human to review.
GUARDRAILS: never edit source; you may run the formatter in write mode and report changed files; re-run a failing test once to detect flakiness; leave the tree as you found it apart from formatter output.
DONE WHEN: you return the VERIFICATION as structured output (PASS | FAIL with verbatim failures, and changedLines from git diff --numstat ${a.base}...HEAD excluding tests, lockfiles and generated files).
${context()}`

const securityBrief = () => `TASK: security review of ${a.branch} against ${a.base}: dependency audit, secret scan, and a diff review for authz, injection, data exposure and unsafe defaults.
GOAL: nothing exploitable or data-exposing leaves draft.
GUARDRAILS: read-only; run the repo's own tools where present; report, do not fix; a finding needs an attack path.
DONE WHEN: you return the SECURITY REVIEW as structured output (PASS | BLOCK).
${context()}`

const smokeBrief = () => `TASK: start the app or service the way the repo documents and exercise this slice's acceptance criteria end to end, with ${a.flag ? `flag ${a.flag} off and on` : 'the new behaviour'}.
GOAL: the slice works outside the unit tests, with evidence the owner can check without re-running it.
GUARDRAILS: never edit code or flip the flag by editing source; stop everything you start; if you cannot run at all, return SKIPPED with the exact reason and command.
DONE WHEN: you return the SMOKE TEST as structured output (PASS | FAIL | SKIPPED) with one criteria row per acceptance criterion (how exercised, flag off, flag on, evidence path or response excerpt).
${context()}`

// ---------- state and helpers ----------
const commits = []
const reports = {}
const uncertain = []
const deviations = []
const carried = { should: [], nits: [] }
const rounds = { review: 0, verify: 0, security: 0, smoke: 0 }
let reviewed = 0 // commits[0, reviewed) have been through an approving code review

const note = (key, report) => {
  let n = 1
  while (reports[`${key}${n}`] !== undefined) n++
  reports[`${key}${n}`] = report
}
const uniq = (findings) => [...new Map(findings.map((f) => [`${f.location}|${f.issue}`, f])).values()]
const result = (status, extra) => ({
  status, // READY | BLOCKED | NEEDS_HUMAN | FAILED
  ticket: a.ticket, branch: a.branch, base: a.base,
  commits, rounds, reports, uncertain, deviations,
  carried: { should: uniq(carried.should), nits: uniq(carried.nits) },
  ...extra,
})

// halt() ends the workflow from any depth with a non-READY result
class Halt { constructor(res) { this.res = res } }
const halt = (status, extra) => { throw new Halt(result(status, extra)) }

const stops = ['BLOCKED', 'NEEDS_BRIEF', 'MISALIGNED']
const implement = async (brief, phase, label, key, opts = {}) => {
  const impl = await agent(brief, { agentType: 'implementer', schema: IMPL, phase, label, ...opts })
  if (!impl) halt('FAILED', { reason: 'implementer returned nothing', stage: label })
  commits.push(...(impl.commits || []))
  uncertain.push(...(impl.uncertain || []))
  deviations.push(...(impl.deviations || []))
  note(key, impl.report)
  if (stops.includes(impl.status)) halt('BLOCKED', { question: impl.question || impl.report, stage: label, implStatus: impl.status })
  return impl
}

// Review until code-challenger approves; fix rounds are reviewed by the next round.
// The fixer gets blocking findings only. SHOULD / NIT go to the owner's packet:
// the approving round re-reviews the whole scope, so its lists are the current ones.
const reviewLoop = async (fixes, label) => {
  for (let round = 0; ; round++) {
    const review = await agent(reviewBrief(fixes), { agentType: 'code-challenger', schema: REVIEW, phase: fixes ? 'Final review' : 'Review', label: `${label} r${round + 1}` })
    if (!review) halt('FAILED', { reason: 'code-challenger returned nothing', stage: label })
    note('review', review.report)
    if (review.verdict === 'NEEDS_BRIEF' || review.verdict === 'MISALIGNED') halt('NEEDS_HUMAN', { reason: review.report, stage: label })
    if (review.verdict === 'APPROVE' || (review.blocking || []).length === 0) {
      reviewed = commits.length
      carried.should.push(...(review.should || []))
      carried.nits.push(...(review.nits || []))
      return review
    }
    if (round >= maxRounds) halt('NEEDS_HUMAN', { reason: `review still blocking after ${maxRounds} fix rounds`, stage: label, open: review.blocking })
    rounds.review++
    log(`${label} round ${round + 1}: ${review.blocking.length} blocking finding(s)`)
    await implement(fixBrief('review', { blocking: review.blocking }), fixes ? 'Final review' : 'Review', `fix ${label} r${round + 1}`, 'fixReview')
  }
}

// Verify until green with no formatter changes; failures go back to the implementer.
const verifyLoop = async (label, phase) => {
  for (let round = 0; ; round++) {
    const verify = await agent(verifyBrief(), { agentType: 'verifier', schema: VERIFY, phase, label: `${label} r${round + 1}`, ...FAST })
    if (!verify) halt('FAILED', { reason: 'verifier returned nothing', stage: label })
    note('verify', verify.report)
    if (verify.result === 'NEEDS_BRIEF') halt('NEEDS_HUMAN', { reason: verify.report, stage: label })
    const formatter = verify.formatterChanged || []
    if (verify.result === 'PASS' && formatter.length === 0) return verify
    if (round >= maxRounds) halt('NEEDS_HUMAN', { reason: `checks still failing after ${maxRounds} fix rounds`, stage: label, failures: verify.failures })
    rounds.verify++
    // formatter-only fixes are mechanical; failing checks need the judgement model
    const formatOnly = verify.result === 'PASS'
    const ask = formatOnly
      ? `commit the formatter changes to: ${formatter.join(', ')}`
      : `make the checks pass without weakening them. Verbatim failure:\n${verify.failures || verify.report}`
    log(`${label} round ${round + 1}: ${verify.result}`)
    await implement(fixBrief('verification', [ask]), phase, `fix ${label} r${round + 1}`, 'fixVerify', formatOnly ? FAST : {})
  }
}

const SECURITY_OFF = { verdict: 'PASS', blocking: [], should: [], report: 'security review disabled by config' }
const SMOKE_OFF = { result: 'SKIPPED', reason: 'smoke test not requested for this slice', report: 'smoke test skipped by config' }

try {
  // ---------- Implement ----------
  phase('Implement')
  const impl = await implement(implementBrief(), 'Implement', `implement ${a.branch}`, 'implement')
  if (impl.status === 'PARTIAL') {
    log(`implementer reported PARTIAL, asking it to finish: ${impl.report.slice(0, 200)}`)
    const done = await implement(fixBrief('completion', [`the slice's "done when" does not hold yet; finish it. Your previous report: ${impl.report}`]), 'Implement', 'complete partial', 'implement')
    if (done.status === 'PARTIAL') halt('NEEDS_HUMAN', { reason: `implementer could not finish the slice: ${done.report}`, stage: 'implement' })
  }

  // ---------- Review ----------
  phase('Review')
  const review = await reviewLoop(null, 'review')

  // ---------- Verify, then the size gate ----------
  phase('Verify')
  const verified = await verifyLoop('verify', 'Verify')
  if (verified.changedLines > maxLines) {
    halt('NEEDS_HUMAN', { reason: `slice changes ${verified.changedLines} lines excluding tests and generated code (limit ${maxLines}): split it so a human can review it`, stage: 'size' })
  }

  // ---------- Gates: security + smoke in parallel, each with bounded fix rounds ----------
  // Both gates re-run after any gate fix: a fix for one can break the other.
  phase('Gates')
  let security = SECURITY_OFF
  let smoke = SMOKE_OFF
  for (let round = 0; ; round++) {
    const [sec, smk] = await parallel([
      () => (a.security === false ? Promise.resolve(SECURITY_OFF)
        : agent(securityBrief(), { agentType: 'security-reviewer', schema: SECURITY, phase: 'Gates', label: `security r${round + 1}` })),
      () => (a.smoke === false ? Promise.resolve(SMOKE_OFF)
        : agent(smokeBrief(), { agentType: 'smoke-tester', schema: SMOKE, phase: 'Gates', label: `smoke r${round + 1}`, model: FAST.model })),
    ])
    security = sec || { verdict: 'BLOCK', blocking: [], should: [], report: 'security-reviewer returned nothing' }
    smoke = smk || { result: 'FAIL', report: 'smoke-tester returned nothing' }
    note('security', security.report)
    note('smoke', smoke.report)
    if (security.verdict === 'NEEDS_BRIEF' || smoke.result === 'NEEDS_BRIEF') halt('NEEDS_HUMAN', { reason: 'a gate asked for a better brief', stage: 'gates' })
    const secBlock = security.verdict === 'BLOCK'
    const smokeFail = smoke.result === 'FAIL'
    if (!secBlock && !smokeFail) break
    if (secBlock) rounds.security++
    if (smokeFail) rounds.smoke++
    if (round >= maxRounds) {
      halt('NEEDS_HUMAN', { reason: `gates still failing after ${maxRounds} fix rounds`, stage: 'gates', open: { security: security.blocking, smoke: smoke.report } })
    }
    const items = []
    if (secBlock) items.push({ security: security.blocking })
    if (smokeFail) items.push({ smoke: smoke.report, evidence: smoke.evidence || [] })
    log(`gates: ${secBlock ? 'security BLOCK ' : ''}${smokeFail ? 'smoke FAIL' : ''}`)
    await implement(fixBrief('gate', items, 'Security findings take the safer fix.'), 'Gates', `fix gates r${round + 1}`, 'fixGates')
    await verifyLoop('verify after gate fix', 'Gates')
  }
  carried.should.push(...(security.should || []))

  // ---------- Final review: no unreviewed commit reaches the PR ----------
  // Security and smoke are not re-run for fixes made here; those fixes are reviewed and verified.
  phase('Final review')
  for (let pass = 0; commits.length > reviewed; pass++) {
    if (pass >= maxRounds) halt('NEEDS_HUMAN', { reason: `fixes kept arriving after ${maxRounds} final review passes`, stage: 'final-review' })
    const before = commits.length
    await reviewLoop(commits.slice(reviewed), 'review fixes')
    if (commits.length > before) await verifyLoop('verify after review fixes', 'Final review')
  }

  return result('READY', {
    verification: 'PASS',
    changedLines: verified.changedLines,
    coverage: review.coverage || [],
    security: security.verdict,
    smoke: smoke.result,
    smokeReason: smoke.reason || '',
    smokeCriteria: smoke.criteria || [],
    smokeEvidence: smoke.evidence || [],
  })
} catch (e) {
  if (e instanceof Halt) return e.res
  throw e
}
