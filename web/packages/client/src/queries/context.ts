/**
 * The materializer for one UI context: its subscriptions, the rows it holds,
 * and its revision. `publish` recomputes only the subscriptions a set of
 * committed changes can affect, diffs them against what the context already
 * has, and emits one patch (or one snapshot after `resync`) with a revision
 * exactly one above the last.
 */
import {
  rowKey,
  type CoreMessage,
  type IntentResult,
  type ListChange,
  type Patch,
  type QueryDescriptor,
  type ResourceChange,
  type ResourceValue,
  type Revision,
  type Row,
  type RowChange,
  type RowKey,
  type SubId,
  type TxId,
} from "@inline/core-protocol"
import type { DbResidentChange } from "../database"
import {
  affects,
  computeQuery,
  type QueryDeps,
  type QueryEnv,
  type SubscriptionFacts,
} from "./compute"
import { diffList, plainEqual } from "./diff"

type Subscription = {
  query: QueryDescriptor
  facts: SubscriptionFacts
  /** Not ready: its initial result is still loading; it is left out of patches. */
  ready: boolean
  /** Recompute at the next publish regardless of changes. */
  stale: boolean
  deps?: QueryDeps
  keys?: RowKey[]
  resource?: ResourceValue
  rowKeys: Set<RowKey>
}

type HeldRow = { row: Row; holders: Set<SubId> }

/** How many settled intent results a context keeps for snapshots. */
const SETTLED_LOG_LIMIT = 256

const isFinal = (result: IntentResult) => result.status !== "accepted"

export class QueryContext {
  private revision: Revision = 0
  private readonly subs = new Map<SubId, Subscription>()
  private readonly held = new Map<RowKey, HeldRow>()
  /** Rows whose last holder let go; removed at the next publish unless re-held. */
  private readonly orphaned = new Set<RowKey>()
  private pendingSettled: IntentResult[] = []
  private readonly intentLog = new Map<TxId, IntentResult>()
  /** A context's first message is a snapshot, so it never merges into stale state. */
  private snapshotRequested = true

  constructor(private readonly output: (message: CoreMessage) => void) {}

  get currentRevision(): Revision {
    return this.revision
  }

  /** True when the next publish would emit something even without changes. */
  get hasPendingOutput(): boolean {
    if (this.snapshotRequested || this.pendingSettled.length > 0 || this.orphaned.size > 0) {
      return true
    }
    for (const sub of this.subs.values()) {
      if (sub.ready && (sub.stale || !sub.deps)) return true
    }
    return false
  }

  query(sub: SubId): QueryDescriptor | undefined {
    return this.subs.get(sub)?.query
  }

  entries(): Array<[SubId, QueryDescriptor]> {
    return Array.from(this.subs, ([sub, state]) => [sub, state.query])
  }

  subscribe(sub: SubId, query: QueryDescriptor, facts: SubscriptionFacts, ready: boolean) {
    if (this.subs.has(sub)) this.unsubscribe(sub)
    this.subs.set(sub, {
      query,
      facts,
      ready,
      stale: true,
      rowKeys: new Set(),
    })
  }

  unsubscribe(sub: SubId): boolean {
    const state = this.subs.get(sub)
    if (!state) return false
    for (const key of state.rowKeys) this.release(sub, key)
    this.subs.delete(sub)
    return true
  }

  setReady(sub: SubId, ready: boolean, facts?: SubscriptionFacts) {
    const state = this.subs.get(sub)
    if (!state) return
    if (facts) state.facts = facts
    state.ready = ready
    state.stale = true
  }

  /** Mark subscriptions for recomputation at the next publish. */
  invalidate(where: (query: QueryDescriptor) => boolean) {
    for (const state of this.subs.values()) {
      if (where(state.query)) state.stale = true
    }
  }

  /** Mark one subscription for recomputation at the next publish. */
  invalidateSub(sub: SubId) {
    const state = this.subs.get(sub)
    if (state) state.stale = true
  }

  /** The facts a subscription was made ready with. */
  facts(sub: SubId): SubscriptionFacts | undefined {
    return this.subs.get(sub)?.facts
  }

  settle(result: IntentResult) {
    this.pendingSettled.push(result)
    this.intentLog.delete(result.tx)
    this.intentLog.set(result.tx, result)
    if (this.intentLog.size > SETTLED_LOG_LIMIT) {
      for (const [tx, logged] of this.intentLog) {
        if (this.intentLog.size <= SETTLED_LOG_LIMIT) break
        if (isFinal(logged)) this.intentLog.delete(tx)
      }
    }
  }

  requestSnapshot() {
    this.snapshotRequested = true
  }

  /**
   * Recompute what `changes` (or `everything`) can affect and emit the
   * result. Call only when the replica's memory equals its committed state.
   */
  publish(env: QueryEnv, changes: readonly DbResidentChange[], everything: boolean) {
    const snapshot = this.snapshotRequested
    const full = everything || snapshot
    const upserts = new Map<RowKey, Row>()
    const lists: ListChange[] = []
    const resources: ResourceChange[] = []

    for (const [sub, state] of this.subs) {
      if (!state.ready) continue
      const affected =
        full ||
        state.stale ||
        !state.deps ||
        changes.some((change) => affects(state.deps!, change))
      if (!affected) continue
      state.stale = false
      const result = computeQuery(state.query, env, state.facts)
      state.deps = result.deps

      const next = new Set<RowKey>()
      for (const row of result.rows) {
        const key = rowKey(row.kind, row.id)
        next.add(key)
        this.hold(sub, key, row, upserts)
      }
      for (const key of state.rowKeys) {
        if (!next.has(key)) this.release(sub, key)
      }
      state.rowKeys = next

      if (result.keys) {
        const change = diffList(sub, state.keys, result.keys)
        if (change) lists.push(change)
        state.keys = result.keys
      }
      if (result.resource && !plainEqual(state.resource, result.resource)) {
        resources.push({ sub, value: result.resource })
        state.resource = result.resource
      }
    }

    const removals: RowChange[] = []
    for (const key of this.orphaned) {
      const held = this.held.get(key)
      if (!held || held.holders.size > 0) continue
      this.held.delete(key)
      upserts.delete(key)
      removals.push({ op: "remove", kind: held.row.kind, id: held.row.id })
    }
    this.orphaned.clear()

    const settled = this.pendingSettled
    this.pendingSettled = []

    if (snapshot) {
      this.snapshotRequested = false
      this.revision += 1
      const readySubs = Array.from(this.subs).filter(([, state]) => state.ready)
      this.output({
        kind: "snapshot",
        snapshot: {
          revision: this.revision,
          rows: Array.from(this.held.values(), (held) => held.row),
          lists: readySubs.flatMap(([sub, state]) =>
            state.keys ? [{ sub, keys: state.keys.slice() }] : [],
          ),
          resources: readySubs.flatMap(([sub, state]) =>
            state.resource ? [{ sub, value: state.resource }] : [],
          ),
          settled: Array.from(this.intentLog.values()),
        },
      })
      return
    }

    const rows: RowChange[] = [
      ...removals,
      ...Array.from(upserts.values(), (row): RowChange => ({ op: "upsert", row })),
    ]
    if (
      rows.length === 0 &&
      lists.length === 0 &&
      resources.length === 0 &&
      settled.length === 0
    ) {
      return
    }
    const patch: Patch = {
      base: this.revision,
      revision: this.revision + 1,
      rows,
      lists,
      resources,
      settled,
    }
    this.revision = patch.revision
    this.output({ kind: "patch", patch })
  }

  private hold(sub: SubId, key: RowKey, row: Row, upserts: Map<RowKey, Row>) {
    const held = this.held.get(key)
    if (!held) {
      this.held.set(key, { row, holders: new Set([sub]) })
      upserts.set(key, row)
      return
    }
    held.holders.add(sub)
    if (!plainEqual(held.row, row)) {
      held.row = row
      upserts.set(key, row)
    }
  }

  private release(sub: SubId, key: RowKey) {
    const held = this.held.get(key)
    if (!held) return
    held.holders.delete(sub)
    if (held.holders.size === 0) this.orphaned.add(key)
  }
}
