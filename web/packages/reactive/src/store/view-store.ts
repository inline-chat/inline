/**
 * The view store: the UI thread's read-only projection of what the core
 * published, plus the overlay of the UI's own predictions. See
 * web/docs/reactivity.md ("View store") and web/docs/architecture.md
 * ("Local echo"). README.md in this package states the invariants.
 */

import {
  rowKey,
  type IntentResult,
  type Patch,
  type ResourceValue,
  type Revision,
  type Row,
  type RowKey,
  type RowKind,
  type RowOf,
  type Snapshot,
  type SubId,
  type TxId,
} from "@inline/core-protocol"
import {
  batch,
  computed,
  isTracking,
  observedSignal,
  signal,
  type ObservedSignal,
  type ReadSignal,
  type Signal,
} from "../signals"
import { plainEqual, sameKeys } from "./equal"

/** A row the UI predicts for one of its own intents. */
export type OptimisticRow = {
  row: Row
  /**
   * Subscriptions whose list shows this row at its end until the core's
   * patch carries the row (or settles the intent). A sent message names the
   * chat window it was sent from, when that window is at the latest message.
   */
  appendTo?: readonly SubId[]
}

export type ApplyResult =
  | { ok: true }
  /** `patch.base` did not match; nothing was applied. Ask the core for a resync. */
  | { ok: false; reason: "gap"; revision: Revision; base: Revision }

/** Subscriptions exported as plain data; the boot snapshot is built on it. */
export type StoreSnapshotData = {
  format: 1
  /** The store's revision when exported. Informational: an import does not restore it. */
  revision: Revision
  lists: { sub: SubId; keys: RowKey[]; resource?: ResourceValue }[]
  rows: Row[]
}

export type ExportOptions = {
  /** Keys of rows a row needs that are not in a list (the chat and user of a dialog). Followed transitively. */
  expand?: (row: Row) => readonly RowKey[]
  /**
   * The part of each list to export (the first screen of a long list), chosen
   * before rows are collected, so the cost of an export follows what it keeps.
   */
  select?: (sub: SubId, keys: readonly RowKey[]) => readonly RowKey[]
}

export type ViewStoreOptions = {
  /** Sweep unobserved row signals once this many exist. Default 1024. */
  sweepThreshold?: number
}

type OverlayEntry = {
  tx: TxId
  row: Row
  appendTo: readonly SubId[]
}

type Waiter = { resolve: (result: IntentResult) => void; reject: (error: unknown) => void }

type SubState = {
  keys: Signal<readonly RowKey[]>
  appends: Signal<readonly RowKey[]>
  list: ReadSignal<readonly RowKey[]>
  resource: Signal<ResourceValue | undefined>
}

const EMPTY_KEYS: readonly RowKey[] = Object.freeze([])
const EMPTY_SUB_SET: ReadonlySet<SubId> = new Set()

/** Read a list of one subscription: the core's keys, then overlay rows appended to it. */
const effectiveList = (state: Pick<SubState, "keys" | "appends">) => (): readonly RowKey[] => {
  const keys = state.keys.get()
  const appends = state.appends.get()
  if (appends.length === 0) return keys
  const present = new Set(keys)
  const extra = appends.filter((key) => !present.has(key))
  return extra.length === 0 ? keys : [...keys, ...extra]
}

export class ViewStore {
  private readonly base = new Map<RowKey, Row>()
  /**
   * Rows imported with `importSnapshot` (the boot snapshot) that the core has
   * not published yet. Read under the core's rows; dropped row by row as the
   * core publishes them and all at once when every provisional list is confirmed.
   */
  private readonly provisionalRows = new Map<RowKey, Row>()
  private readonly provisionalSubsSignal = signal<ReadonlySet<SubId>>(EMPTY_SUB_SET)
  private readonly overlay = new Map<RowKey, OverlayEntry>()
  private readonly overlayByTx = new Map<TxId, Set<RowKey>>()
  private readonly cells = new Map<RowKey, ObservedSignal<Row | undefined>>()
  private readonly handles = new Map<RowKey, ReadSignal<Row | undefined>>()
  private readonly subs = new Map<SubId, SubState>()
  private readonly waiters = new Map<TxId, Waiter[]>()
  private readonly revisionSignal = signal<Revision>(0)
  private readonly sweepFloor: number
  private sweepAt: number

  // Bookkeeping of one mutation, flushed at its end.
  private touchedRows = new Set<RowKey>()
  private touchedAppends = new Set<SubId>()

  constructor(options?: ViewStoreOptions) {
    this.sweepFloor = options?.sweepThreshold ?? 1024
    this.sweepAt = this.sweepFloor
  }

  // -------------------------------------------------------------------------
  // Reads

  /** The revision of the core's state this store holds. Tracked. */
  get revision(): ReadSignal<Revision> {
    return this.revisionSignal
  }

  /**
   * A row as views see it: the overlay's prediction if there is one, else the
   * core's row. A signal for the row exists only while something observes it.
   */
  row<K extends RowKind>(kind: K, id: string): ReadSignal<RowOf<K> | undefined> {
    return this.rowByKey(rowKey(kind, id)) as ReadSignal<RowOf<K> | undefined>
  }

  rowByKey(key: RowKey): ReadSignal<Row | undefined> {
    let handle = this.handles.get(key)
    if (handle === undefined) {
      handle = {
        get: () => (isTracking() ? this.cellFor(key).get() : this.effective(key)),
        peek: () => this.effective(key),
      }
      this.handles.set(key, handle)
    }
    return handle
  }

  /** Read a row now without tracking. */
  peekRow(key: RowKey): Row | undefined {
    return this.effective(key)
  }

  /** The ordered row keys of a subscription, with appended overlay rows last. */
  list(sub: SubId): ReadSignal<readonly RowKey[]> {
    return this.subState(sub).list
  }

  /** The resource of a subscription (window state, core phase). */
  resource(sub: SubId): ReadSignal<ResourceValue | undefined> {
    return this.subState(sub).resource
  }

  /**
   * Subscriptions whose list and resource are still provisional (imported,
   * not yet sent by the core). Tracked. Empty once the core confirmed them all.
   */
  get provisionalSubs(): ReadSignal<ReadonlySet<SubId>> {
    return this.provisionalSubsSignal
  }

  hasSub(sub: SubId): boolean {
    return this.subs.has(sub)
  }

  /**
   * Whether this row, as views see it, is provisional: imported from a boot
   * snapshot, with no row from the core or the overlay yet. Untracked; track
   * `provisionalSubs` to hear when provisional rows go.
   */
  isProvisional(key: RowKey): boolean {
    return !this.overlay.has(key) && !this.base.has(key) && this.provisionalRows.has(key)
  }

  /** Whether the overlay holds a prediction for this row. */
  hasOverlay(key: RowKey): boolean {
    return this.overlay.has(key)
  }

  /** Counts for tests and the developer overlay. */
  stats(): { rows: number; overlay: number; signals: number; subs: number; waiting: number; provisional: number } {
    return {
      rows: this.base.size,
      provisional: this.provisionalRows.size,
      overlay: this.overlay.size,
      signals: this.cells.size,
      subs: this.subs.size,
      waiting: this.waiters.size,
    }
  }

  // -------------------------------------------------------------------------
  // Subscriptions

  /** Create the list and resource of a subscription. Patches for unknown subs are ignored. */
  ensureSub(sub: SubId): void {
    this.subState(sub)
  }

  private subState(sub: SubId): SubState {
    let state = this.subs.get(sub)
    if (state === undefined) {
      const keys = signal<readonly RowKey[]>(EMPTY_KEYS)
      const appends = signal<readonly RowKey[]>(EMPTY_KEYS)
      state = {
        keys,
        appends,
        list: computed(effectiveList({ keys, appends }), { equals: sameKeys }),
        resource: signal<ResourceValue | undefined>(undefined, { equals: plainEqual }),
      }
      this.subs.set(sub, state)
      this.recomputeAppends(sub, state)
    }
    return state
  }

  /** Forget a subscription's list and resource. Its rows stay until the core removes them. */
  dropSub(sub: SubId): void {
    this.subs.delete(sub)
    if (this.provisionalSubsSignal.peek().has(sub)) {
      batch(() => {
        this.confirmProvisional(sub)
        this.flushTouched()
      })
    }
  }

  // -------------------------------------------------------------------------
  // Writes from the core

  /**
   * Apply a patch from the core. If `patch.base` is not this store's revision
   * nothing is applied and a gap is reported: the caller asks for a resync.
   * Otherwise every row, list, resource and overlay change is installed in one
   * batch, so no observer sees half a patch.
   */
  applyPatch(patch: Patch): ApplyResult {
    const current = this.revisionSignal.peek()
    if (patch.base !== current) {
      return { ok: false, reason: "gap", revision: current, base: patch.base }
    }
    const results = patch.settled
    batch(() => {
      for (const change of patch.rows) {
        if (change.op === "upsert") {
          this.installRow(change.row)
        } else {
          const key = rowKey(change.kind, change.id)
          this.base.delete(key)
          this.provisionalRows.delete(key)
          this.dropOverlayKey(key)
          this.touchedRows.add(key)
        }
      }
      for (const change of patch.lists) {
        const state = this.subs.get(change.sub)
        if (state === undefined) continue
        // The core's first list for a sub is a `replace`. A splice on a list
        // that is still provisional applies to what the core believes the
        // UI holds, which is nothing.
        const wasProvisional = this.confirmProvisional(change.sub)
        if (change.op === "replace") {
          state.keys.set(sameKeys(state.keys.peek(), change.keys) ? state.keys.peek() : change.keys.slice())
        } else {
          const next = wasProvisional ? [] : state.keys.peek().slice()
          next.splice(change.index, change.remove, ...change.insert)
          if (!sameKeys(next, state.keys.peek())) state.keys.set(next)
        }
      }
      for (const change of patch.resources) {
        this.subs.get(change.sub)?.resource.set(change.value)
      }
      for (const result of results) {
        this.dropOverlayTx(result.tx)
      }
      this.revisionSignal.set(patch.revision)
      this.flushTouched()
    })
    this.deliver(results)
    this.maybeSweep()
    return { ok: true }
  }

  /**
   * Replace the core's state with a full snapshot (after a gap). The overlay
   * is kept, except for predictions whose row the snapshot carries.
   * Subscriptions the snapshot does not mention keep their lists, and
   * provisional rows stay until their lists are confirmed: a context's first
   * snapshot usually arrives before the core has computed anything.
   */
  replaceAll(snapshot: Snapshot): void {
    // TODO(contract): `Snapshot` has no `settled`; results in patches dropped
    // during a gap are lost and their waiters hang. Read it if the core adds it.
    const settled = (snapshot as Snapshot & { settled?: IntentResult[] }).settled ?? []
    batch(() => {
      const previous = new Map(this.base)
      this.base.clear()
      for (const row of snapshot.rows) {
        const key = rowKey(row.kind, row.id)
        this.installRow(row, previous.get(key) ?? this.provisionalRows.get(key))
      }
      for (const key of previous.keys()) {
        if (!this.base.has(key)) this.touchedRows.add(key)
      }
      for (const entry of snapshot.lists) {
        const state = this.subs.get(entry.sub)
        if (state === undefined) continue
        this.confirmProvisional(entry.sub)
        if (!sameKeys(state.keys.peek(), entry.keys)) state.keys.set(entry.keys.slice())
      }
      for (const change of snapshot.resources) {
        this.subs.get(change.sub)?.resource.set(change.value)
      }
      for (const result of settled) this.dropOverlayTx(result.tx)
      this.revisionSignal.set(snapshot.revision)
      this.flushTouched()
    })
    this.deliver(settled)
    this.maybeSweep()
  }

  // -------------------------------------------------------------------------
  // The overlay: the UI's own predictions

  /**
   * Install the optimistic rows of an intent. Reads see them immediately, in
   * the same task. A prediction for a row that already has one replaces it.
   */
  addOverlay(tx: TxId, rows: readonly OptimisticRow[]): void {
    if (rows.length === 0) return
    batch(() => {
      for (const { row, appendTo } of rows) {
        const key = rowKey(row.kind, row.id)
        this.dropOverlayKey(key)
        this.overlay.set(key, { tx, row, appendTo: appendTo ?? EMPTY_SUBS })
        let keys = this.overlayByTx.get(tx)
        if (keys === undefined) {
          keys = new Set()
          this.overlayByTx.set(tx, keys)
        }
        keys.add(key)
        this.touchedRows.add(key)
        for (const sub of appendTo ?? EMPTY_SUBS) this.touchedAppends.add(sub)
      }
      this.flushTouched()
    })
  }

  /** Remove every prediction of an intent (the intent was rejected or abandoned). */
  dropOverlay(tx: TxId): void {
    if (!this.overlayByTx.has(tx)) return
    batch(() => {
      this.dropOverlayTx(tx)
      this.flushTouched()
    })
  }

  // -------------------------------------------------------------------------
  // Settled results

  /**
   * Resolves with the first result the core reports for `tx`. Rejects with
   * `StoreDisposedError` if the store is disposed first; that rejection is
   * marked handled, so a caller that does not await is not reported.
   */
  waitFor(tx: TxId): Promise<IntentResult> {
    const promise = new Promise<IntentResult>((resolve, reject) => {
      const waiter = { resolve, reject }
      const list = this.waiters.get(tx)
      if (list) list.push(waiter)
      else this.waiters.set(tx, [waiter])
    })
    promise.catch(() => {})
    return promise
  }

  /** Deliver results that arrived outside a patch (or a local refusal). */
  settle(results: readonly IntentResult[]): void {
    batch(() => {
      for (const result of results) this.dropOverlayTx(result.tx)
      this.flushTouched()
    })
    this.deliver(results)
  }

  // -------------------------------------------------------------------------
  // Export and import

  /** Export the chosen subscriptions and the rows they need as plain data. Overlay rows are not exported. */
  exportSnapshot(subs: readonly SubId[], options?: ExportOptions): StoreSnapshotData {
    const lists: StoreSnapshotData["lists"] = []
    const rows: Row[] = []
    const seen = new Set<RowKey>()
    const pending: RowKey[] = []
    const visit = (key: RowKey) => {
      if (seen.has(key)) return
      seen.add(key)
      pending.push(key)
    }
    for (const sub of subs) {
      const state = this.subs.get(sub)
      if (state === undefined) continue
      const all = state.keys.peek()
      const keys = options?.select ? options.select(sub, all) : all
      const resource = state.resource.peek()
      lists.push({ sub, keys: keys.slice(), ...(resource ? { resource } : {}) })
      for (const key of keys) visit(key)
    }
    while (pending.length > 0) {
      const key = pending.shift()!
      const row = this.base.get(key) ?? this.provisionalRows.get(key)
      if (row === undefined) continue
      rows.push(row)
      if (options?.expand) for (const related of options.expand(row)) visit(related)
    }
    return { format: 1, revision: this.revisionSignal.peek(), lists, rows }
  }

  /**
   * Install exported data as provisional state, before the core has
   * published anything (the boot snapshot). The revision is not changed.
   * `mapSub` maps an exported sub to the live one; lists it maps to
   * `undefined` are skipped.
   *
   * Provisional rows are read under the core's rows and never replace them.
   * A provisional list stays until the core sends that sub's list (a patch
   * or a snapshot that names it); a core row equal to a provisional one takes
   * its object, so confirmation renders nothing. Once no provisional list is
   * left, the provisional rows the core did not publish are dropped.
   */
  importSnapshot(data: StoreSnapshotData, mapSub: (sub: SubId) => SubId | undefined = (sub) => sub): void {
    if (data.format !== 1) return
    batch(() => {
      const subs = new Set(this.provisionalSubsSignal.peek())
      for (const entry of data.lists) {
        const sub = mapSub(entry.sub)
        if (sub === undefined) continue
        const state = this.subState(sub)
        state.keys.set(entry.keys.slice())
        if (entry.resource) state.resource.set(entry.resource)
        subs.add(sub)
      }
      if (subs.size > 0) {
        for (const row of data.rows) {
          const key = rowKey(row.kind, row.id)
          if (this.base.has(key)) continue
          this.provisionalRows.set(key, row)
          this.touchedRows.add(key)
        }
      }
      this.provisionalSubsSignal.set(subs)
      this.flushTouched()
    })
  }

  /**
   * Give up on provisional state: provisional lists become empty, their
   * resources unset, provisional rows go. For a provisional state the core
   * will never confirm.
   */
  dropProvisional(): void {
    const subs = this.provisionalSubsSignal.peek()
    if (subs.size === 0 && this.provisionalRows.size === 0) return
    batch(() => {
      for (const sub of subs) {
        const state = this.subs.get(sub)
        if (state === undefined) continue
        state.keys.set(EMPTY_KEYS)
        state.resource.set(undefined)
      }
      this.provisionalSubsSignal.set(EMPTY_SUB_SET)
      this.clearProvisionalRows()
      this.flushTouched()
    })
  }

  // -------------------------------------------------------------------------
  // Memory

  /** Release row signals nothing observes. Runs on its own as signals accumulate. */
  sweep(): void {
    for (const [key, cell] of this.cells) {
      if (!cell.observed()) {
        this.cells.delete(key)
        this.handles.delete(key)
      }
    }
    for (const key of this.handles.keys()) {
      if (!this.cells.has(key)) this.handles.delete(key)
    }
    this.sweepAt = Math.max(this.sweepFloor, this.cells.size * 2)
  }

  /** Reject every waiter with `StoreDisposedError` and drop all state. */
  dispose(): void {
    const waiters = [...this.waiters.values()]
    this.waiters.clear()
    for (const list of waiters) for (const waiter of list) waiter.reject(new StoreDisposedError())
    this.cells.clear()
    this.handles.clear()
    this.subs.clear()
    this.base.clear()
    this.provisionalRows.clear()
    this.provisionalSubsSignal.set(EMPTY_SUB_SET)
    this.overlay.clear()
    this.overlayByTx.clear()
  }

  // -------------------------------------------------------------------------
  // Internals

  private effective(key: RowKey): Row | undefined {
    const entry = this.overlay.get(key)
    if (entry !== undefined) return entry.row
    return this.base.get(key) ?? this.provisionalRows.get(key)
  }

  private cellFor(key: RowKey): ObservedSignal<Row | undefined> {
    let cell = this.cells.get(key)
    if (cell === undefined) {
      cell = observedSignal(this.effective(key))
      this.cells.set(key, cell)
    }
    return cell
  }

  /**
   * Put a row from the core into the revisioned state, keeping the identity
   * of an equal row already there, or of an equal prediction it confirms.
   */
  private installRow(row: Row, previous?: Row): void {
    const key = rowKey(row.kind, row.id)
    previous ??= this.base.get(key) ?? this.provisionalRows.get(key)
    this.provisionalRows.delete(key)
    const predicted = this.overlay.get(key)?.row
    let next = row
    if (previous !== undefined && plainEqual(previous, row)) next = previous
    else if (predicted !== undefined && plainEqual(predicted, row)) next = predicted
    this.base.set(key, next)
    this.dropOverlayKey(key)
    this.touchedRows.add(key)
  }

  /**
   * The core sent this sub's list: it is no longer provisional. When it was
   * the last, provisional rows the core did not publish go. Returns whether
   * it was provisional. Call inside a batch; flush after.
   */
  private confirmProvisional(sub: SubId): boolean {
    const subs = this.provisionalSubsSignal.peek()
    if (!subs.has(sub)) return false
    const next = new Set(subs)
    next.delete(sub)
    this.provisionalSubsSignal.set(next.size === 0 ? EMPTY_SUB_SET : next)
    if (next.size === 0) this.clearProvisionalRows()
    return true
  }

  private clearProvisionalRows(): void {
    for (const key of this.provisionalRows.keys()) this.touchedRows.add(key)
    this.provisionalRows.clear()
  }

  private dropOverlayKey(key: RowKey): void {
    const entry = this.overlay.get(key)
    if (entry === undefined) return
    this.overlay.delete(key)
    const keys = this.overlayByTx.get(entry.tx)
    if (keys !== undefined) {
      keys.delete(key)
      if (keys.size === 0) this.overlayByTx.delete(entry.tx)
    }
    this.touchedRows.add(key)
    for (const sub of entry.appendTo) this.touchedAppends.add(sub)
  }

  private dropOverlayTx(tx: TxId): void {
    const keys = this.overlayByTx.get(tx)
    if (keys === undefined) return
    for (const key of keys) this.dropOverlayKey(key)
  }

  private recomputeAppends(sub: SubId, state: SubState): void {
    const appends: RowKey[] = []
    for (const [key, entry] of this.overlay) {
      if (entry.appendTo.includes(sub)) appends.push(key)
    }
    const current = state.appends.peek()
    if (!sameKeys(current, appends)) state.appends.set(appends.length === 0 ? EMPTY_KEYS : appends)
  }

  /** Push the effective value of every touched row and list to its signal. Call inside the batch. */
  private flushTouched(): void {
    for (const key of this.touchedRows) {
      this.cells.get(key)?.set(this.effective(key))
    }
    for (const sub of this.touchedAppends) {
      const state = this.subs.get(sub)
      if (state !== undefined) this.recomputeAppends(sub, state)
    }
    this.touchedRows = new Set()
    this.touchedAppends = new Set()
  }

  private deliver(results: readonly IntentResult[]): void {
    for (const result of results) {
      const list = this.waiters.get(result.tx)
      if (list === undefined) continue
      this.waiters.delete(result.tx)
      for (const waiter of list) waiter.resolve(result)
    }
  }

  private maybeSweep(): void {
    if (this.cells.size >= this.sweepAt) this.sweep()
  }
}

const EMPTY_SUBS: readonly SubId[] = Object.freeze([])

export class StoreDisposedError extends Error {
  constructor() {
    super("The view store was disposed before the intent settled")
    this.name = "StoreDisposedError"
  }
}
