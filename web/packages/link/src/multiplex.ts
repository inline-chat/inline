/**
 * One core endpoint shared by several UI contexts.
 *
 * The core host implements a single `CoreEndpoint`. Each tab is its own
 * context with its own subscription IDs, revisions and resync, so link puts
 * this multiplexer in front of the core:
 *
 * - Subscription IDs are namespaced: each (context, sub) pair gets a fresh
 *   core-side sub. Two contexts can both use sub 1.
 * - Revisions are per context and rewritten here. A context receives a patch
 *   only when it carries something for it, numbered contiguously from 0.
 * - List and resource changes go to the context that owns the sub; intent
 *   results go to the context that posted the intent.
 * - Rows go to every open context. The core's patch does not say which sub a
 *   row belongs to (a sidebar's chat and user rows are not in its list keys),
 *   so routing them is over-inclusive by design. The multiplexer keeps a mirror
 *   of the rows the core has published, and a context that opens late gets the
 *   mirror first, so it never misses a row the core sent before it existed.
 * - `resync` from a context asks the core once (coalesced) and hands the
 *   snapshot to every context waiting for one, filtered to its subs and to
 *   the intent results of its own transactions.
 * - A revision gap in the core's own stream resyncs every context.
 * - Visibility is aggregated: the core sees "visible" while any context is.
 */

import type {
  Command,
  CoreEndpoint,
  CoreMessage,
  CoreMessageListener,
  IntentResult,
  ListChange,
  Patch,
  ResourceChange,
  Revision,
  Row,
  RowChange,
  RowKey,
  Snapshot,
  SubId,
  TxId,
} from "@inline/core-protocol"
import { rowKey } from "@inline/core-protocol"
import { Log } from "@inline/log"

/** Opens one context's endpoint on a core. */
export interface CoreContexts {
  open(contextId: string): CoreEndpoint
  /** Closes every context and the core. */
  close(): void | Promise<void>
}

type Context = {
  id: string
  revision: Revision
  /** Local sub to core sub. */
  subs: Map<SubId, SubId>
  listeners: Set<CoreMessageListener>
  visible: boolean | undefined
  closed: boolean
}

type SubOwner = { context: Context; local: SubId }

export type MultiplexOptions = {
  log?: Log
}

const terminal = (result: IntentResult) => result.status === "confirmed" || result.status === "rejected"

export const multiplexEndpoint = (core: CoreEndpoint, options: MultiplexOptions = {}): CoreContexts => {
  const log = (options.log ?? new Log("Link")).withScope("Multiplex")
  const contexts = new Map<string, Context>()
  const owners = new Map<SubId, SubOwner>()
  const txOwners = new Map<TxId, Set<Context>>()
  const mirror = new Map<RowKey, Row>()
  const snapshotWaiters = new Set<Context>()
  const helloWaiters = new Set<Context>()
  let nextCoreSub = 1
  let coreRevision: Revision | undefined
  let resyncOutstanding = false
  let gapResync = false
  let coreHello: CoreMessage | undefined
  let helloForwarded = false
  let aggregateVisible: boolean | undefined
  let closed = false

  const emit = (context: Context, message: CoreMessage) => {
    if (context.closed) return
    for (const listener of Array.from(context.listeners)) {
      try {
        listener(message)
      } catch (error) {
        log.error("listener threw", { error })
      }
    }
  }

  const emitPatch = (context: Context, body: Omit<Patch, "base" | "revision">) => {
    if (
      body.rows.length === 0 &&
      body.lists.length === 0 &&
      body.resources.length === 0 &&
      body.settled.length === 0
    ) return
    const base = context.revision
    context.revision += 1
    emit(context, { kind: "patch", patch: { base, revision: context.revision, ...body } })
  }

  const requestResync = (context: Context | "all") => {
    if (context === "all") {
      gapResync = true
      for (const c of contexts.values()) snapshotWaiters.add(c)
    } else {
      snapshotWaiters.add(context)
    }
    if (resyncOutstanding) return
    resyncOutstanding = true
    core.post({ kind: "resync" })
  }

  const applyRows = (rows: RowChange[]) => {
    for (const change of rows) {
      if (change.op === "upsert") mirror.set(rowKey(change.row.kind, change.row.id), change.row)
      else mirror.delete(rowKey(change.kind, change.id))
    }
  }

  const routeLists = (lists: ListChange[], resources: ResourceChange[]) => {
    const byContext = new Map<Context, { lists: ListChange[]; resources: ResourceChange[] }>()
    const slot = (context: Context) => {
      let entry = byContext.get(context)
      if (!entry) {
        entry = { lists: [], resources: [] }
        byContext.set(context, entry)
      }
      return entry
    }
    for (const change of lists) {
      const owner = owners.get(change.sub)
      if (!owner) continue
      slot(owner.context).lists.push({ ...change, sub: owner.local })
    }
    for (const change of resources) {
      const owner = owners.get(change.sub)
      if (!owner) continue
      slot(owner.context).resources.push({ ...change, sub: owner.local })
    }
    return byContext
  }

  const onPatch = (patch: Patch) => {
    if (coreRevision !== undefined && patch.base !== coreRevision) {
      // Something was lost between the core and here. Every context gets a
      // snapshot; meanwhile the patch is still routed, since each context's
      // own stream stays contiguous and the snapshot replaces what it built.
      log.warn("core revision gap", { expected: coreRevision, base: patch.base })
      if (!gapResync) requestResync("all")
    }
    coreRevision = patch.revision
    applyRows(patch.rows)
    const routed = routeLists(patch.lists, patch.resources)
    const settledBy = new Map<Context, IntentResult[]>()
    for (const result of patch.settled) {
      const set = txOwners.get(result.tx)
      if (!set) continue
      for (const context of set) {
        const list = settledBy.get(context) ?? []
        list.push(result)
        settledBy.set(context, list)
      }
      if (terminal(result)) txOwners.delete(result.tx)
    }
    for (const context of contexts.values()) {
      const own = routed.get(context)
      emitPatch(context, {
        rows: patch.rows,
        lists: own?.lists ?? [],
        resources: own?.resources ?? [],
        settled: settledBy.get(context) ?? [],
      })
    }
  }

  const contextSnapshot = (context: Context, snapshot: Snapshot): Snapshot => {
    const lists: Snapshot["lists"] = []
    for (const list of snapshot.lists) {
      const owner = owners.get(list.sub)
      if (owner?.context === context) lists.push({ sub: owner.local, keys: list.keys })
    }
    const resources: ResourceChange[] = []
    for (const resource of snapshot.resources) {
      const owner = owners.get(resource.sub)
      if (owner?.context === context) resources.push({ sub: owner.local, value: resource.value })
    }
    const settled = (snapshot.settled ?? []).filter((result) => txOwners.get(result.tx)?.has(context))
    context.revision += 1
    return { revision: context.revision, rows: [...mirror.values()], lists, resources, settled }
  }

  const onSnapshot = (snapshot: Snapshot) => {
    resyncOutstanding = false
    gapResync = false
    coreRevision = snapshot.revision
    mirror.clear()
    for (const row of snapshot.rows) mirror.set(rowKey(row.kind, row.id), row)
    const waiting = [...snapshotWaiters]
    snapshotWaiters.clear()
    for (const context of waiting) {
      if (context.closed) continue
      emit(context, { kind: "snapshot", snapshot: contextSnapshot(context, snapshot) })
    }
  }

  const onHello = (message: CoreMessage) => {
    coreHello = message
    const waiting = helloWaiters.size > 0 ? [...helloWaiters] : [...contexts.values()]
    helloWaiters.clear()
    for (const context of waiting) emit(context, message)
  }

  const unsubscribeCore = core.subscribe((message) => {
    if (closed) return
    switch (message.kind) {
      case "patch":
        onPatch(message.patch)
        return
      case "snapshot":
        onSnapshot(message.snapshot)
        return
      case "hello":
        onHello(message)
        return
    }
  })

  const updateVisibility = () => {
    let any: boolean | undefined
    for (const context of contexts.values()) {
      if (context.visible === undefined) continue
      any = (any ?? false) || context.visible
    }
    if (any === undefined || any === aggregateVisible) return
    aggregateVisible = any
    core.post({ kind: "signal", signal: { kind: "visibility", visible: any } })
  }

  const handle = (context: Context, command: Command) => {
    switch (command.kind) {
      case "hello":
        if (coreHello) emit(context, coreHello)
        else {
          helloWaiters.add(context)
          if (!helloForwarded) {
            helloForwarded = true
            core.post(command)
          }
        }
        return
      case "subscribe": {
        const previous = context.subs.get(command.sub)
        if (previous !== undefined) {
          owners.delete(previous)
          core.post({ kind: "unsubscribe", sub: previous })
        }
        const coreSub = nextCoreSub++
        context.subs.set(command.sub, coreSub)
        owners.set(coreSub, { context, local: command.sub })
        core.post({ ...command, sub: coreSub })
        return
      }
      case "unsubscribe": {
        const coreSub = context.subs.get(command.sub)
        if (coreSub === undefined) return
        context.subs.delete(command.sub)
        owners.delete(coreSub)
        core.post({ kind: "unsubscribe", sub: coreSub })
        return
      }
      case "ensure":
      case "trimWindow": {
        const coreSub = context.subs.get(command.sub)
        if (coreSub === undefined) return
        core.post({ ...command, sub: coreSub })
        return
      }
      case "intent": {
        let set = txOwners.get(command.tx)
        if (!set) {
          set = new Set()
          txOwners.set(command.tx, set)
        }
        set.add(context)
        core.post(command)
        return
      }
      case "resync":
        requestResync(context)
        return
      case "signal":
        if (command.signal.kind === "visibility") {
          context.visible = command.signal.visible
          updateVisibility()
          return
        }
        core.post(command)
        return
      case "session":
        core.post(command)
        return
      default: {
        // A new command kind is a type error here until it is routed. At run
        // time, one without a sub is safe to forward untouched; one with a
        // sub is not, since the sub ID would name another context's sub.
        const unknown: never = command
        const value = unknown as Record<string, unknown>
        if ("sub" in value) {
          log.warn("dropped an unknown command that names a sub", { kind: value.kind })
          return
        }
        core.post(unknown)
        return
      }
    }
  }

  const closeContext = (context: Context) => {
    if (context.closed) return
    context.closed = true
    context.listeners.clear()
    contexts.delete(context.id)
    snapshotWaiters.delete(context)
    helloWaiters.delete(context)
    for (const [tx, set] of txOwners) {
      set.delete(context)
      if (set.size === 0) txOwners.delete(tx)
    }
    if (!closed) {
      for (const coreSub of context.subs.values()) {
        owners.delete(coreSub)
        core.post({ kind: "unsubscribe", sub: coreSub })
      }
      updateVisibility()
    }
    context.subs.clear()
  }

  return {
    open(contextId) {
      if (closed) throw new Error("core is closed")
      const existing = contexts.get(contextId)
      if (existing) closeContext(existing)
      const context: Context = {
        id: contextId,
        revision: 0,
        subs: new Map(),
        listeners: new Set(),
        visible: undefined,
        closed: false,
      }
      contexts.set(contextId, context)
      let introduced = false
      const introduce = () => {
        // A late context first gets every row the core already published.
        if (introduced) return
        introduced = true
        if (mirror.size > 0) {
          emitPatch(context, {
            rows: [...mirror.values()].map((row) => ({ op: "upsert", row })),
            lists: [],
            resources: [],
            settled: [],
          })
        }
      }
      return {
        post(command) {
          if (context.closed || closed) return
          introduce()
          handle(context, command)
        },
        subscribe(listener) {
          context.listeners.add(listener)
          return () => {
            context.listeners.delete(listener)
          }
        },
        close() {
          closeContext(context)
        },
      }
    },
    close() {
      if (closed) return
      for (const context of Array.from(contexts.values())) closeContext(context)
      closed = true
      unsubscribeCore()
      return core.close()
    },
  }
}

/** Whether a value is a `CoreContexts` rather than a single `CoreEndpoint`. */
export const isCoreContexts = (value: CoreEndpoint | CoreContexts): value is CoreContexts =>
  typeof (value as Partial<CoreContexts>).open === "function" &&
  typeof (value as Partial<CoreEndpoint>).post !== "function"
