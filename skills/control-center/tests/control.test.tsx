import { describe, expect, mock, test } from 'claude-code/testing'

import { age, arrivals, grouped, parseBoard, splitDetail, summary, urlLabel } from '../hooks/board'

const row = (id: string, name: string, waiting: string, detail = '') =>
  ({ id, name, waiting, detail, cwd: '~/w', started: '2026-10-17T10:00:00+00:00' })

const BOARD = [
  row('a', 'PROD-1', 'needs input', 'question in the session'),
  row('b', 'PROD-2', 'draft ready', 'https://github.com/o/r/pull/3994 https://github.com/o/r/pull/3995'),
  row('c', 'PROD-3', 'working'),
  row('d', 'PROD-4', 'waiting review', 'https://github.com/o/r/pull/3962'),
]

describe('board', () => {
  test('groups in the control center order, empty groups left out', async () => {
    const g = grouped(parseBoard(JSON.stringify([...BOARD].reverse())))
    expect(g.map(x => x.group)).toEqual(['needs input', 'draft ready', 'working', 'waiting review'])
  })

  test('the summary counts what waits on the owner', async () => {
    expect(summary(BOARD)).toBe('agents: 1 input · 1 draft')
    expect(summary([row('c', 'PROD-3', 'working')])).toBe('agents: nothing on you · 1 working')
  })

  test('an agent that starts waiting on the owner is an arrival, once', async () => {
    const before = [row('a', 'PROD-1', 'working'), row('b', 'PROD-2', 'draft ready')]
    expect(arrivals(before, BOARD).map(a => a.id)).toEqual(['a'])
    expect(arrivals([], BOARD)).toEqual([])
  })

  test('details split into text and PR links', async () => {
    expect(splitDetail(BOARD[1]!.detail).urls.map(urlLabel)).toEqual(['#3994', '#3995'])
    expect(splitDetail('plan on PROD-9 in Linear')).toEqual({ text: 'plan on PROD-9 in Linear', urls: [] })
  })

  test('ages read nushell datetimes', async () => {
    expect(age('2026-10-17T10:00:00+00:00', Date.parse('2026-10-17T12:00:00Z'))).toBe('2h')
    expect(age('not a date', 0)).toBe('')
  })

  test('a malformed board is empty, a malformed row dropped', async () => {
    expect(parseBoard('')).toEqual([])
    expect(parseBoard('[{"id":"x"},{"id":"y","waiting":"done"}]').map(a => a.id)).toEqual(['y'])
  })
})

test('/control draws the agents grouped, with PR links and a status line', async ($, on) => {
  mock.clock(on, { now: Date.parse('2026-10-17T12:00:00Z') })
  const runs: string[][] = []
  on('process.run', ($, e) => {
    runs.push([...e.argv])
    return { value: { exitCode: 0, stdout: JSON.stringify(BOARD), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  let status: string | undefined
  on('ui.status', ($, e, next) => {
    status = e.text
    return next(e)
  })

  await $.command.run({
    command: 'control', args: '', origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 160 },
  })
  expect(runs[0]?.at(-1)).toContain('inbox board | to json')
  expect(status).toBe('agents: 1 input · 1 draft')

  const ui = await $.ui.mount({
    plugin: 'control-center', surface: 'terminal', component: 'Pane', requestId: 'control',
    props: {
      title: 'Agents', isFocused: true, bodyColumns: 80, placement: 'dock',
      scroll: { offset: 0, bodyRows: 40 }, view: {},
    },
  })
  expect(await ui.find({ type: 'Text', text: /needs input \(1\)/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /draft ready \(1\)/ })).toBeDefined()
  expect((await ui.find({ key: 'b' }))?.text).toContain('PROD-2')
  expect((await ui.findAll({ type: 'Link' })).map(l => l.text)).toEqual(['#3994', '#3995', '#3962'])

  await ui.press({ key: 'b' })
  expect(runs.at(-1)?.at(-1)).toContain('inbox attach b')
  await ui.unmount()
})
