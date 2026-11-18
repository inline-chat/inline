import { Log, LogRingBuffer, type LogRecord } from "@inline/log"
import { spaceId as makeSpaceId, userId as makeUserId, type UserID } from "@inline/ids"
import { AuthStore } from "../auth"
import { Db } from "../database"
import {
  DbObjectKind,
  type Chat,
  type DeferredUpdate,
  type SpaceMember,
  type Dialog,
  type Message,
  type PendingTransaction,
  type SyncBucketState,
  type SyncGlobalState,
} from "../database/models"
import { DbQueryPlanType } from "../database/types"
import { RealtimeClient } from "../realtime/realtime"
import { DbSyncStorage, SyncEngine, type SyncStorage } from "../realtime/sync"
import { syncBucketId, type SyncBucketKey } from "../realtime/sync/sync-types"
import {
  upsertChat,
  upsertDialog,
  upsertMessage,
  upsertUser,
} from "../realtime/transactions/mappers"
import { CrashableDisk, type CrashRule, type CrashableStore } from "./crashable-disk"
import { ScriptedTransport } from "./scripted-transport"
import {
  ModelServerEndpoint,
  ServerModel,
  chatPeer,
  encodeChat,
  encodeDialog,
  encodeMessage,
  encodeUser,
  type BucketId,
  type FrameInterceptor,
} from "./server-model"
import { useFakeTime, type FakeTime } from "./virtual-clock"

/**
 * A real account core (Db on in-memory SQLite, RealtimeClient with its real
 * ConnectionManager, SyncEngine and outbox) wired to the server model through
 * a scripted transport, under fake time. One harness owns:
 *
 * - `clock`: fake timers driving every global timer and `Date`;
 * - `model`: the server model, the oracle;
 * - `disk`: the SQLite replica, which survives `restart()`;
 * - `process`: the live core; `restart()` replaces it, optionally as a crash.
 *
 * Nothing here sleeps. `settle()` runs until no frame, commit or timer moves.
 */

export type CoreProcess = {
  readonly store: CrashableStore
  readonly db: Db
  readonly auth: AuthStore
  readonly transport: ScriptedTransport
  readonly endpoint: ModelServerEndpoint
  readonly client: RealtimeClient
  readonly sync: SyncEngine
}

export type CoreHarnessOptions = {
  model?: ServerModel
  selfUserId?: bigint
  startMs?: number
  /** Fixed reconnect backoff, so schedules stay deterministic. Default 1 s. */
  backoffMs?: number
  /** Wrap the sync storage, for instance to plant a bug. */
  wrapSyncStorage?: (storage: SyncStorage) => SyncStorage
  /** Keep the last N core log records for failure reports. Default 400. */
  logLimit?: number
}

export type ReplicaSnapshot = {
  /** Durable rows, read back from SQLite. */
  messages: Message[]
  chats: Chat[]
  dialogs: Dialog[]
  pendingTransactions: PendingTransaction[]
  buckets: SyncBucketState[]
  deferredUpdates: DeferredUpdate[]
  spaceMembers: SpaceMember[]
  globalState?: SyncGlobalState
  /** Rows resident in the live Db's memory. */
  residentMessages: Message[]
  /** A write the Db could not flush to SQLite, if any. */
  flushError?: unknown
}

export const bucketKeyFor = (bucketId: BucketId): SyncBucketKey => {
  if (bucketId === "user") return { kind: "user" }
  if (bucketId.startsWith("space:")) {
    return { kind: "space", spaceId: makeSpaceId(bucketId.slice("space:".length)) }
  }
  return { kind: "chat", peer: chatPeer(BigInt(bucketId.slice("chat:".length))) }
}

export class CoreHarness {
  readonly clock: FakeTime
  readonly model: ServerModel
  readonly disk = new CrashableDisk()
  readonly logs: LogRingBuffer
  readonly selfUserId: bigint
  private current: CoreProcess | undefined
  private residentRevision = 0
  private unsubscribeResident: (() => void) | undefined
  private readonly options: CoreHarnessOptions

  private constructor(options: CoreHarnessOptions) {
    this.options = options
    this.clock = useFakeTime(options.startMs != null ? { startMs: options.startMs } : {})
    this.selfUserId = options.model?.selfUserId ?? options.selfUserId ?? 1n
    this.model =
      options.model ??
      new ServerModel({ selfUserId: this.selfUserId, now: () => this.clock.nowSeconds() })
    this.logs = new LogRingBuffer(options.logLimit ?? 400, 4 * 1_024 * 1_024)
  }

  /** Create a harness. Fake time is installed until `dispose()`. */
  static create(options: CoreHarnessOptions = {}) {
    return new CoreHarness(options)
  }

  get process(): CoreProcess {
    if (!this.current) throw new Error("No core process; call boot() first")
    return this.current
  }

  /** Whether a core process is live (not crashed or shut down). */
  get isRunning() {
    return this.current != null
  }

  get self(): UserID {
    return makeUserId(this.selfUserId)
  }

  /**
   * Start a core process on the disk and sign it in. It is not connected
   * until `connect()` (or the transport's policy) accepts the attempt.
   */
  async boot(options: { crashRule?: CrashRule; connectPolicy?: "manual" | "accept" } = {}) {
    if (this.current) throw new Error("A core process is already running")
    const logger = new Log("Core", {
      level: "debug",
      sink: false,
      recordSinks: [this.logs],
    })
    const store = this.disk.openStore(
      options.crashRule ? { crashRule: options.crashRule } : {},
    )
    const db = new Db({ persistenceStore: store, autoHydrate: true, logger })
    await this.settleUntil(db.ready)
    const auth = new AuthStore()
    const transport = new ScriptedTransport({ connectPolicy: options.connectPolicy ?? "accept" })
    const endpoint = new ModelServerEndpoint(this.model, transport)
    let realtime: RealtimeClient | undefined
    const baseStorage: SyncStorage = new DbSyncStorage(db)
    const sync = new SyncEngine({
      db,
      client: {
        callRpc: (method, input, rpcOptions) => {
          if (!realtime) return Promise.reject(new Error("Realtime is not constructed"))
          return realtime.client.callRpc(method, input, rpcOptions)
        },
      },
      storage: this.options.wrapSyncStorage?.(baseStorage) ?? baseStorage,
      logger: logger.withScope("Sync"),
    })
    const backoffMs = this.options.backoffMs ?? 1_000
    realtime = new RealtimeClient({
      auth,
      db,
      transport,
      sync,
      logger,
      url: "ws://model.test",
      connection: { backoffDelayMs: () => backoffMs },
    })
    this.unsubscribeResident?.()
    this.unsubscribeResident = db.subscribeToResidentChanges((batch) => {
      this.residentRevision += 1 + batch.changes.length
    })
    this.current = { store, db, auth, transport, endpoint, client: realtime, sync }
    await this.settleUntil(
      realtime.startSession({ token: "model-token", userId: this.self }),
    )
    return this.current
  }

  /** Write the model's current state straight into the replica, cursors included. */
  async seedReplicaFromModel() {
    const { db } = this.process
    const model = this.model
    await this.settleUntil(
      db.commit(() => {
        for (const user of model.users.values()) upsertUser(db, encodeUser(user))
        for (const chat of model.chats.values()) {
          upsertChat(db, encodeChat(chat))
          const dialog = model.dialogs.get(chat.id)
          if (dialog) upsertDialog(db, encodeDialog(chat, dialog, model.unreadCount(chat.id)))
          for (const message of chat.messages.values()) {
            upsertMessage(db, encodeMessage(message, model.selfUserId))
          }
        }
        for (const bucketId of model.bucketIds()) {
          db.replace({
            kind: DbObjectKind.SyncBucketState,
            id: syncBucketId(bucketKeyFor(bucketId)),
            seq: model.bucketSeq(bucketId),
            date: this.clock.nowSeconds(),
          })
        }
        db.replace({
          kind: DbObjectKind.SyncGlobalState,
          id: 0,
          lastSyncDate: this.clock.nowSeconds(),
        })
      }),
    )
  }

  /** Point every server frame of the current process at `interceptor`. */
  intercept(interceptor: FrameInterceptor) {
    this.process.endpoint.interceptor = interceptor
  }

  /** A value that changes whenever the system makes progress. */
  progress = () => {
    const current = this.current
    if (!current) return this.residentRevision
    return `${current.transport.activity}:${this.residentRevision}:${current.client.connectionState}`
  }

  settle() {
    return this.clock.settle({ progress: this.progress, quietRounds: 4 })
  }

  /** Drive time until `predicate` holds. */
  runUntil(
    predicate: () => boolean,
    options: { stepMs?: number; maxMs?: number; description?: string } = {},
  ) {
    return this.clock.runUntil(predicate, {
      progress: this.progress,
      quietRounds: 4,
      ...options,
    })
  }

  /** Await a promise from the core while driving fake time. */
  async settleUntil<T>(promise: Promise<T>, maxMs = 120_000): Promise<T> {
    let outcome: { value: T } | { error: unknown } | undefined
    promise.then(
      (value) => {
        outcome = { value }
      },
      (error: unknown) => {
        outcome = { error }
      },
    )
    await this.clock.runUntil(() => outcome != null, {
      progress: this.progress,
      quietRounds: 2,
      stepMs: 250,
      maxMs,
      description: "awaited core promise",
    })
    const settled = outcome!
    if ("error" in settled) throw settled.error
    return settled.value
  }

  connected() {
    return this.current?.client.connectionState === "connected"
  }

  pendingIntents() {
    if (!this.current) return 0
    return this.current.db
      .queryCollection<
        DbObjectKind.PendingTransaction,
        PendingTransaction,
        DbQueryPlanType.Objects
      >(DbQueryPlanType.Objects, DbObjectKind.PendingTransaction)
      .filter((record) => record.status === "pending").length
  }

  /**
   * Remove every fault, make sure the client is connected on a fresh
   * connection (which runs discovery and the user bucket), and drive time
   * until the outbox is empty and sync is idle.
   */
  async heal(options: { reconnect?: boolean; maxMs?: number } = {}) {
    const { transport, endpoint, sync } = this.process
    endpoint.interceptor = () => "deliver"
    transport.connectPolicy = "accept"
    if (transport.isHolding) await transport.release()
    if (transport.state === "connecting") await transport.accept()
    await this.runUntil(() => this.connected(), {
      maxMs: options.maxMs ?? 120_000,
      description: "client reconnects after faults",
    })
    if (options.reconnect ?? true) {
      await transport.disconnect("heal")
      await this.runUntil(() => this.connected(), {
        maxMs: options.maxMs ?? 120_000,
        description: "client reconnects for discovery",
      })
    }
    await this.runUntil(() => this.connected() && this.pendingIntents() === 0, {
      stepMs: 500,
      maxMs: options.maxMs ?? 120_000,
      description: "outbox drains",
    })
    await this.settleUntil(sync.idle())
    await this.settle()
  }

  /** Kill the live process (no clean shutdown) and forget it. */
  crash() {
    const current = this.current
    if (!current) return
    this.disk.crash()
    current.transport.kill()
    current.endpoint.dispose()
    this.unsubscribeResident?.()
    this.unsubscribeResident = undefined
    this.current = undefined
  }

  /** Stop the live process cleanly. */
  async shutdown() {
    const current = this.current
    if (!current) return
    await this.settleUntil(current.client.stop()).catch(() => undefined)
    await this.settleUntil(current.db.closePersistence()).catch(() => undefined)
    current.transport.kill()
    current.endpoint.dispose()
    this.unsubscribeResident?.()
    this.unsubscribeResident = undefined
    this.current = undefined
  }

  /** Replace the process: crash or shut down, then boot a new one on the disk. */
  async restart(options: { crash?: boolean; crashRule?: CrashRule } = {}) {
    if (options.crash) this.crash()
    else await this.shutdown()
    return await this.boot(options.crashRule ? { crashRule: options.crashRule } : {})
  }

  /** What the replica holds: durable rows from SQLite, plus resident messages. */
  async snapshot(): Promise<ReplicaSnapshot> {
    const { db, store } = this.process
    let flushError: unknown
    try {
      await this.settleUntil(db.flushPersistence())
    } catch (error) {
      flushError = error
    }
    const read = <K extends DbObjectKind>(kind: K) =>
      this.settleUntil(store.collection(kind).getAll())
    const [messages, chats, dialogs, pendingTransactions, buckets, deferredUpdates, global, spaceMembers] =
      await Promise.all([
        read(DbObjectKind.Message),
        read(DbObjectKind.Chat),
        read(DbObjectKind.Dialog),
        read(DbObjectKind.PendingTransaction),
        read(DbObjectKind.SyncBucketState),
        read(DbObjectKind.DeferredUpdate),
        read(DbObjectKind.SyncGlobalState),
        read(DbObjectKind.SpaceMember),
      ])
    return {
      messages,
      chats,
      dialogs,
      pendingTransactions,
      buckets,
      deferredUpdates,
      spaceMembers,
      ...(global[0] ? { globalState: global[0] } : {}),
      residentMessages: db.queryCollection<
        DbObjectKind.Message,
        Message,
        DbQueryPlanType.Objects
      >(DbQueryPlanType.Objects, DbObjectKind.Message),
      ...(flushError !== undefined ? { flushError } : {}),
    }
  }

  /** The last core log records, oldest first, for a failure report. */
  recentLogs(limit = 60): string[] {
    return this.logs
      .snapshot()
      .slice(-limit)
      .map((record: LogRecord) => `${record.level} ${record.scope} ${record.event}`)
  }

  async dispose() {
    try {
      if (this.current) {
        this.current.transport.kill()
        this.current.endpoint.dispose()
        this.current = undefined
      }
      this.unsubscribeResident?.()
      await this.disk.dispose()
    } finally {
      this.clock.dispose()
    }
  }
}
