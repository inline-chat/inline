import { setTimeout, clearTimeout } from "node:timers"
import { Method } from "@inline-chat/protocol/core"

export const PREAUTH_FRAME_BYTES = 64 * 1024
export const REALTIME_FRAME_BYTES = 16 * 1024 * 1024
export const PREAUTH_METHODS: ReadonlySet<Method> = new Set([Method.GET_USERS, Method.SEARCH_USERS])
export const MAX_USER_CONNECTIONS = 64

export type ConnectionLease = { activate(): boolean; release(): void }
export const makeConnectionAdmission = (limits = { total: 4_096, perIp: 128, upgradesPerMinute: 120 }) => {
  let total = 0
  const active = new Map<string, number>()
  const windows = new Map<string, { start: number; count: number }>()
  const leases = new Set<ConnectionLease>()
  return {
    acquire(ip: string, now = Date.now()): ConnectionLease | undefined {
      if (total >= limits.total || (active.get(ip) ?? 0) >= limits.perIp) return undefined
      if (windows.size >= 10_000) {
        for (const [key, window] of windows) if (now - window.start >= 60_000) windows.delete(key)
        if (!windows.has(ip) && windows.size >= 10_000) return undefined
      }
      let window = windows.get(ip)
      if (!window || now - window.start >= 60_000) {
        window = { start: now, count: 0 }
        windows.set(ip, window)
      }
      if (window.count >= limits.upgradesPerMinute) return undefined
      window.count++
      total++
      active.set(ip, (active.get(ip) ?? 0) + 1)
      let released = false
      const lease: ConnectionLease = {
        activate() { clearTimeout(timer); return !released },
        release() {
          if (released) return
          released = true
          clearTimeout(timer)
          total--
          const count = (active.get(ip) ?? 1) - 1
          if (count === 0) active.delete(ip)
          else active.set(ip, count)
          leases.delete(lease)
        },
      }
      const timer = setTimeout(() => lease.release(), 10_000)
      timer.unref()
      leases.add(lease)
      return lease
    },
    shutdown() { for (const lease of leases) lease.release() },
  }
}

type MessageBudget = { preauth: number; initializations: number; initializing: boolean }
const budgets = new WeakMap<object, MessageBudget>()
export function admitPreauthMessage(connection: object, authenticated: boolean, initialization: boolean): (() => void) | undefined {
  if (authenticated) return () => {}
  let budget = budgets.get(connection)
  if (!budget) { budget = { preauth: 0, initializations: 0, initializing: false }; budgets.set(connection, budget) }
  if (++budget.preauth > 10 || (initialization && (budget.initializing || ++budget.initializations > 3))) return undefined
  if (initialization) budget.initializing = true
  return () => { if (initialization) budget.initializing = false }
}
