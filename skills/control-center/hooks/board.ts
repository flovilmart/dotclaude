// The control center's logic, without the engine: what `inbox board` printed, grouped and summarised.
import type { Agent } from '../types'

/** The groups, in the order drawn: the waits on the owner, then the rest (nu/shell/inbox.nu GROUPS) */
export const GROUPS = ['needs input', 'needs plan validation', 'draft ready', 'working', 'waiting review', 'done'] as const

/** The groups waiting on the owner */
export const ON_ME: readonly string[] = GROUPS.slice(0, 3)

const SHORT: Record<string, string> = {
  'needs input': 'input',
  'needs plan validation': 'plan',
  'draft ready': 'draft',
  working: 'working',
  'waiting review': 'review',
  done: 'done',
}

export const COLORS: Record<string, string> = {
  'needs input': 'red',
  'needs plan validation': 'yellow',
  'draft ready': 'cyan',
  working: 'green',
}

/** `inbox board | to json` → agents; a row missing an id or a group is dropped */
export function parseBoard(stdout: string): Agent[] {
  const rows: unknown = JSON.parse(stdout.trim() === '' ? '[]' : stdout)
  if (!Array.isArray(rows)) return []
  return rows.flatMap((r: any) =>
    typeof r?.id === 'string' && typeof r?.waiting === 'string'
      ? [{ id: r.id, name: String(r.name ?? ''), waiting: r.waiting, detail: String(r.detail ?? ''), cwd: String(r.cwd ?? ''), started: String(r.started ?? '') }]
      : [],
  )
}

/** Agents by group, in GROUPS order, empty groups left out (an unknown group goes last) */
export function grouped(agents: readonly Agent[]): { group: string; agents: Agent[] }[] {
  const order = (g: string) => (GROUPS as readonly string[]).indexOf(g) === -1 ? GROUPS.length : (GROUPS as readonly string[]).indexOf(g)
  const groups = [...new Set(agents.map(a => a.waiting))].sort((a, b) => order(a) - order(b))
  return groups.map(group => ({ group, agents: agents.filter(a => a.waiting === group) }))
}

/** The status line: what waits on the owner, e.g. "agents: 2 input · 1 plan · 3 draft" */
export function summary(agents: readonly Agent[]): string {
  const parts = ON_ME.flatMap(g => {
    const n = agents.filter(a => a.waiting === g).length
    return n === 0 ? [] : [`${n} ${SHORT[g]}`]
  })
  const working = agents.filter(a => a.waiting === 'working').length
  return parts.length === 0 ? `agents: nothing on you · ${working} working` : `agents: ${parts.join(' · ')}`
}

/** Agents that moved into a group on the owner since the previous board */
export function arrivals(before: readonly Agent[], after: readonly Agent[]): Agent[] {
  const was = new Map(before.map(a => [a.id, a.waiting]))
  return after.filter(a => ON_ME.includes(a.waiting) && was.get(a.id) !== a.waiting && before.length > 0)
}

/** The URLs in a detail, and the text around them */
export function splitDetail(detail: string): { text: string; urls: string[] } {
  const words = detail.split(/\s+/).filter(w => w !== '')
  const urls = words.filter(w => /^https?:\/\//.test(w))
  return { text: words.filter(w => !urls.includes(w)).join(' '), urls }
}

/** A short label for a PR or issue URL: "#3994", else the URL */
export function urlLabel(url: string): string {
  const m = url.match(/\/pull\/(\d+)/)
  return m ? `#${m[1]}` : url
}

/** "5m", "2h", "3d" since a nushell datetime string */
export function age(started: string, now: number): string {
  const t = Date.parse(started)
  if (Number.isNaN(t)) return ''
  const m = Math.max(0, Math.round((now - t) / 60000))
  return m < 60 ? `${m}m` : m < 60 * 24 ? `${Math.round(m / 60)}h` : `${Math.round(m / 1440)}d`
}
