// Regression tests for workflows/subtask.js. Run: node --test ~/.claude/workflows/test/*.test.mjs
import test from 'node:test'
import assert from 'node:assert/strict'
import { run } from './harness.mjs'

const ARGS = { ticket: 'ENG-1', branch: 'eng-1-s1', base: 'main', security: false, smoke: false }
const impl = (commits, extra = {}) => ({ status: 'DONE', commits, uncertain: [], report: 'impl', ...extra })
const review = (blocking = [], should = [], extra = {}) =>
  ({ verdict: blocking.length ? 'REQUEST_CHANGES' : 'APPROVE', blocking, should, nits: [], report: 'review', ...extra })
const finding = (issue) => ({ location: 'src/a.ts:1', issue })

test('happy path is READY with one pass of each stage', async () => {
  const { result, labels } = await run('subtask.js', ARGS, { implementer: [impl(['a1 feat'])] })
  assert.equal(result.status, 'READY')
  assert.deepEqual(labels, ['implement eng-1-s1', 'review r1', 'verify r1'])
})

test('commits made to fix the verifier are code-reviewed before READY', async () => {
  const { result, labels } = await run('subtask.js', ARGS, {
    implementer: [impl(['a1 feat']), impl(['b2 fix types'])],
    verifier: [{ result: 'FAIL', failures: 'TS2345', changedLines: 100, report: 'fail' }],
  })
  assert.equal(result.status, 'READY')
  assert.deepEqual(labels.slice(-3), ['fix verify r1', 'verify r2', 'review fixes r1'])
})

test('fix review scope names only the unreviewed commits', async () => {
  const { calls } = await run('subtask.js', ARGS, {
    implementer: [impl(['a1 feat']), impl(['b2 fix types'])],
    verifier: [{ result: 'FAIL', failures: 'TS2345', changedLines: 100, report: 'fail' }],
  })
  const final = calls.find((c) => c.label === 'review fixes r1').prompt
  assert.match(final, /b2 fix types/)
  assert.doesNotMatch(final, /a1 feat/)
})

test('commits made to fix a gate are code-reviewed before READY', async () => {
  const { result, labels } = await run('subtask.js', { ...ARGS, security: true }, {
    implementer: [impl(['a1 feat']), impl(['c3 escape input'])],
    'security-reviewer': [{ verdict: 'BLOCK', blocking: [finding('sql injection')], should: [], report: 'block' }],
  })
  assert.equal(result.status, 'READY')
  assert.ok(labels.indexOf('review fixes r1') > labels.indexOf('fix gates r1'))
})

test('a PARTIAL implementation is sent back once, then escalated', async () => {
  const partial = impl(['a1 half'], { status: 'PARTIAL', report: 'half done' })
  const once = await run('subtask.js', ARGS, { implementer: [partial, impl(['a2 rest'])] })
  assert.equal(once.result.status, 'READY')
  assert.ok(once.labels.includes('complete partial'))

  const twice = await run('subtask.js', ARGS, { implementer: [partial, partial] })
  assert.equal(twice.result.status, 'NEEDS_HUMAN')
  assert.equal(twice.result.stage, 'implement')
})

test('should findings sent to the fixer are not carried into the PR body', async () => {
  const { result } = await run('subtask.js', ARGS, {
    implementer: [impl(['a1 feat']), impl(['b2 fix'])],
    'code-challenger': [review([finding('B1')], [finding('S1')]), review([], [finding('S2'), finding('S2')])],
  })
  assert.equal(result.status, 'READY')
  assert.deepEqual(result.carried.should.map((f) => f.issue), ['S2'])
})

test('an oversized slice stops with a request to split it', async () => {
  const { result } = await run('subtask.js', { ...ARGS, maxLines: 400 }, {
    verifier: [{ result: 'PASS', changedLines: 950, report: 'pass' }],
  })
  assert.equal(result.status, 'NEEDS_HUMAN')
  assert.equal(result.stage, 'size')
})

test('a failed re-verify after a gate fix gets a fix round instead of escalating', async () => {
  const { result, labels } = await run('subtask.js', { ...ARGS, smoke: true }, {
    implementer: [impl(['a1 feat']), impl(['c3 fix smoke']), impl(['d4 fix lint'])],
    'smoke-tester': [{ result: 'FAIL', report: '500 on POST /x' }],
    verifier: [
      { result: 'PASS', changedLines: 100, report: 'pass' },
      { result: 'FAIL', failures: 'lint', changedLines: 100, report: 'fail' },
    ],
  })
  assert.equal(result.status, 'READY')
  assert.ok(labels.includes('fix verify after gate fix r1'))
})

test('reports from repeated rounds are kept, not overwritten', async () => {
  const { result } = await run('subtask.js', { ...ARGS, smoke: true, security: true }, {
    implementer: [impl(['a1 feat']), impl(['c3 fix smoke'])],
    'smoke-tester': [{ result: 'FAIL', report: 'smoke one' }, { result: 'PASS', report: 'smoke two' }],
    'security-reviewer': [
      { verdict: 'PASS', blocking: [], should: [], report: 'security one' },
      { verdict: 'PASS', blocking: [], should: [], report: 'security two' },
    ],
  })
  assert.equal(result.reports.smoke2, 'smoke two')
  assert.equal(result.reports.security1, 'security one')
  assert.equal(result.reports.security2, 'security two')
})

test('READY carries what the validation packet needs', async () => {
  const { result } = await run('subtask.js', { ...ARGS, smoke: true }, {
    implementer: [impl(['a1 feat'], { uncertain: ['src/a.ts:10 — chose UTC'], deviations: ['merged steps 2 and 3'] })],
    'code-challenger': [review([], [], { coverage: [{ criterion: 'AC1', test: 'test/a.test.ts:4' }] })],
    'smoke-tester': [{ result: 'PASS', criteria: [{ criterion: 'AC1', how: 'curl', evidence: '201' }], report: 'pass' }],
  })
  assert.deepEqual(result.uncertain, ['src/a.ts:10 — chose UTC'])
  assert.deepEqual(result.deviations, ['merged steps 2 and 3'])
  assert.equal(result.coverage[0].test, 'test/a.test.ts:4')
  assert.equal(result.smokeCriteria[0].evidence, '201')
  assert.equal(result.changedLines, 100)
})

test('a blocked implementer returns its question', async () => {
  const { result } = await run('subtask.js', ARGS, {
    implementer: [impl([], { status: 'BLOCKED', question: 'Change the API?' })],
  })
  assert.equal(result.status, 'BLOCKED')
  assert.equal(result.question, 'Change the API?')
})

test('review blocking after maxRounds escalates with the open findings', async () => {
  const { result } = await run('subtask.js', { ...ARGS, maxRounds: 1 }, {
    'code-challenger': () => review([finding('B1')]),
  })
  assert.equal(result.status, 'NEEDS_HUMAN')
  assert.equal(result.open[0].issue, 'B1')
})
