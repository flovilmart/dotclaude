// harness.mjs — run a saved workflow script offline with scripted agents.
//
// A workflow script is the body of an async function with the globals
// args, agent, parallel, phase and log; `export const meta` is the only
// module syntax it uses. The harness strips that and runs the body with stubs.
//
//   const { result, calls } = await run('subtask.js', args, {
//     implementer: [reply1, reply2],          // replies in call order
//     verifier: (prompt, opts) => reply,      // or a function
//   })
//
// An agent type with no replies left (or none given) returns `fallback(type)`.

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const dir = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

const PASS = {
  implementer: { status: 'DONE', commits: [], uncertain: [], report: 'done' },
  'code-challenger': { verdict: 'APPROVE', blocking: [], should: [], nits: [], report: 'approve' },
  verifier: { result: 'PASS', changedLines: 100, report: 'pass' },
  'security-reviewer': { verdict: 'PASS', blocking: [], should: [], report: 'pass' },
  'smoke-tester': { result: 'PASS', report: 'pass' },
  'slice-planner': { status: 'OK', flag: '', slices: [], report: 'plan' },
  'design-challenger': { verdict: 'APPROVE', blocking: [], should: [], report: 'approve' },
}

export async function run(script, args, replies = {}) {
  const src = fs.readFileSync(path.join(dir, script), 'utf8').replace(/^export const meta/m, 'const meta')
  const calls = []
  const queues = Object.fromEntries(Object.entries(replies).map(([k, v]) => [k, Array.isArray(v) ? [...v] : v]))
  const agent = async (prompt, opts) => {
    calls.push({ type: opts.agentType, label: opts.label, prompt, model: opts.model, effort: opts.effort })
    const q = queues[opts.agentType]
    if (typeof q === 'function') return q(prompt, opts)
    if (q && q.length) return q.shift()
    return PASS[opts.agentType]
  }
  const parallel = (fns) => Promise.all(fns.map((f) => f()))
  const body = new AsyncFunction('args', 'agent', 'parallel', 'phase', 'log', src)
  const result = await body(args, agent, parallel, () => {}, () => {})
  return { result, calls, labels: calls.map((c) => c.label) }
}
