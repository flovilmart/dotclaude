// Regression tests for workflows/plan.js. Run: node --test ~/.claude/workflows/test/*.test.mjs
import test from 'node:test'
import assert from 'node:assert/strict'
import { run } from './harness.mjs'

const ARGS = { ticket: 'ENG-1', worktree: '/tmp/wt', spec: 'spec', profile: 'profile', baseBranch: 'eng-1' }
const plan = (extra = {}) => ({ status: 'OK', flag: '', slices: [{ n: 1 }], report: 'plan', ...extra })
const blocking = { verdict: 'REVISE', blocking: [{ finding: 'too big' }], should: [], report: 'revise' }

test('approved plan', async () => {
  const { result, labels } = await run('plan.js', ARGS, { 'slice-planner': [plan()] })
  assert.equal(result.status, 'APPROVED')
  assert.deepEqual(labels, ['plan', 'challenge r1'])
})

test('open questions stop the run before the challenge', async () => {
  const { result, labels } = await run('plan.js', ARGS, { 'slice-planner': [plan({ openQuestions: ['Which tenant?'] })] })
  assert.equal(result.status, 'NEEDS_HUMAN')
  assert.deepEqual(result.openQuestions, ['Which tenant?'])
  assert.deepEqual(labels, ['plan'])
})

test('a revision that raises questions stops too', async () => {
  const { result } = await run('plan.js', ARGS, {
    'slice-planner': [plan(), plan({ openQuestions: ['Keep v1?'] })],
    'design-challenger': [blocking],
  })
  assert.equal(result.status, 'NEEDS_HUMAN')
  assert.equal(result.stage, 'revise')
})

test('blocking findings after maxRounds escalate', async () => {
  const { result } = await run('plan.js', { ...ARGS, maxRounds: 1 }, {
    'slice-planner': () => plan(),
    'design-challenger': () => blocking,
  })
  assert.equal(result.status, 'NEEDS_HUMAN')
  assert.equal(result.open[0].finding, 'too big')
})
