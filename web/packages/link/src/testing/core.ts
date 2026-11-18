/**
 * A small fake of the account core, and a recording UI.
 *
 * `FakeCore` implements one `CoreEndpoint` the way the core host does: it
 * keeps subscriptions, emits patches with contiguous revisions, answers
 * `resync` with a snapshot and treats intents as idempotent by `tx` against a
 * `FakeDurable` store that outlives any one core (the stand-in for SQLite on
 * OPFS, which a new leader reopens).
 */

import {
  type Command,
  type CoreEndpoint,
  type CoreMessage,
  type CoreMessageListener,
  type CoreResource,
  type Intent,
  type IntentResult,
  type ListChange,
  type MessageRow,
  type Patch,
  type QueryDescriptor,
  type ResourceChange,
  type Row,
  type RowKey,
  type Snapshot,
  type SubId,
  type TxId,
  optimisticMessageRow,
  rowKey,
} from "@inline/core-protocol"

type ChatId = Extract<QueryDescriptor, { kind: "chatWindow" }>["chatId"]
type UserId = MessageRow["fromId"]

/** State that survives a core: the durable outbox and messages. */
export class FakeDurable {
  readonly intents = new Map<TxId, Intent>()
  /** Every tx whose effect was applied, in order. A tx appears here once or the core is wrong. */
  readonly applied: TxId[] = []
  readonly messages: MessageRow[] = []
  readonly cores: FakeCore[] = []
}

export type FakeCoreOptions = {
  buildId?: string
  userId?: string
}

export class FakeCore implements CoreEndpoint {
  readonly received: Command[] = []
  readonly subs = new Map<SubId, QueryDescriptor>()
  revision = 0
  closed = false
  killed = false
  private readonly listeners = new Set<CoreMessageListener>()
  /** Latest result per tx this core reported, for snapshots. */
  readonly results = new Map<TxId, IntentResult>()
  private skipNext = false
  private muted = false
  private readonly buildId: string
  private readonly userId: UserId

  constructor(
    readonly durable: FakeDurable,
    options: FakeCoreOptions = {},
  ) {
    this.buildId = options.buildId ?? "build-1"
    this.userId = (options.userId ?? "7") as UserId
    durable.cores.push(this)
  }

  get alive() {
    return !this.closed && !this.killed
  }

  post(command: Command) {
    if (!this.alive) return
    this.received.push(command)
    queueMicrotask(() => this.handle(command))
  }

  subscribe(listener: CoreMessageListener) {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  close() {
    this.closed = true
    this.listeners.clear()
  }

  /** The core dies without closing. */
  kill() {
    this.killed = true
    this.listeners.clear()
  }

  /** Keeps working but delivers nothing: results are lost on the way out. */
  mute() {
    this.muted = true
  }

  /** The next patch skips a revision, as if one were lost. */
  skipRevision() {
    this.skipNext = true
  }

  /** Reports a server acknowledgement. */
  confirm(tx: TxId) {
    this.emitPatch({ rows: [], lists: [], resources: [], settled: [{ tx, status: "confirmed" }] })
  }

  /** A row change from the server, delivered to every chat window showing it. */
  receiveMessage(row: MessageRow) {
    this.durable.messages.push(row)
    this.emitPatch({
      rows: [{ op: "upsert", row }],
      lists: this.chatLists(row.chatId),
      resources: [],
      settled: [],
    })
  }

  commandsOf<K extends Command["kind"]>(kind: K): Extract<Command, { kind: K }>[] {
    return this.received.filter((command): command is Extract<Command, { kind: K }> => command.kind === kind)
  }

  private handle(command: Command) {
    if (!this.alive) return
    switch (command.kind) {
      case "hello":
        this.emit({ kind: "hello", buildId: this.buildId, protocol: command.protocol })
        return
      case "subscribe": {
        this.subs.set(command.sub, command.query)
        const view = this.view(command.sub, command.query)
        this.emitPatch({
          rows: view.rows.map((row) => ({ op: "upsert", row })),
          lists: view.keys ? [{ sub: command.sub, op: "replace", keys: view.keys }] : [],
          resources: view.resource ? [{ sub: command.sub, value: view.resource }] : [],
          settled: [],
        })
        return
      }
      case "unsubscribe":
        this.subs.delete(command.sub)
        return
      case "intent":
        this.intent(command.tx, command.intent)
        return
      case "resync":
        this.emit({ kind: "snapshot", snapshot: this.snapshot() })
        return
      default:
        return
    }
  }

  private intent(tx: TxId, intent: Intent) {
    if (this.durable.intents.has(tx)) {
      this.emitPatch({ rows: [], lists: [], resources: [], settled: [{ tx, status: "accepted" }] })
      return
    }
    this.durable.intents.set(tx, intent)
    this.durable.applied.push(tx)
    if (intent.kind !== "sendText") {
      this.emitPatch({ rows: [], lists: [], resources: [], settled: [{ tx, status: "accepted" }] })
      return
    }
    const row = optimisticMessageRow(intent, this.userId, 1_700_000_000)
    this.durable.messages.push(row)
    const settled: IntentResult = { tx, status: "accepted", rows: [rowKey("message", row.id)] }
    this.emitPatch({
      rows: [{ op: "upsert", row }],
      lists: this.chatLists(intent.chatId),
      resources: [],
      settled: [settled],
    })
  }

  private chatLists(chatId: ChatId): ListChange[] {
    const lists: ListChange[] = []
    for (const [sub, query] of this.subs) {
      if (query.kind === "chatWindow" && query.chatId === chatId) {
        lists.push({ sub, op: "replace", keys: this.messageKeys(chatId) })
      }
    }
    return lists
  }

  private messageKeys(chatId: ChatId): RowKey[] {
    return this.durable.messages.filter((m) => m.chatId === chatId).map((m) => rowKey("message", m.id))
  }

  private view(_sub: SubId, query: QueryDescriptor): { rows: Row[]; keys?: RowKey[]; resource?: CoreResource } {
    switch (query.kind) {
      case "core":
        return {
          rows: [],
          resource: {
            kind: "core",
            phase: "ready",
            connection: "connected",
            storage: "persistent",
            buildId: this.buildId,
            userId: this.userId,
          },
        }
      case "chatWindow":
        return {
          rows: this.durable.messages.filter((m) => m.chatId === query.chatId),
          keys: this.messageKeys(query.chatId),
        }
      default:
        return { rows: [], keys: [] }
    }
  }

  private snapshot(): Snapshot {
    const rows = new Map<RowKey, Row>()
    const lists: Snapshot["lists"] = []
    const resources: ResourceChange[] = []
    for (const [sub, query] of this.subs) {
      const view = this.view(sub, query)
      for (const row of view.rows) rows.set(rowKey(row.kind, row.id), row)
      if (view.keys) lists.push({ sub, keys: view.keys })
      if (view.resource) resources.push({ sub, value: view.resource })
    }
    return { revision: this.revision, rows: [...rows.values()], lists, resources, settled: [...this.results.values()] }
  }

  private emitPatch(body: Omit<Patch, "base" | "revision">) {
    if (!this.alive) return
    for (const result of body.settled) this.results.set(result.tx, result)
    if (this.skipNext) {
      this.skipNext = false
      this.revision += 1
    }
    const base = this.revision
    this.revision += 1
    this.emit({ kind: "patch", patch: { base, revision: this.revision, ...body } })
  }

  private emit(message: CoreMessage) {
    if (!this.alive || this.muted) return
    for (const listener of Array.from(this.listeners)) listener(message)
  }
}

/**
 * A minimal view store: applies snapshots and patches, and fails loudly if a
 * patch's base is not the last revision it applied.
 */
export class RecordingUi {
  readonly messages: CoreMessage[] = []
  readonly rows = new Map<RowKey, Row>()
  readonly lists = new Map<SubId, RowKey[]>()
  readonly resources = new Map<SubId, ResourceChange["value"]>()
  readonly settled: IntentResult[] = []
  readonly errors: string[] = []
  revision = 0
  snapshots = 0
  private readonly unsubscribe: () => void

  constructor(endpoint: CoreEndpoint) {
    this.unsubscribe = endpoint.subscribe((message) => this.apply(message))
  }

  stop() {
    this.unsubscribe()
  }

  list(sub: SubId): RowKey[] | undefined {
    return this.lists.get(sub)
  }

  settledFor(tx: TxId): IntentResult["status"][] {
    return this.settled.filter((result) => result.tx === tx).map((result) => result.status)
  }

  phase(sub: SubId): string | undefined {
    const value = this.resources.get(sub)
    return value?.kind === "core" ? value.phase : undefined
  }

  private apply(message: CoreMessage) {
    this.messages.push(message)
    if (message.kind === "snapshot") {
      const snapshot = message.snapshot
      this.snapshots += 1
      this.rows.clear()
      this.lists.clear()
      this.resources.clear()
      for (const row of snapshot.rows) this.rows.set(rowKey(row.kind, row.id), row)
      for (const list of snapshot.lists) this.lists.set(list.sub, list.keys)
      for (const resource of snapshot.resources) this.resources.set(resource.sub, resource.value)
      this.settled.push(...(snapshot.settled ?? []))
      this.revision = snapshot.revision
      return
    }
    if (message.kind !== "patch") return
    const patch = message.patch
    if (patch.base !== this.revision || patch.revision !== patch.base + 1) {
      this.errors.push(`patch ${patch.base}->${patch.revision} after ${this.revision}`)
    }
    this.revision = patch.revision
    for (const change of patch.rows) {
      if (change.op === "upsert") this.rows.set(rowKey(change.row.kind, change.row.id), change.row)
      else this.rows.delete(rowKey(change.kind, change.id))
    }
    for (const change of patch.lists) {
      if (change.op === "replace") this.lists.set(change.sub, change.keys)
      else {
        const keys = [...(this.lists.get(change.sub) ?? [])]
        keys.splice(change.index, change.remove, ...change.insert)
        this.lists.set(change.sub, keys)
      }
    }
    for (const resource of patch.resources) this.resources.set(resource.sub, resource.value)
    this.settled.push(...patch.settled)
  }
}
