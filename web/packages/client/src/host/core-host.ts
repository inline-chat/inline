/**
 * The core host for one account at a time. It implements `CoreEndpoint`
 * in-process: UI contexts post commands and receive patches. `link` carries
 * the same interface across a worker or between tabs; nothing here knows
 * about either.
 *
 * Guarantees (see host/README.md for the full list and what is not done):
 * - Each context gets patches with contiguous revisions; `resync` answers
 *   with a snapshot one revision on.
 * - Query results are read from the committed view (queries/view.ts), so a
 *   row is on disk before a UI sees it.
 * - An intent is `accepted` only after its durable commit.
 * - Sign-out and server revocation stop the core and erase the replica.
 */
import {
  CORE_PROTOCOL_VERSION,
  type BrowserSignal,
  type Command,
  type ConnectionState,
  type CoreEndpoint,
  type CoreMessage,
  type CoreMessageListener,
  type CorePhase,
  type CoreResource,
  type Intent,
  type IntentResult,
  type QueryDescriptor,
  type SessionInfo,
  type StorageState,
  type SubId,
  type SearchIndexState,
  type SyncStall,
  type TxId,
} from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import { Log } from "@inline/log"
import type { DbResidentChange } from "../database"
import { DbObjectKind, type MessageKey } from "../database/models"
import type { QueryEnv } from "../queries/compute"
import { plainEqual } from "../queries/diff"
import { QueryContext } from "../queries/context"
import { isPositiveId, isValidQuery } from "../queries/validate"
import type { Transport } from "../realtime/transport/transport"
import {
  AccountCore,
  OutdatedReplicaError,
  type HostMediaConfig,
  type HostRealtimeOptions,
  type HostStorage,
} from "./account-core"
import { handledQuery } from "../queries/compute"
import { isMediaRef } from "../queries/validate"
import { hasErrorNamed } from "./errors"
import { runIntent } from "./intents"
import {
  accountFiles,
  clearEraseMarker,
  defaultByteStore,
  eraseMediaFiles,
  finishPendingErase,
  writeEraseMarker,
  type AccountFiles,
} from "./erase"
import type { EnsureRange } from "./windows"

export type CoreHostOptions = {
  /** This build's ID; sent in `hello` and in the `core` resource. */
  buildId: string
  /** Open (do not erase) the storage for an account. */
  openStorage: (userId: UserID) => HostStorage | Promise<HostStorage>
  /** Defaults to the realtime client's WebSocket transport. */
  createTransport?: (userId: UserID) => Transport
  realtime?: HostRealtimeOptions
  logger?: Log
  /** Milliseconds since the epoch. */
  now?: () => number
  /** Messages per window page. Default 50, at most 200. */
  pageSize?: number
  /**
   * How long sign-out waits for the server's `LOG_OUT` answer before it
   * completes locally. Default 3000 ms.
   */
  logOutTimeoutMs?: number
  /** How long after the first ready publish local search starts indexing. Default 1000 ms. */
  searchStartDelayMs?: number
  /** The account's media core (`false`: none). Defaults in `HostMediaConfig`. */
  media?: HostMediaConfig | false
  /**
   * Erase an account's replica without opening it (the browser:
   * `eraseOpfsHostStorage`), to finish an erase a killed core left behind.
   * Default: open it unread, close it, erase it.
   */
  eraseStorage?: (userId: UserID) => Promise<void>
}

type WindowLease = {
  chatId: ChatID
  account: AccountCore
  opened: boolean
  cancelled: boolean
}

type IntentEntry = {
  contexts: Set<HostContext>
  latest?: IntentResult
  /** Resolves the `idle()` hold once the first result is known. */
  reported?: () => void
}

/** How many settled intents the host remembers for idempotent retries. */
const INTENT_MEMORY = 1024

let nextContextId = 1

/** One UI context's endpoint on the host. */
export class HostContext implements CoreEndpoint {
  readonly id = nextContextId++
  readonly queries: QueryContext
  closed = false
  private readonly listeners = new Set<CoreMessageListener>()

  constructor(
    private readonly dispatch: (context: HostContext, command: Command) => void,
    private readonly onClose: (context: HostContext) => void,
    private readonly log: Log,
  ) {
    this.queries = new QueryContext((message) => this.emit(message))
  }

  post(command: Command): void {
    if (this.closed) return
    try {
      this.dispatch(this, command)
    } catch (error) {
      this.log.error("command.failed", { error })
    }
  }

  subscribe(listener: CoreMessageListener): () => void {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  close(): void {
    if (this.closed) return
    this.onClose(this)
    this.closed = true
    this.listeners.clear()
  }

  emit(message: CoreMessage) {
    if (this.closed) return
    for (const listener of Array.from(this.listeners)) {
      try {
        listener(message)
      } catch (error) {
        this.log.error("listener.failed", { error })
      }
    }
  }
}

export class CoreHost implements CoreEndpoint {
  private readonly log: Log
  private readonly contexts = new Set<HostContext>()
  private readonly primary: HostContext
  private readonly now: () => number
  private readonly pageSize: number

  private phase: CorePhase = "signedOut"
  private connection: ConnectionState = "idle"
  private storage: StorageState = "persistent"
  private stalledSync: SyncStall[] | undefined
  private searchIndex: SearchIndexState | undefined
  /** A sign-out is erasing the account's data: intents are refused. */
  private signingOut = false
  /** How the last sign-out's or revocation's erase ended. */
  private erased: "complete" | "failed" | undefined
  /** Each account's byte store and root, for its erase marker. */
  private readonly files = new Map<UserID, AccountFiles>()
  private userId: UserID | undefined
  private failure: string | undefined
  private account: AccountCore | null = null
  /** Storage of a session that failed to start, kept so sign-out can erase it. */
  private unopenedStorage: HostStorage | null = null
  private generation = 0
  private shutdownTask: Promise<void> | null = null
  /** Session commands queued or running; intents wait for them. */
  private sessionOperations = 0
  private facts = { online: true, visible: true }

  private sessionQueue: Promise<void> = Promise.resolve()
  private pendingChanges: DbResidentChange[] = []
  private recomputeAll = false
  private flushScheduled = false
  private readonly tasks = new Set<Promise<unknown>>()
  private readonly leases = new Map<string, WindowLease>()
  private readonly intents = new Map<TxId, IntentEntry>()
  /** Handled subscriptions (media, search): lease key to handle, and handle to owner. */
  private readonly handles = new Map<string, number>()
  private readonly handleOwners = new Map<number, { context: HostContext; sub: SubId }>()
  private nextHandle = 1

  constructor(private readonly options: CoreHostOptions) {
    this.log = options.logger ?? new Log("Core.Host")
    this.now = options.now ?? Date.now
    this.pageSize = Math.min(200, Math.max(1, options.pageSize ?? 50))
    this.primary = this.openContext()
  }

  // -------------------------------------------------------------------------
  // CoreEndpoint (the primary context)

  post(command: Command): void {
    this.primary.post(command)
  }

  subscribe(listener: CoreMessageListener): () => void {
    return this.primary.subscribe(listener)
  }

  /**
   * The host as an endpoint owns the core: closing it shuts the core down
   * (see `shutdown`) and resolves once storage and the connection are
   * released. Contexts from `openContext` close on their own.
   */
  close(): Promise<void> {
    return this.shutdown()
  }

  // -------------------------------------------------------------------------
  // Host API

  /**
   * A new UI context with its own subscriptions, revisions and rows. Its first
   * message is a snapshot.
   */
  openContext(): HostContext {
    const context = new HostContext(
      (from, command) => this.handle(from, command),
      (closing) => this.closeContext(closing),
      this.log.withScope("Context"),
    )
    this.contexts.add(context)
    this.scheduleFlush()
    return context
  }

  /** Alias of `openContext`. */
  connect(): HostContext {
    return this.openContext()
  }

  /** The current `core` resource. */
  coreResource(): CoreResource {
    return {
      kind: "core",
      phase: this.phase,
      connection: this.connection,
      storage: this.storage,
      buildId: this.options.buildId,
      ...(this.userId ? { userId: this.userId } : {}),
      ...(this.failure ? { failure: this.failure } : {}),
      ...(this.stalledSync ? { stalledSync: this.stalledSync } : {}),
      ...(this.searchIndex ? { searchIndex: this.searchIndex } : {}),
      ...(this.signingOut ? { signingOut: true as const } : {}),
      ...(this.phase === "signedOut" && this.erased ? { erased: this.erased } : {}),
    }
  }

  /** The byte store holding an account's media files and its erase marker (the media core's). */
  private filesFor(userId: UserID): AccountFiles {
    let files = this.files.get(userId)
    if (!files) {
      const media = this.options.media === false ? undefined : this.options.media
      files = accountFiles(media?.store?.(userId) ?? defaultByteStore(), media?.accountKey?.(userId) ?? `u${userId}`)
      this.files.set(userId, files)
    }
    return files
  }

  /**
   * Finish an erase that a killed core left for this account (its marker is
   * still there): the replica, its search index and the media files go
   * before anything opens them. For a boot sweep of accounts nobody is
   * signed in to. Resolves whether there was one; rejects when it failed.
   */
  finishPendingErase(userId: UserID): Promise<boolean> {
    return finishPendingErase({
      userId,
      files: this.filesFor(userId),
      openStorage: this.options.openStorage,
      ...(this.options.eraseStorage ? { eraseStorage: this.options.eraseStorage } : {}),
    })
  }

  /**
   * Resolve once the host's bounded work has finished: commands, local
   * loads, intent acceptance and publishing. Server round trips are not
   * waited for.
   */
  async idle(): Promise<void> {
    while (this.tasks.size > 0) {
      await Promise.allSettled(Array.from(this.tasks))
    }
  }

  /**
   * Stop the core without erasing the replica (the worker is closing, or a
   * handoff). Resolves once the store is closed and realtime stopped.
   * Idempotent.
   */
  shutdown(): Promise<void> {
    if (this.shutdownTask) return this.shutdownTask
    this.shutdownTask = (async () => {
      // Detach the UI first: a handoff must not show it a signed-out phase.
      for (const context of Array.from(this.contexts)) context.close()
      await this.enqueueSession(async () => {
        await this.stopAccount({ erase: false, revoked: false })
      })
      await this.idle()
    })()
    return this.shutdownTask
  }

  // -------------------------------------------------------------------------
  // Commands

  private handle(context: HostContext, command: Command) {
    if (command == null || typeof command !== "object") return
    switch (command.kind) {
      case "hello":
        context.emit({
          kind: "hello",
          buildId: this.options.buildId,
          protocol: CORE_PROTOCOL_VERSION,
        })
        return
      case "session":
        if (command.action === "start") {
          const session = command.session
          void this.enqueueSession(() => this.startSession(session))
        } else if (command.action === "signOut") {
          void this.enqueueSession(() => this.signOut())
        }
        return
      case "signal":
        this.applySignal(command.signal)
        return
      case "subscribe":
        if (!Number.isSafeInteger(command.sub)) return
        this.subscribeQuery(context, command.sub, command.query)
        return
      case "unsubscribe":
        this.releaseLease(context, command.sub)
        if (context.queries.unsubscribe(command.sub)) this.scheduleFlush()
        return
      case "ensure":
        this.ensure(context, command.sub, command.range)
        return
      case "intent":
        this.intent(context, command.tx, command.intent)
        return
      case "resync":
        context.queries.requestSnapshot()
        this.scheduleFlush()
        return
      default: {
        // TODO(contract): trimWindow. Not in `core-protocol` yet; the
        // rich-content agent is adding `{ kind: "trimWindow"; sub; keep }`.
        const untyped = command as { kind?: unknown; sub?: unknown; keep?: unknown }
        if (untyped.kind === "trimWindow") {
          this.trimWindow(context, untyped.sub as SubId, untyped.keep)
          return
        }
        this.log.warn("command.unknown", {})
      }
    }
  }

  private closeContext(context: HostContext) {
    for (const [sub] of context.queries.entries()) {
      this.releaseLease(context, sub)
      context.queries.unsubscribe(sub)
    }
    for (const entry of this.intents.values()) entry.contexts.delete(context)
    this.account?.media?.dropContext(context.id)
    this.contexts.delete(context)
  }

  // -------------------------------------------------------------------------
  // Session

  private enqueueSession(operation: () => Promise<void>): Promise<void> {
    this.sessionOperations += 1
    const task = this.sessionQueue
      .then(operation)
      .catch((error: unknown) => {
        this.log.error("session.operation.failed", { error })
      })
      .finally(() => {
        this.sessionOperations -= 1
      })
    this.sessionQueue = task
    return this.track(task)
  }

  private async startSession(session: SessionInfo) {
    if (this.shutdownTask) return
    if (
      session == null ||
      typeof session.token !== "string" ||
      session.token.length === 0 ||
      !isPositiveId(session.userId)
    ) {
      this.log.warn("session.invalid", {})
      return
    }
    if (this.account?.userId === session.userId) return
    if (this.account) await this.stopAccount({ erase: false, revoked: false })

    const generation = ++this.generation
    this.userId = session.userId
    this.failure = undefined
    this.erased = undefined
    this.phase = "starting"
    this.connection = "idle"
    this.unopenedStorage = null
    this.setSubscriptionsReady(false)
    this.coreChanged()

    let storage: HostStorage | null = null
    let account: AccountCore
    try {
      // An erase a killed core left behind finishes before anything opens the replica.
      await this.finishPendingErase(session.userId)
    } catch (error) {
      if (generation !== this.generation) return
      this.log.error("session.start.erase.failed", { error })
      this.phase = "failed"
      this.failure = "The data of an earlier session could not be erased"
      this.setSubscriptionsReady(true)
      this.recomputeAll = true
      this.coreChanged()
      return
    }
    if (generation !== this.generation) return
    try {
      storage = await this.options.openStorage(session.userId)
      account = await AccountCore.open({
        session: { userId: session.userId, token: session.token },
        storage,
        ...(this.options.createTransport
          ? { transport: this.options.createTransport(session.userId) }
          : {}),
        ...(this.options.realtime ? { realtime: this.options.realtime } : {}),
        logger: this.log.withScope("Account"),
        ...(this.options.media !== undefined ? { media: this.options.media } : {}),
        ...(this.options.searchStartDelayMs !== undefined
          ? { searchStartDelayMs: this.options.searchStartDelayMs }
          : {}),
        onHandleChange: (handle) => {
          if (generation !== this.generation) return
          const owner = this.handleOwners.get(handle)
          if (!owner) return
          owner.context.queries.invalidateSub(owner.sub)
          this.scheduleFlush()
        },
        onComposeChange: (chatId) => {
          if (generation !== this.generation) return
          for (const context of this.contexts) {
            context.queries.invalidate(
              (query) => query.kind === "composeActions" && (query.chatId == null || query.chatId === chatId),
            )
          }
          this.scheduleFlush()
        },
        pageSize: this.pageSize,
        now: this.now,
        facts: { ...this.facts },
        onChanges: (batch) => {
          if (generation !== this.generation || !this.account) return
          this.pendingChanges.push(...batch.changes)
          this.scheduleFlush()
        },
        onWindowChange: (chatId) => {
          if (generation !== this.generation) return
          for (const context of this.contexts) {
            context.queries.invalidate(
              (query) => query.kind === "chatWindow" && query.chatId === chatId,
            )
          }
          this.scheduleFlush()
        },
        onState: () => {
          if (generation === this.generation) this.refreshAccountState()
        },
        onDisplayChange: (change) => {
          if (generation !== this.generation || !this.account) return
          for (const key of change.messageKeys ?? []) {
            this.pendingChanges.push({ kind: DbObjectKind.Message, id: key as MessageKey })
          }
          if (change.feed) {
            for (const context of this.contexts) {
              context.queries.invalidate((query) => query.kind === "newMessages")
            }
          }
          this.scheduleFlush()
        },
        onRosterChange: (scope, id) => {
          if (generation !== this.generation) return
          for (const context of this.contexts) {
            context.queries.invalidate((query) =>
              scope === "chat"
                ? query.kind === "chatParticipants" && query.chatId === id
                : query.kind === "spaceMembers" && query.spaceId === id,
            )
          }
          this.scheduleFlush()
        },
        onRevoked: () => {
          if (generation !== this.generation) return
          void this.enqueueSession(() => this.stopAccount({ erase: true, revoked: true }))
        },
        track: (task) => this.track(task),
      })
    } catch (error) {
      if (generation !== this.generation) return
      const outdated = error instanceof OutdatedReplicaError
      this.log.error("session.start.failed", { outdated, error })
      this.unopenedStorage = storage
      this.phase = outdated ? "outdated" : "failed"
      this.failure = outdated
        ? undefined
        : hasErrorNamed(error, "InlineSqliteUnavailableError") &&
            (error as { reason?: unknown }).reason === "opfs-busy"
          ? "Another window is still using this account's storage"
          : "The local database could not be opened"
      this.setSubscriptionsReady(true)
      this.recomputeAll = true
      this.coreChanged()
      return
    }
    if (generation !== this.generation) {
      await account.stop()
      return
    }
    this.account = account
    this.pendingChanges = []
    this.recomputeAll = true
    this.phase = "ready"
    this.refreshAccountState()
    for (const context of this.contexts) {
      for (const [sub, query] of context.queries.entries()) {
        if (query.kind !== "core") this.activate(context, sub, query)
      }
    }
    this.coreChanged()
  }

  /**
   * Sign-out from a UI: tell the server (`LOG_OUT`, bounded by
   * `logOutTimeoutMs`; skipped offline), then stop and erase. A revocation
   * from the server never comes here, so it never calls `LOG_OUT`.
   */
  private async signOut() {
    const ready = this.phase === "ready"
    // Unusable at once: intents are refused from here on.
    this.signingOut = true
    this.coreChanged()
    try {
      await this.stopAccount({
        erase: true,
        revoked: false,
        // After the erase marker is on disk, before the connection closes:
        // hand LOG_OUT to the socket and never wait for its answer.
        beforeStop: (account) => {
          if (!ready) return
          void account.sendLogOut(this.options.logOutTimeoutMs ?? 3_000).then((outcome) => {
            this.log.info("session.signOut", { server: outcome })
          })
        },
      })
    } finally {
      this.signingOut = false
      this.coreChanged()
    }
  }

  /**
   * Stop the running account. With `erase`, the replica is deleted after the
   * store closes (sign-out and revocation, invariant 10).
   */
  private async stopAccount(options: {
    erase: boolean
    revoked: boolean
    beforeStop?: (account: AccountCore) => void
  }) {
    const account = this.account
    const userId = account?.userId ?? this.userId
    const storage = account?.storage ?? this.unopenedStorage
    this.generation += 1
    this.account = null
    this.unopenedStorage = null
    this.pendingChanges = []
    this.leases.clear()
    this.handles.clear()
    this.handleOwners.clear()
    this.setSubscriptionsReady(false)

    // Intents still open cannot be followed past this point. One that may
    // have committed stays in the outbox, so its outcome is unknown.
    for (const [tx, entry] of this.intents) {
      const latest = entry.latest
      if (latest == null || latest.status === "accepted") {
        this.reportIntent(tx, entry, {
          tx,
          status: "uncertain",
          ...(latest?.rows ? { rows: latest.rows } : {}),
        })
      }
    }

    // The erase marker goes first: a core killed from here on leaves it, and
    // the next start of this account finishes the erase (`erase.ts`).
    const files = options.erase && userId ? this.filesFor(userId) : undefined
    let eraseFailed = false
    if (files) {
      try {
        await writeEraseMarker(files, this.now())
      } catch (error) {
        this.log.error("session.erase.marker.failed", { error })
        eraseFailed = true
      }
    }
    if (account) {
      options.beforeStop?.(account)
      // Closes the replica (nothing is written after this) and erases media.
      await account.stop({ erase: options.erase })
    }
    if (options.erase) {
      try {
        if (storage) await storage.erase()
        if (files) await eraseMediaFiles(files)
      } catch (error) {
        this.log.error("session.erase.failed", { error })
        eraseFailed = true
      }
      if (files && !eraseFailed) {
        await clearEraseMarker(files).catch((error: unknown) => {
          // Everything is gone; a stale marker only makes the next start erase an empty replica.
          this.log.warn("session.erase.marker.clear.failed", { error })
        })
      }
      this.erased = eraseFailed ? "failed" : "complete"
    }
    this.phase = "signedOut"
    this.failure = undefined
    this.connection = options.revoked ? "sessionRevoked" : "idle"
    this.stalledSync = undefined
    this.searchIndex = undefined
    this.userId = undefined
    this.setSubscriptionsReady(true)
    this.recomputeAll = true
    this.coreChanged()
  }

  private refreshAccountState() {
    const account = this.account
    if (!account) return
    const connection = account.connectionState()
    const storage = account.storageState()
    const stalledSync = account.syncStalls()
    const searchIndex = account.search?.indexState()
    if (
      connection === this.connection &&
      storage === this.storage &&
      plainEqual(stalledSync, this.stalledSync) &&
      plainEqual(searchIndex, this.searchIndex)
    ) {
      return
    }
    this.searchIndex = searchIndex
    this.connection = connection
    this.storage = storage
    this.stalledSync = stalledSync
    this.coreChanged()
  }

  private applySignal(signal: BrowserSignal) {
    if (signal == null || typeof signal !== "object") return
    const connection = this.account?.realtime.connection
    let task: Promise<void> | undefined
    switch (signal.kind) {
      case "online":
        if (typeof signal.online !== "boolean") return
        this.facts.online = signal.online
        task = connection?.setNetworkAvailable(signal.online)
        break
      case "visibility":
        if (typeof signal.visible !== "boolean") return
        this.facts.visible = signal.visible
        task = connection?.setAppActive(signal.visible)
        break
      case "wake":
        task = connection?.systemDidWake()
        break
      default:
        return
    }
    if (!task) return
    void this.track(
      task
        .catch((error: unknown) => this.log.warn("signal.failed", { error }))
        .then(() => this.refreshAccountState()),
    )
    this.refreshAccountState()
  }

  // -------------------------------------------------------------------------
  // Subscriptions

  private subscribeQuery(context: HostContext, sub: SubId, query: QueryDescriptor) {
    this.releaseLease(context, sub)
    const valid = isValidQuery(query)
    context.queries.subscribe(sub, query, valid ? {} : { invalid: true }, false)
    if (!valid) {
      this.log.warn("subscribe.invalid", {})
      context.queries.setReady(sub, true)
    } else if (query.kind === "core" || this.phase !== "starting") {
      if (this.phase === "ready" && query.kind !== "core") this.activate(context, sub, query)
      else context.queries.setReady(sub, true)
    }
    this.scheduleFlush()
  }

  /** Make a subscription ready against the running account. */
  private activate(context: HostContext, sub: SubId, query: QueryDescriptor) {
    const account = this.account
    if (query.kind === "newMessages" && account) {
      // The feed lists only what arrives after this point.
      context.queries.setReady(sub, true, { since: account.feed.cursor })
      return
    }
    if (account && query.kind === "chatParticipants") account.ensureRoster("chat", query.chatId)
    if (account && query.kind === "spaceMembers") account.ensureRoster("space", query.spaceId)
    if (account && query.kind === "userSettings") account.ensureSettings()
    if (account && handledQuery(query)) {
      const handle = this.nextHandle++
      this.handles.set(this.leaseKey(context, sub), handle)
      this.handleOwners.set(handle, { context, sub })
      if (query.kind === "chatMedia") {
        // First result after the device's matches are read from disk (local
        // first: no empty list for media on the device).
        context.queries.setReady(sub, false, { handle })
        const key = this.leaseKey(context, sub)
        void this.track(
          account.openHandled(handle, query).then(() => {
            if (this.handles.get(key) !== handle || this.account !== account) return
            context.queries.setReady(sub, true, { handle })
            this.scheduleFlush()
          }),
        )
        return
      }
      context.queries.setReady(sub, true, { handle })
      if (query.kind === "media") account.media?.open(handle, query.media, query.priority ?? "visible")
      else if (query.kind === "searchServerMessages" || query.kind === "searchUsers") {
        void account.openHandled(handle, query)
      } else account.search?.open(handle, query)
      return
    }
    if (query.kind !== "chatWindow" || !account) {
      context.queries.setReady(sub, true)
      return
    }
    const lease: WindowLease = {
      chatId: query.chatId,
      account,
      opened: false,
      cancelled: false,
    }
    this.leases.set(this.leaseKey(context, sub), lease)
    void this.track(
      (async () => {
        const facts = await account.windows.open(query.chatId, query.anchor)
        lease.opened = true
        if (lease.cancelled || this.account !== account) {
          if (this.account === account) account.windows.close(query.chatId)
          return
        }
        context.queries.setReady(sub, true, facts)
        this.scheduleFlush()
      })().catch((error: unknown) => {
        this.log.error("window.open.failed", { error })
        if (!lease.cancelled) {
          context.queries.setReady(sub, true)
          this.scheduleFlush()
        }
      }),
    )
  }

  private leaseKey(context: HostContext, sub: SubId) {
    return `${context.id}:${sub}`
  }

  private releaseLease(context: HostContext, sub: SubId) {
    const key = this.leaseKey(context, sub)
    const handle = this.handles.get(key)
    if (handle != null) {
      this.handles.delete(key)
      this.handleOwners.delete(handle)
      this.account?.media?.close(handle)
      this.account?.search?.close(handle)
      this.account?.closeHandled(handle)
    }
    const lease = this.leases.get(key)
    if (!lease) return
    this.leases.delete(key)
    lease.cancelled = true
    if (lease.opened && this.account === lease.account) {
      lease.account.windows.close(lease.chatId)
    }
  }

  private setSubscriptionsReady(ready: boolean) {
    for (const context of this.contexts) {
      for (const [sub, query] of context.queries.entries()) {
        if (query.kind !== "core") context.queries.setReady(sub, ready)
      }
    }
  }

  private ensure(context: HostContext, sub: SubId, range: unknown) {
    const query = context.queries.query(sub)
    const account = this.account
    if (query?.kind === "chatMedia" && account && this.phase === "ready") {
      // `older`: the next server page of the list. Other ranges mean nothing here.
      const handle = this.handles.get(this.leaseKey(context, sub))
      if (range === "older" && handle != null) account.chatMedia.older(handle)
      return
    }
    if (query?.kind !== "chatWindow" || !account || this.phase !== "ready") return
    if (!this.leases.get(this.leaseKey(context, sub))?.opened) return
    const valid =
      range === "older" ||
      range === "newer" ||
      range === "latest" ||
      (range != null &&
        typeof range === "object" &&
        isPositiveId((range as { around?: unknown }).around))
    if (!valid) return
    void this.track(
      account.windows.ensure(query.chatId, range as EnsureRange).catch((error: unknown) => {
        this.log.warn("window.ensure.failed", { error })
      }),
    )
  }

  private trimWindow(context: HostContext, sub: SubId, keep: unknown) {
    const query = context.queries.query(sub)
    const account = this.account
    if (query?.kind !== "chatWindow" || !account || this.phase !== "ready") return
    if (!this.leases.get(this.leaseKey(context, sub))?.opened) return
    const range = keep as { from?: unknown; to?: unknown } | null
    if (!range || !isPositiveId(range.from) || !isPositiveId(range.to)) return
    account.windows.trim(query.chatId, {
      from: range.from as MessageID,
      to: range.to as MessageID,
    })
  }

  // -------------------------------------------------------------------------
  // Intents

  private intent(context: HostContext, tx: TxId, intent: Intent) {
    if (typeof tx !== "string" || tx.length === 0) return
    if (this.signingOut && !this.intents.has(tx)) {
      // Signing out: nothing more is written for this account.
      context.queries.settle({ tx, status: "rejected", reason: "notSignedIn" })
      this.scheduleFlush()
      return
    }
    const existing = this.intents.get(tx)
    if (existing) {
      // A retried command (a handoff, a lost reply): answer with what is known.
      existing.contexts.add(context)
      if (existing.latest) {
        context.queries.settle(existing.latest)
        this.scheduleFlush()
      }
      return
    }
    const entry: IntentEntry = { contexts: new Set([context]) }
    this.intents.set(tx, entry)
    this.pruneIntents()
    const report = (result: IntentResult) => this.reportIntent(tx, entry, result)
    // `idle()` covers acceptance, not the server round trip that follows.
    void this.track(
      new Promise<void>((resolve) => {
        entry.reported = resolve
      }),
    )
    void (
      (async () => {
        // Commands are ordered: an intent posted after `session start` waits for it.
        while (this.phase === "starting" || this.sessionOperations > 0) await this.sessionQueue
        const account = this.account
        if (!account || this.phase !== "ready") {
          report({
            tx,
            status: "rejected",
            reason: this.phase === "signedOut" ? "notSignedIn" : "unavailable",
          })
          return
        }
        if (intent?.kind === "mediaHints") {
          const refs = Array.isArray(intent.nearby) ? intent.nearby.slice(0, 500) : undefined
          if (!refs || !refs.every(isMediaRef)) {
            report({ tx, status: "rejected", reason: "invalid" })
            return
          }
          account.media?.setNearby(context.id, refs)
          report({ tx, status: "confirmed" })
          return
        }
        await runIntent({
          account,
          tx,
          intent,
          report: (result) => {
            // Results from an account that has since stopped are stale.
            if (this.account === account) report(result)
          },
          now: this.now(),
        })
      })().catch((error: unknown) => {
        this.log.error("intent.failed", { error })
        report({ tx, status: "rejected", reason: "invalid" })
      })
    )
  }

  private reportIntent(_tx: TxId, entry: IntentEntry, result: IntentResult) {
    const latest = entry.latest
    if (latest && latest.status !== "accepted") return // already final
    entry.latest = result
    entry.reported?.()
    for (const context of entry.contexts) context.queries.settle(result)
    this.scheduleFlush()
  }

  private pruneIntents() {
    if (this.intents.size <= INTENT_MEMORY) return
    for (const [tx, entry] of this.intents) {
      if (this.intents.size <= INTENT_MEMORY) return
      if (entry.latest && entry.latest.status !== "accepted") this.intents.delete(tx)
    }
  }

  // -------------------------------------------------------------------------
  // Publishing

  private coreChanged() {
    for (const context of this.contexts) {
      context.queries.invalidate((query) => query.kind === "core")
    }
    this.scheduleFlush()
  }

  /**
   * Publish once the current task's changes are in, so several commits in one
   * task share a patch. Everything read is committed (see queries/view.ts).
   */
  private scheduleFlush() {
    if (this.flushScheduled) return
    this.flushScheduled = true
    void this.track(
      Promise.resolve().then(() => {
        this.flushScheduled = false
        try {
          this.publish()
        } catch (error) {
          this.log.error("publish.failed", { error })
        }
      }),
    )
  }

  private publish() {
    const env: QueryEnv = {
      core: this.coreResource(),
      account: this.phase === "ready" ? this.account : null,
    }
    const changes = this.pendingChanges
    this.pendingChanges = []
    const everything = this.recomputeAll
    this.recomputeAll = false
    for (const context of this.contexts) {
      context.queries.publish(env, changes, everything)
    }
    // The first ready result is out: background indexing may begin.
    if (env.account && this.account) this.account.search?.startSoon()
  }

  private track<T>(task: Promise<T>): Promise<T> {
    this.tasks.add(task)
    void task.then(
      () => this.tasks.delete(task),
      () => this.tasks.delete(task),
    )
    return task
  }
}
