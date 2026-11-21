import { db, queryPoolCapacity } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { sql } from "drizzle-orm"
import { searchFailureClass } from "./cloudFailure"

const DEADLINE_MS = 15_000
const STATEMENT_TIMEOUT_MS = 3_000
export type CloudSearchBudget = {
  check: () => void
  snapshot: <T>(read: (tx: Transaction) => Promise<T>) => Promise<T>
}

type Request = { cancel: () => void; run: () => Promise<void> }
type Slot = { running: Request; waiting?: Request }
const sessions = new Map<string, Slot>()

/** A slot holds at most one physical operation and its newest replacement. */
export function withCloudSearchBudget<T>(
  actor: number,
  session: number,
  signal: AbortSignal | undefined,
  search: (budget: CloudSearchBudget) => Promise<T>,
): Promise<T> {
  const sessionKey = `${actor}/${session}`
  const slot = sessions.get(sessionKey)
  if (signal?.aborted) return Promise.reject(RealtimeRpcError.RequestTimeout("Search canceled"))
  if (!slot && sessions.size >= Math.max(1, Math.floor(queryPoolCapacity() / 3)))
    return Promise.reject(RealtimeRpcError.RateLimit(1))
  return new Promise<T>((resolve, reject) => {
    let canceled: RealtimeRpcError | undefined
    const deadline = performance.now() + DEADLINE_MS
    const cancel = (error: RealtimeRpcError) => {
      canceled = error
      if (slot?.waiting === request) slot.waiting = undefined
      cleanup()
      reject(error)
    }
    const onAbort = () => cancel(RealtimeRpcError.RequestTimeout("Search canceled"))
    const timer = setTimeout(() => cancel(RealtimeRpcError.RequestTimeout()), DEADLINE_MS)
    timer.unref()
    const cleanup = () => {
      clearTimeout(timer)
      signal?.removeEventListener("abort", onAbort)
    }
    const check = () => {
      if (canceled) throw canceled
      if (performance.now() >= deadline) throw RealtimeRpcError.RequestTimeout()
    }
    const request: Request = {
      cancel: () => cancel(RealtimeRpcError.RequestTimeout("Search superseded")),
      run: async () => {
        try {
          check()
          const result = await search({
            check,
            snapshot: (read) => {
              check()
              return db.transaction(
                async (tx) => {
                  check()
                  await tx.execute(sql`select set_config('statement_timeout', ${String(STATEMENT_TIMEOUT_MS)}, true),
                 set_config('jit', 'off', true), set_config('lock_timeout', '1000', true), set_config('idle_in_transaction_session_timeout', '5000', true)`)
                  check()
                  const value = await read(tx)
                  check()
                  return value
                },
                { isolationLevel: "repeatable read", accessMode: "read only" },
              )
            },
          })
          check()
          resolve(result)
        } catch (error) {
          reject(searchFailureClass(error) === "database-timeout" ? RealtimeRpcError.RequestTimeout() : error)
        } finally {
          cleanup()
          const current = sessions.get(sessionKey)!
          if (current.waiting) {
            current.running = current.waiting
            current.waiting = undefined
            void current.running.run()
          } else sessions.delete(sessionKey)
        }
      },
    }
    signal?.addEventListener("abort", onAbort, { once: true })
    if (slot) {
      slot.running.cancel()
      slot.waiting?.cancel()
      slot.waiting = request
    } else {
      sessions.set(sessionKey, { running: request })
      void request.run()
    }
  })
}
