/**
 * Ties a view store to a core endpoint: subscriptions, intents with local
 * echo, patches through the frame lane, resync on a gap.
 */

import type {
  Command,
  CoreEndpoint,
  CoreMessage,
  Intent,
  IntentResult,
  QueryDescriptor,
  ResourceValue,
  RowKey,
  SubId,
  TxId,
} from "@inline/core-protocol"
import type { Scheduler } from "../schedule"
import type { ReadSignal } from "../signals"
import { ViewStore, type ExportOptions, type OptimisticRow, type StoreSnapshotData } from "./view-store"

export type EnsureRange = Extract<Command, { kind: "ensure" }>["range"]

export interface SubscriptionHandle {
  readonly sub: SubId
  readonly query: QueryDescriptor
  /** Ordered row keys; overlay rows appended to this subscription come last. */
  readonly list: ReadSignal<readonly RowKey[]>
  readonly resource: ReadSignal<ResourceValue | undefined>
  /** Ask the core to extend or move the window. */
  ensure(range: EnsureRange): void
  /** Stop the subscription. Idempotent. */
  unsubscribe(): void
}

/**
 * Resolves with the first result the core reports for the intent; rejects
 * with `StoreDisposedError` if the client is disposed first.
 */
export type IntentHandle = Promise<IntentResult> & { readonly tx: TxId }

/** Subscriptions exported with their queries, for the boot snapshot. */
export type ClientSnapshotData = {
  format: 1
  queries: { sub: SubId; query: QueryDescriptor }[]
  store: StoreSnapshotData
}

export type StoreClientOptions = {
  endpoint: CoreEndpoint
  scheduler: Scheduler
  store?: ViewStore
  /** Transaction IDs must be unique across every context of the account. */
  newTxId?: () => TxId
  /**
   * Called after each frame-lane batch has been applied, for performance
   * tracing. `waitedMs` is how long the batch's first message waited for its
   * frame. Must be cheap; it runs on every batch.
   */
  onBatch?: (info: StoreBatchInfo) => void
}

export type StoreBatchInfo = {
  messages: number
  rows: number
  waitedMs: number
}

export interface StoreClient {
  readonly store: ViewStore
  subscribe(query: QueryDescriptor): SubscriptionHandle
  /**
   * Send an intent. Its optimistic rows are installed in the sync lane, so
   * they are readable before this returns; then the command is posted.
   */
  intent(intent: Intent, optimistic?: readonly OptimisticRow[]): IntentHandle
  /** True between a detected gap and the snapshot that answers the resync. */
  resyncing(): boolean
  exportSubscriptions(handles: readonly SubscriptionHandle[], options?: ExportOptions): ClientSnapshotData
  /** Install exported subscriptions as provisional state and subscribe to their queries again. */
  restore(data: ClientSnapshotData): SubscriptionHandle[]
  dispose(): void
}

const randomContextId = (): string => {
  const bytes = new Uint8Array(8)
  const crypto = (globalThis as { crypto?: { getRandomValues?: (array: Uint8Array) => Uint8Array } }).crypto
  if (crypto?.getRandomValues) crypto.getRandomValues(bytes)
  else for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256)
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")
}

export const txIdAllocator = (contextId: string = randomContextId()): (() => TxId) => {
  let next = 1
  return () => `${contextId}-${next++}`
}

export const createStoreClient = (options: StoreClientOptions): StoreClient => {
  const { endpoint, scheduler } = options
  const store = options.store ?? new ViewStore()
  const newTxId = options.newTxId ?? txIdAllocator()
  const handles = new Map<SubId, SubscriptionHandle>()
  let nextSub = 1
  let inbox: CoreMessage[] = []
  let resyncing = false
  let disposed = false
  let sweepQueued = false

  const now = (): number => globalThis.performance?.now() ?? 0
  let firstReceivedAt = 0

  const drain = () => {
    const messages = inbox
    inbox = []
    const onBatch = options.onBatch
    if (onBatch) {
      let rows = 0
      for (const message of messages) {
        rows += message.kind === "patch" ? message.patch.rows.length : message.kind === "snapshot" ? message.snapshot.rows.length : 0
      }
      applyMessages(messages)
      onBatch({ messages: messages.length, rows, waitedMs: now() - firstReceivedAt })
      return
    }
    applyMessages(messages)
  }

  const applyMessages = (messages: CoreMessage[]) => {
    for (const message of messages) {
      if (disposed) return
      if (message.kind === "snapshot") {
        store.replaceAll(message.snapshot)
        resyncing = false
      } else if (message.kind === "patch") {
        if (resyncing) continue
        const result = store.applyPatch(message.patch)
        if (!result.ok) {
          resyncing = true
          endpoint.post({ kind: "resync" })
        }
      }
    }
  }

  const stopListening = endpoint.subscribe((message) => {
    if (disposed) return
    if (message.kind !== "patch" && message.kind !== "snapshot") return
    inbox.push(message)
    if (inbox.length === 1) {
      if (options.onBatch) firstReceivedAt = now()
      scheduler.frame(drain)
    }
  })

  const queueSweep = () => {
    if (sweepQueued) return
    sweepQueued = true
    scheduler.idle(() => {
      sweepQueued = false
      store.sweep()
    })
  }

  const open = (sub: SubId, query: QueryDescriptor): SubscriptionHandle => {
    store.ensureSub(sub)
    let active = true
    const handle: SubscriptionHandle = {
      sub,
      query,
      list: store.list(sub),
      resource: store.resource(sub),
      ensure: (range) => {
        if (active && !disposed) endpoint.post({ kind: "ensure", sub, range })
      },
      unsubscribe: () => {
        if (!active) return
        active = false
        handles.delete(sub)
        if (disposed) return
        endpoint.post({ kind: "unsubscribe", sub })
        store.dropSub(sub)
        queueSweep()
      },
    }
    handles.set(sub, handle)
    return handle
  }

  return {
    store,
    subscribe: (query) => {
      const sub = nextSub++
      const handle = open(sub, query)
      endpoint.post({ kind: "subscribe", sub, query })
      return handle
    },
    intent: (intent, optimistic) => {
      const tx = newTxId()
      const settled = store.waitFor(tx)
      if (optimistic && optimistic.length > 0) {
        scheduler.sync(() => store.addOverlay(tx, optimistic))
      }
      endpoint.post({ kind: "intent", tx, intent })
      return Object.assign(settled, { tx })
    },
    resyncing: () => resyncing,
    exportSubscriptions: (list, exportOptions) => ({
      format: 1,
      queries: list.map((handle) => ({ sub: handle.sub, query: handle.query })),
      store: store.exportSnapshot(
        list.map((handle) => handle.sub),
        exportOptions,
      ),
    }),
    restore: (data) => {
      if (data.format !== 1) return []
      const mapping = new Map<SubId, SubId>()
      const restored = data.queries.map(({ sub, query }) => {
        const live = nextSub++
        mapping.set(sub, live)
        return open(live, query)
      })
      store.importSnapshot(data.store, (sub) => mapping.get(sub))
      for (const handle of restored) endpoint.post({ kind: "subscribe", sub: handle.sub, query: handle.query })
      return restored
    },
    dispose: () => {
      if (disposed) return
      disposed = true
      stopListening()
      for (const handle of handles.values()) handle.unsubscribe()
      inbox = []
      store.dispose()
    },
  }
}
