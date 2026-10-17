/** One background session as `inbox board` lists it */
export type Agent = {
  id: string
  name: string
  /** one of GROUPS */
  waiting: string
  detail: string
  cwd: string
  /** when it started, as nushell writes a datetime */
  started: string
}

export type Board = {
  agents: Agent[]
  /** epoch ms of the last refresh, 0 before the first */
  updatedAt: number
  /** why the last refresh failed, or null */
  error: string | null
}

declare module 'claude-code' {
  interface PluginState {
    'control-center': { board: Board }
  }
}
