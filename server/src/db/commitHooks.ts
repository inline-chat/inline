import type { Transaction } from "./types"
import { Log } from "@in/server/utils/log"

const log = new Log("db.commitHooks")

/**
 * A best-effort side effect that must begin only after its owning database
 * transaction has committed. Implementations may merge later registrations
 * with the same key into one more-recent effect.
 */
export type PostCommitHook = {
  run: () => Promise<void>
  merge?: (next: PostCommitHook) => void
}

type HookState = {
  hooks: Map<string | symbol, PostCommitHook>
}

type TransactionCallback<T> = (tx: Transaction) => Promise<T>
type TransactionInvoker = <T>(callback: TransactionCallback<T>, config?: unknown) => Promise<T>
type TransactionOwner = {
  transaction: TransactionInvoker
}

const hookStates = new WeakMap<object, HookState>()
const wrappedTransactions = new WeakSet<object>()

export const maxConcurrentPostCommitHooks = 32
export const maxQueuedPostCommitHooks = 4_096
const pendingHooks = new Map<string | symbol, PostCommitHook>()
const idleWaiters = new Set<() => void>()
let activeHooks = 0
let lastSaturationWarningAt = 0

const notifyWhenIdle = () => {
  if (pendingHooks.size !== 0 || activeHooks !== 0) return
  for (const resolve of idleWaiters) resolve()
  idleWaiters.clear()
}

const runPendingHooks = () => {
  while (activeHooks < maxConcurrentPostCommitHooks && pendingHooks.size > 0) {
    const next = pendingHooks.entries().next().value as [string | symbol, PostCommitHook] | undefined
    if (!next) return
    const [key, hook] = next
    pendingHooks.delete(key)
    activeHooks += 1
    void Promise.resolve()
      .then(() => hook.run())
      .catch((error) => {
        // A committed mutation stays successful even when a transient hint
        // cannot be sent. Durable replay/repair remains the recovery path.
        log.warn("Post-commit hook failed", { error })
      })
      .finally(() => {
        activeHooks -= 1
        runPendingHooks()
        notifyWhenIdle()
      })
  }
}

const recordSaturation = () => {
  if (Date.now() - lastSaturationWarningAt < 60_000) return
  lastSaturationWarningAt = Date.now()
  log.warn("Post-commit hook queue is saturated; dropping transient notifications", {
    capacity: maxQueuedPostCommitHooks,
  })
}

const enqueuePendingHook = (key: string | symbol, hook: PostCommitHook) => {
  const pending = pendingHooks.get(key)
  if (pending) {
    try {
      if (!pending.merge) throw new Error("queued post-commit hook has no merge function")
      pending.merge(hook)
    } catch (error) {
      // Dispatch happens after the mutation committed. A bad secondary hook
      // must never surface to its caller or block unrelated notifications.
      log.warn("Could not merge queued post-commit hook", { error })
    }
    return
  }
  if (pendingHooks.size >= maxQueuedPostCommitHooks) {
    recordSaturation()
    return
  }
  pendingHooks.set(key, hook)
}

const dispatch = (state: HookState) => {
  for (const [key, hook] of state.hooks) enqueuePendingHook(key, hook)
  runPendingHooks()
}

const addHook = (state: HookState, key: string | symbol, hook: PostCommitHook) => {
  const current = state.hooks.get(key)
  if (!current) {
    state.hooks.set(key, hook)
    return
  }
  if (!current.merge) throw new Error("Post-commit hook key was registered more than once without a merge function")
  current.merge(hook)
}

const mergeHooks = (target: HookState, source: HookState) => {
  for (const [key, hook] of source.hooks) addHook(target, key, hook)
}

const wrapNestedTransaction = (tx: Transaction, parentState: HookState) => {
  const transaction = tx as Transaction & object & TransactionOwner
  if (wrappedTransactions.has(transaction)) return
  wrappedTransactions.add(transaction)

  const original = transaction.transaction.bind(tx) as TransactionInvoker
  Object.defineProperty(transaction, "transaction", {
    configurable: true,
    value: async <T>(callback: TransactionCallback<T>, config?: unknown): Promise<T> => {
      let nestedState: HookState | undefined
      const result = await original(async (nestedTx) => {
        nestedState = { hooks: new Map() }
        hookStates.set(nestedTx, nestedState)
        wrapNestedTransaction(nestedTx, nestedState)
        try {
          return await callback(nestedTx)
        } finally {
          hookStates.delete(nestedTx)
        }
      }, config)

      // postgres-js resolves a savepoint transaction only after RELEASE. A
      // rejected savepoint never reaches this merge, so its effects are lost.
      if (nestedState) mergeHooks(parentState, nestedState)
      return result
    },
    writable: true,
  })
}

/**
 * Installs commit-aware transaction wrappers on one Drizzle database object.
 * The returned value retains the exact database type, including transaction
 * generics and options at callers.
 */
export const installPostCommitHooks = <TDatabase extends object>(database: TDatabase): TDatabase => {
  const owner = database as TDatabase & TransactionOwner
  if (wrappedTransactions.has(owner)) return database
  wrappedTransactions.add(owner)

  const original = owner.transaction.bind(database) as TransactionInvoker
  Object.defineProperty(owner, "transaction", {
    configurable: true,
    value: async <T>(callback: TransactionCallback<T>, config?: unknown): Promise<T> => {
      let rootState: HookState | undefined
      const result = await original(async (tx) => {
        rootState = { hooks: new Map() }
        hookStates.set(tx, rootState)
        wrapNestedTransaction(tx, rootState)
        try {
          return await callback(tx)
        } finally {
          hookStates.delete(tx)
        }
      }, config)

      // `original` resolves only after the outer database COMMIT. Start the
      // non-critical notifications afterwards and never extend mutation
      // latency or turn publication failure into a mutation failure.
      if (rootState) dispatch(rootState)
      return result
    },
    writable: true,
  })
  return database
}

/** Register a coalescible side effect for this exact transaction object. */
export const registerPostCommitHook = (tx: Transaction, key: string | symbol, hook: PostCommitHook) => {
  const state = hookStates.get(tx)
  if (!state) {
    throw new Error("Post-commit hooks require a transaction created by the configured database")
  }
  addHook(state, key, hook)
}

/**
 * Wait for already-committed hooks during test teardown or graceful shutdown.
 * Normal mutation paths must never await these best-effort notifications.
 */
export const waitForPostCommitHooks = (): Promise<void> => {
  if (pendingHooks.size === 0 && activeHooks === 0) return Promise.resolve()
  return new Promise((resolve) => idleWaiters.add(resolve))
}
