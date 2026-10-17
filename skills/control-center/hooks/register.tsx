// /control: a live pane of every background agent, grouped by what it waits on.
//
// The data is `inbox board` (nu/shell/inbox.nu): `claude agents --json`, the watcher's waiting.json and the
// coordinators' state files. Nothing runs until /control opens the pane; then it refreshes every 15 s, keeps
// a summary in the status line, and toasts an agent that starts waiting on you. Pressing an agent brings it
// up in tmux (`inbox attach`); `o` opens every agent waiting on you (`inbox open`), `r` refreshes.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Board } from '../types'
import { COLORS, age, arrivals, grouped, parseBoard, splitDetail, summary, urlLabel } from './board'

const PANE = 'control'
const EVERY_MS = 15_000
const board = atom({ plugin: 'control-center', key: 'board' } as const, { agents: [], updatedAt: 0, error: null } as Board)

const inbox = (cmd: string) => ['nu', '--no-config-file', '-c', `use ~/.claude/nu/shell/inbox.nu; ${cmd}`]

let timer: { cancel: () => void } | null = null
let refreshing = false

async function refresh($: EngineInterface) {
  if (refreshing) return
  refreshing = true
  try {
    const run = await $.process.run(inbox('inbox board | to json'), { timeoutMs: 20_000 })
    const now = await $.clock.now()
    if (run.exitCode !== 0) {
      await update($, board, b => ({ ...b, updatedAt: now, error: run.stderr.trim().split('\n').at(-1) ?? 'inbox board failed' }))
      return
    }
    const agents = parseBoard(run.stdout)
    const before = (await read($, board)).agents
    await update($, board, () => ({ agents, updatedAt: now, error: null }))
    $.ui.status(summary(agents))
    for (const a of arrivals(before, agents)) $.ui.toast(`${a.name || a.id} · ${a.waiting}`)
  } catch (err) {
    const now = await $.clock.now()
    await update($, board, b => ({ ...b, updatedAt: now, error: String(err) }))
  } finally {
    refreshing = false
  }
}

async function attach($: EngineInterface, id: string) {
  if (!/^[A-Za-z0-9-]+$/.test(id)) return
  const run = await $.process.run(inbox(`inbox attach ${id} | to json`))
  if (run.exitCode !== 0) $.ui.toast(`Not in tmux? Run: claude attach ${id}`)
}

async function openAll($: EngineInterface) {
  const run = await $.process.run(inbox('inbox open'), { timeoutMs: 60_000 })
  $.ui.toast(run.exitCode === 0 ? run.stdout.trim().split('\n').at(-1) ?? 'Opened' : 'inbox open needs tmux')
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'control',
      description: 'Control center: every background agent, grouped by what it waits on',
    })

    return next(e)
  })

  on('command.run', { command: 'control' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Agents', focus: true })
    if (timer === null) timer = $.clock.every(EVERY_MS, () => void refresh($))
    await refresh($)

    return { text: 'Control center opened: press an agent to bring it up in tmux, o opens everything on you, r refreshes.' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button, Link } = $.ui.resolve(e)
    const b = await read($, board)
    const now = await $.clock.now()
    const ago = b.updatedAt === 0 ? 'loading…' : `updated ${Math.round((now - b.updatedAt) / 1000)}s ago`

    return (
      <Box flexDirection="column">
        <Box flexDirection="row" gap={1}>
          <Text bold>{summary(b.agents)}</Text>
          <Text dimColor>{ago}</Text>
        </Box>
        <Box flexDirection="row" gap={1}>
          <Button key="open-all" label="Open all on me" hotkey="o" onPress={() => void openAll($)} />
          <Button key="refresh" label="Refresh" hotkey="r" onPress={() => void refresh($)} />
        </Box>
        {b.error !== null && <Text color="red">{b.error}</Text>}
        {grouped(b.agents).map(g => (
          <Box key={g.group} flexDirection="column" marginTop={1}>
            <Text bold color={COLORS[g.group]} dimColor={COLORS[g.group] === undefined}>
              {g.group} ({g.agents.length})
            </Text>
            {g.agents.map(a => {
              const d = splitDetail(a.detail)
              return (
                <Box key={a.id} flexDirection="row" gap={1}>
                  <Button key={a.id} onPress={() => void attach($, a.id)}>
                    {a.name || a.id} <Text dimColor>{age(a.started, now)}</Text>
                  </Button>
                  {d.text !== '' && <Text dimColor wrap="truncate-end">{d.text}</Text>}
                  {d.urls.map(u => <Link key={u} href={u} label={urlLabel(u)} />)}
                </Box>
              )
            })}
          </Box>
        ))}
      </Box>
    )
  })
}
