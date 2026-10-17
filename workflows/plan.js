// plan.js — plan a ticket as a stack of subtasks and challenge the plan.
//
// Called by the ticket-coordinator (skills/ticket-workflow) with:
//   Workflow({ scriptPath: "~/.claude/workflows/plan.js", args: {...} })
//
// args:
//   ticket, worktree, spec, profile, branchPattern ("{linear_branch}-s{n}-{slug}"),
//   baseBranch (Linear gitBranchName), maxRounds (default 2)
//
// Returns { status: APPROVED | NEEDS_HUMAN | FAILED, plan, review, rounds, reports }.
// APPROVED means the design-challenger approved; the coordinator then asks the
// owner to approve the plan (config plan_approval) before it creates the Linear
// sub-issues from `plan.slices`. Open questions from the planner stop the run
// before the challenge: there is no point challenging a plan built on a guess.

export const meta = {
  name: 'plan',
  description: 'Slice a ticket into reversible subtasks and challenge the design',
  whenToUse: 'From /ticket-workflow after the spec gate; not for direct use',
  phases: [
    { title: 'Plan', detail: 'slice-planner' },
    { title: 'Challenge', detail: 'design-challenger, bounded revision rounds' },
  ],
}

const a = args || {}
const maxRounds = a.maxRounds || 2
const asText = (v) => (typeof v === 'string' ? v : JSON.stringify(v, null, 2))
const questions = (p) => p.openQuestions || []

const SLICE = {
  type: 'object',
  properties: {
    n: { type: 'integer' },
    slug: { type: 'string' },
    goal: { type: 'string' },
    priority: { type: 'integer', description: '1 urgent .. 4 low' },
    dependsOn: { type: 'array', items: { type: 'integer' } },
    files: { type: 'array', items: { type: 'string' } },
    testsFirst: { type: 'array', items: { type: 'string' } },
    flagImpact: { type: 'string' },
    revertCost: { type: 'string' },
    doneWhen: { type: 'array', items: { type: 'string' } },
    guardrails: { type: 'array', items: { type: 'string' } },
    steps: { type: 'array', items: { type: 'string' } },
    risks: { type: 'array', items: { type: 'string' } },
    smoke: { type: 'boolean', description: 'true when the slice has user-visible, API, CLI or integration behaviour worth a smoke test' },
  },
  required: ['n', 'slug', 'goal', 'priority', 'dependsOn', 'doneWhen', 'guardrails', 'steps'],
}
const PLAN = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['OK', 'NEEDS_BRIEF', 'MISALIGNED'] },
    flag: { type: 'string', description: 'feature flag name or empty' },
    slices: { type: 'array', items: SLICE },
    risks: { type: 'array', items: { type: 'string' } },
    openQuestions: { type: 'array', items: { type: 'string' }, description: 'blocking questions for the human only' },
    notNow: { type: 'array', items: { type: 'string' } },
    report: { type: 'string', description: 'the STACK PLAN in markdown, ready to post' },
  },
  required: ['status', 'flag', 'slices', 'report'],
}
const FINDING = {
  type: 'object',
  properties: { slice: { type: 'integer' }, finding: { type: 'string' }, evidence: { type: 'string' }, fix: { type: 'string' } },
  required: ['finding'],
}
const DESIGN = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['APPROVE', 'REVISE', 'NEEDS_BRIEF', 'MISALIGNED'] },
    blocking: { type: 'array', items: FINDING },
    should: { type: 'array', items: FINDING },
    notes: { type: 'array', items: { type: 'string' } },
    simplerAlternative: { type: 'string' },
    report: { type: 'string' },
  },
  required: ['verdict', 'blocking', 'should', 'report'],
}

const context = () => `
CONTEXT
- Ticket: ${a.ticket}   Worktree: ${a.worktree}   Base branch: ${a.baseBranch}
- Branch pattern for slices: ${a.branchPattern}
- Spec:
${asText(a.spec)}
- Repo profile:
${asText(a.profile)}`

const planBrief = () => `TASK: design the stack of subtasks (slices) for ${a.ticket}.
GOAL: the spec's goal reached through small, independently reviewable and revertable slices, each shippable on its own.
GUARDRAILS: the spec's Guardrails and the repo's AGENTS.md; under ~400 changed lines per slice excluding tests and generated code (flag above ~800); at most 5 slices, else propose splitting the ticket; one behaviour end to end per slice, never one slice per layer; walking skeleton first; feature flag per the repo's mechanism when behaviour is user-visible and spans slices or carries rollout risk; tests named before code; no speculative generality; honest dependencies; a priority per slice.
DONE WHEN: you return the STACK PLAN as structured output (slices with slug, goal, priority, dependsOn, doneWhen, guardrails, testsFirst, steps, smoke) plus the markdown report.
${context()}`

const reviseBrief = (plan, review) => `TASK: revise this plan to address the blocking findings; keep everything that was not challenged.
GOAL: same as before; the findings exist to make the plan safer and smaller, not bigger.
GUARDRAILS: same as the original brief; do not add scope to satisfy a finding when a cut would do.
DONE WHEN: you return the revised STACK PLAN as structured output.
CURRENT PLAN:
${asText(plan.report)}
BLOCKING FINDINGS:
${asText(review.blocking)}
SHOULD:
${asText(review.should)}
${context()}`

const challengeBrief = (plan) => `TASK: break this plan before any code exists: reversibility, slice size and independence, hidden coupling (grep the callers), tests that would really fail first, flag strategy, data compatibility, repo rules, a simpler alternative.
GOAL: no slice that cannot be merged and reverted alone, no acceptance criterion without a test, no plan that contradicts AGENTS.md.
GUARDRAILS: read-only; every blocking finding needs evidence from the code or the docs; APPROVE when nothing is blocking even if you have notes.
DONE WHEN: you return the DESIGN REVIEW as structured output (APPROVE | REVISE).
PLAN:
${asText(plan.report)}
${context()}`

phase('Plan')
let plan = await agent(planBrief(), { agentType: 'slice-planner', schema: PLAN, phase: 'Plan', label: 'plan' })
if (!plan) return { status: 'FAILED', reason: 'slice-planner returned nothing' }
const reports = { plan1: plan.report }
if (plan.status !== 'OK') return { status: 'NEEDS_HUMAN', reason: plan.report, stage: 'plan', plan }
if (questions(plan).length) return { status: 'NEEDS_HUMAN', reason: 'blocking questions for the human', stage: 'plan', openQuestions: questions(plan), plan, reports }

phase('Challenge')
let review = null
let rounds = 0
while (true) {
  review = await agent(challengeBrief(plan), { agentType: 'design-challenger', schema: DESIGN, phase: 'Challenge', label: `challenge r${rounds + 1}` })
  if (!review) return { status: 'FAILED', reason: 'design-challenger returned nothing', plan, reports }
  reports[`challenge${rounds + 1}`] = review.report
  if (review.verdict === 'NEEDS_BRIEF' || review.verdict === 'MISALIGNED') return { status: 'NEEDS_HUMAN', reason: review.report, stage: 'challenge', plan, review, reports }
  if (review.verdict === 'APPROVE' || (review.blocking || []).length === 0) break
  rounds++
  if (rounds > maxRounds) return { status: 'NEEDS_HUMAN', reason: `plan still has blocking findings after ${maxRounds} revision rounds`, stage: 'challenge', plan, review, reports, open: review.blocking }
  log(`revision round ${rounds}: ${review.blocking.length} blocking finding(s)`)
  plan = await agent(reviseBrief(plan, review), { agentType: 'slice-planner', schema: PLAN, phase: 'Challenge', label: `revise r${rounds}` })
  if (!plan) return { status: 'FAILED', reason: 'slice-planner returned nothing on revision', reports }
  reports[`plan${rounds + 1}`] = plan.report
  if (plan.status !== 'OK') return { status: 'NEEDS_HUMAN', reason: plan.report, stage: 'revise', plan, reports }
  if (questions(plan).length) return { status: 'NEEDS_HUMAN', reason: 'blocking questions for the human', stage: 'revise', openQuestions: questions(plan), plan, reports }
}

return { status: 'APPROVED', reason: '', openQuestions: [], plan, review, rounds, reports }
