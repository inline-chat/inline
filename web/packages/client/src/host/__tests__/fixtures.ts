/**
 * Fixtures for host tests: a fake disk (in-memory SQLite that outlives a
 * store until erased), a transport a test can await, and a UI context that
 * applies patches with the `core-protocol` reference reducer.
 */
import {
  ServerProtocolMessage,
  type ClientMessage,
  type Message as ProtocolMessage,
  type RpcResult,
  type Update,
} from "@inline-chat/protocol/core"
import type { Database, Sqlite3Static } from "@sqlite.org/sqlite-wasm"
import {
  applyPatch,
  applySnapshot,
  createProtocolState,
  type Command,
  type CoreEndpoint,
  type CoreMessage,
  type CoreResource,
  type IntentResult,
  type Patch,
  type ProtocolState,
  type QueryDescriptor,
  type Row,
  type RowKey,
  type SubId,
  type TxId,
  type WindowResource,
} from "@inline/core-protocol"
import type { UserID } from "@inline/ids"
import type { DbModel } from "../../database/models"
import { SQLitePersistenceStore } from "../../database/sqlite/SQLitePersistenceStore"
import { MockTransport } from "../../realtime/transport/mock-transport"
import type { HostStorage } from "../account-core"

let sqlitePromise: Promise<Sqlite3Static> | null = null
const sqlite = () => {
  sqlitePromise ??= import("@sqlite.org/sqlite-wasm").then(({ default: init }) => init())
  return sqlitePromise
}

/**
 * One account's "disk". Closing a store leaves the database in place, as a
 * file would be; `erase` deletes it.
 */
export class FakeDisk {
  private database: Database | null = null
  erased = 0
  opened = 0

  private async open(): Promise<Database> {
    if (!this.database) {
      const sqlite3 = await sqlite()
      this.database = new sqlite3.oo1.DB(":memory:", "c")
    }
    const database = this.database
    // The store closes its handle on close; the "file" stays.
    return new Proxy(database, {
      get(target, property) {
        if (property === "close") return () => undefined
        const value = Reflect.get(target, property, target) as unknown
        return typeof value === "function" ? value.bind(target) : value
      },
    })
  }

  /** Fail the next write transaction just before COMMIT, as a full disk would. */
  failNextWrite: unknown = undefined

  store(): SQLitePersistenceStore {
    return new SQLitePersistenceStore(() => this.open(), {
      onWriteCheckpoint: ({ phase }) => {
        if (phase !== "before-commit" || this.failNextWrite === undefined) return
        const error = this.failNextWrite
        this.failNextWrite = undefined
        throw error
      },
    })
  }

  storage(): HostStorage {
    this.opened += 1
    return {
      store: this.store(),
      kind: "persistent",
      erase: async () => {
        this.erased += 1
        this.database?.close()
        this.database = null
      },
    }
  }

  async seed(objects: DbModel[]) {
    const store = this.store()
    await store.open()
    await store.write(objects.map((object) => ({ type: "put", object })))
    await store.close()
  }

  /** Rows in a table, read without migrating (the replica may be from a newer schema). */
  async count(table: string): Promise<number> {
    const db = await this.open()
    const exists = db.selectValue("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [table])
    if (exists == null) return 0 // erased: an empty file
    return Number(db.selectValue(`SELECT COUNT(*) FROM ${table}`))
  }

  /** Raw access for faults, such as a replica from a newer schema. */
  async exec(sql: string) {
    const store = this.store()
    const db = await store.database()
    db.exec(sql)
    await store.close()
  }
}

/** A mock transport whose sends a test can await. */
export class ScriptedTransport extends MockTransport {
  private waiters: Array<{ match: (message: ClientMessage) => boolean; resolve: (message: ClientMessage) => void }> = []
  private nextId = 100n

  override async send(message: ClientMessage) {
    await super.send(message)
    for (const waiter of this.waiters.slice()) {
      if (waiter.match(message)) {
        this.waiters.splice(this.waiters.indexOf(waiter), 1)
        waiter.resolve(message)
      }
    }
  }

  /** The first RPC (already sent or next) with this input kind that passes `where`. */
  rpc(kind: string, where: (message: ClientMessage) => boolean = () => true): Promise<ClientMessage> {
    const match = (message: ClientMessage) =>
      message.body.oneofKind === "rpcCall" &&
      message.body.rpcCall.input.oneofKind === kind &&
      where(message)
    const sent = this.sent.find(match)
    if (sent) return Promise.resolve(sent)
    return new Promise((resolve) => this.waiters.push({ match, resolve }))
  }

  async open() {
    await this.connect()
    await this.emitMessage(
      ServerProtocolMessage.create({
        id: this.nextId++,
        body: { oneofKind: "connectionOpen", connectionOpen: {} },
      }),
    )
  }

  async reply(request: ClientMessage, result: RpcResult["result"]) {
    await this.emitMessage(
      ServerProtocolMessage.create({
        id: this.nextId++,
        body: { oneofKind: "rpcResult", rpcResult: { reqMsgId: request.id, result } },
      }),
    )
  }

  async fail(request: ClientMessage, code = 400) {
    await this.emitMessage(
      ServerProtocolMessage.create({
        id: this.nextId++,
        body: {
          oneofKind: "rpcError",
          rpcError: { reqMsgId: request.id, errorCode: code, message: "rejected", code } as never,
        },
      }),
    )
  }
}

export const newMessageUpdate = (message: ProtocolMessage): Update =>
  ({ update: { oneofKind: "newMessage", newMessage: { message } } }) as Update

export const updateMessageIdUpdate = (messageId: bigint, randomId: bigint): Update =>
  ({ update: { oneofKind: "updateMessageId", updateMessageId: { messageId, randomId } } }) as Update

/**
 * A UI context driven like the view store would drive it: patches applied
 * with the reference reducer, a resync on a gap, and event-driven waits.
 */
export class TestContext {
  readonly state: ProtocolState = createProtocolState()
  readonly patches: Patch[] = []
  readonly settled: IntentResult[] = []
  snapshots = 0
  gaps = 0
  /** Drop the next N patches, as a lossy carrier would. */
  drop = 0
  private waiters: Array<() => void> = []
  private readonly observers = new Set<(patch: Patch) => void>()
  private readonly unsubscribe: () => void

  constructor(readonly endpoint: CoreEndpoint) {
    this.unsubscribe = endpoint.subscribe((message) => this.receive(message))
  }

  post(command: Command) {
    this.endpoint.post(command)
  }

  subscribeTo(sub: SubId, query: QueryDescriptor) {
    this.post({ kind: "subscribe", sub, query })
  }

  /** Called after each applied patch, with the state already updated. */
  observe(observer: (patch: Patch) => void): () => void {
    this.observers.add(observer)
    return () => this.observers.delete(observer)
  }

  close() {
    this.unsubscribe()
    this.endpoint.close()
  }

  private receive(message: CoreMessage) {
    if (message.kind === "patch") {
      if (this.drop > 0) {
        this.drop -= 1
        return
      }
      this.patches.push(message.patch)
      const outcome = applyPatch(this.state, message.patch)
      if (outcome === "gap") {
        this.gaps += 1
        this.post({ kind: "resync" })
      } else if (outcome === "applied") {
        this.settled.push(...message.patch.settled)
        for (const observer of this.observers) observer(message.patch)
      }
    } else if (message.kind === "snapshot") {
      this.snapshots += 1
      applySnapshot(this.state, message.snapshot)
      this.settled.push(...(message.snapshot.settled ?? []))
    }
    for (const waiter of this.waiters.splice(0)) waiter()
  }

  list(sub: SubId): RowKey[] {
    return this.state.lists.get(sub) ?? []
  }

  rows(sub: SubId): Row[] {
    return this.list(sub).map((key) => {
      const row = this.state.rows.get(key)
      if (!row) throw new Error(`list ${sub} names missing row ${key}`)
      return row
    })
  }

  core(sub: SubId): CoreResource | undefined {
    const value = this.state.resources.get(sub)
    return value?.kind === "core" ? value : undefined
  }

  window(sub: SubId): WindowResource | undefined {
    const value = this.state.resources.get(sub)
    return value?.kind === "window" ? value : undefined
  }

  result(tx: TxId, status?: IntentResult["status"]): IntentResult | undefined {
    const matches = this.settled.filter(
      (result) => result.tx === tx && (!status || result.status === status),
    )
    return matches[matches.length - 1]
  }

  /** Resolve when `predicate` holds after some message (or now). */
  async until(predicate: () => boolean, label = "condition"): Promise<void> {
    let remaining = 200
    while (!predicate()) {
      if (remaining-- === 0) throw new Error(`Gave up waiting for ${label}`)
      await new Promise<void>((resolve) => this.waiters.push(resolve))
    }
  }
}

export const me = "7" as UserID
