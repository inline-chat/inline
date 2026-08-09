import {
  Db,
  DbObjectKind,
  DbQueryPlanType,
  RealtimeClient,
  TransactionFailure,
  getChats,
  getMe,
  messageKey,
  type Chat,
  type AuthSession,
  type AuthStore,
  type InlineClientContextValue,
  type InlinePersistenceStore,
  type RealtimeConnectionState,
} from "@inline/client/core"
import type { UserID } from "@inline/ids"
import { Log } from "@inline/log"
import {
  hydrateReplyThreadAnchors,
  refreshMissingReplyThreadAnchors,
} from "../data/reply-thread"
import { createInlineMediaCache } from "../media/cache/createInlineMediaCache"
import { InlineMediaLoader } from "../media/InlineMediaLoader"
import { InlineMediaRepository } from "../media/InlineMediaRepository"
import { BrowserConnectionLifecycle } from "../runtime/BrowserConnectionLifecycle"
import {
  INLINE_CORE_PROTOCOL_VERSION,
  type InlineCoreSnapshot,
} from "./InlineCoreProtocol"
import { InlineMessageDrafts } from "../drafts/InlineMessageDrafts"
import {
  createOwnedMessageReferenceLoader,
  InlineMessageReferences,
} from "../messages/InlineMessageReferences"
import {
  createOwnedFullChatProgressive,
  type FullChatProgressiveService,
} from "./FullChatProgressiveService"
import { createInlinePersistenceStore } from "../data/createInlinePersistenceStore"
import type {
  InlineCoreAccountOwnership,
  InlineCoreAccountOwnershipAcquirer,
} from "./InlineCoreAccountOwnership"

type SnapshotListener = () => void

export type InlineAccountCoreOptions = {
  auth: AuthStore
  observeBrowserLifecycle?: boolean
  mediaLoader?: InlineMediaLoader
  persistenceStore?: InlinePersistenceStore | null
  logger?: Log
  acquireAccountOwnership?: InlineCoreAccountOwnershipAcquirer
}

const makeOwnerId = () => {
  if (
    typeof crypto !== "undefined" &&
    "randomUUID" in crypto
  ) {
    return crypto.randomUUID()
  }
  return `inline-core-${Date.now()}-${Math.random()
    .toString(36)
    .slice(2)}`
}

const isStoppedTransactionFailure = (error: unknown) =>
  error instanceof TransactionFailure && error.kind === "stopped"

/**
 * The in-page implementation of an authenticated account core. React binds
 * to this owner but does not own database, realtime, bootstrap, or browser
 * lifecycle policy. The same facade can later sit behind a SharedWorker.
 */
export class InlineAccountCore {
  readonly accountId: UserID
  readonly ownerId: string
  readonly auth: AuthStore
  readonly db: Db
  readonly realtime: RealtimeClient
  readonly mediaLoader: InlineMediaLoader
  readonly mediaRepository: InlineMediaRepository
  readonly messageDrafts: InlineMessageDrafts
  readonly messageReferences: InlineMessageReferences
  readonly fullChatProgressive: FullChatProgressiveService
  readonly client: InlineClientContextValue

  private readonly hasDurablePersistence: boolean
  private readonly log: Log
  private readonly acquireAccountOwnership:
    | InlineCoreAccountOwnershipAcquirer
    | undefined
  private readonly browserLifecycle:
    | BrowserConnectionLifecycle
    | undefined
  private readonly listeners = new Set<SnapshotListener>()
  private snapshot: InlineCoreSnapshot
  private running = false
  private generation = 0
  private startTask: Promise<void> | null = null
  private stopTask: Promise<void> | null = null
  private detachBrowserLifecycle: (() => void) | null = null
  private unsubscribeConnection: (() => void) | null = null
  private ownership: InlineCoreAccountOwnership | undefined

  constructor(
    accountId: UserID,
    options: InlineAccountCoreOptions,
  ) {
    this.accountId = accountId
    this.ownerId = makeOwnerId()
    this.auth = options.auth
    this.log = options.logger ?? new Log("InlineAccountCore")
    this.acquireAccountOwnership = options.acquireAccountOwnership
    const persistenceStore =
      options.persistenceStore !== undefined
        ? options.persistenceStore
        : createInlinePersistenceStore({ accountId })
    this.hasDurablePersistence = persistenceStore != null
    this.db = new Db({
      autoHydrate: false,
      persistenceStore,
      logger: this.log.withScope("Database"),
    })
    this.realtime = new RealtimeClient({
      auth: this.auth,
      db: this.db,
      logger: this.log.withScope("Realtime"),
    })
    this.mediaLoader =
      options.mediaLoader ??
      new InlineMediaLoader({
        cache: createInlineMediaCache({ accountId }),
        logger: this.log.withScope("Media"),
      })
    this.mediaRepository = new InlineMediaRepository(
      this.mediaLoader,
    )
    this.messageDrafts = new InlineMessageDrafts(this.db)
    this.messageReferences = new InlineMessageReferences(
      createOwnedMessageReferenceLoader(this.db, this.realtime),
    )
    this.fullChatProgressive =
      createOwnedFullChatProgressive(this.db)
    this.client = {
      auth: this.auth,
      db: this.db,
      realtime: this.realtime,
    }
    this.browserLifecycle =
      options.observeBrowserLifecycle === false
        ? undefined
        : new BrowserConnectionLifecycle({
            connection: this.realtime.connection,
          })
    this.snapshot = {
      protocolVersion: INLINE_CORE_PROTOCOL_VERSION,
      ownerId: this.ownerId,
      accountId,
      phase: "idle",
      cacheReady: false,
      connectionState: "idle",
    }
  }

  getSnapshot = () => this.snapshot

  subscribe = (listener: SnapshotListener) => {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  reportExternalError(message: string) {
    this.updateSnapshot({
      phase: "error",
      blockingFailure: {
        code: "storage-unavailable",
        message,
        recoveryAction: "reload",
      },
    })
  }

  async updateSession(session: AuthSession) {
    if (session.userId !== this.accountId) {
      throw new Error(
        "Inline account core session does not match its account",
      )
    }
    await this.auth.login(session)
    await this.realtime.connection.setAuthAvailable(true)
  }

  start(): Promise<void> {
    if (this.stopTask) {
      return this.stopTask.then(() => this.start())
    }
    if (this.running) {
      return this.startTask ?? Promise.resolve()
    }
    if (this.snapshot.blockingFailure?.recoveryAction === "reload") {
      return Promise.reject(
        new Error(this.snapshot.blockingFailure.message),
      )
    }

    this.running = true
    this.log.info("core.start.requested", {
      generation: this.generation + 1,
    })
    const generation = ++this.generation
    this.detachBrowserLifecycle =
      this.browserLifecycle?.attach() ?? null
    this.unsubscribeConnection =
      this.realtime.onConnectionState((state) => {
        this.handleConnectionState(state, generation)
      })

    const task = this.bootstrap(generation)
    this.startTask = task
    const clearStartTask = () => {
      if (this.startTask === task) {
        this.startTask = null
      }
    }
    void task.then(clearStartTask, clearStartTask)
    return task
  }

  stop() {
    if (this.stopTask) return this.stopTask
    if (!this.running && this.snapshot.phase === "stopped") {
      return Promise.resolve()
    }
    this.running = false
    this.generation += 1
    this.detachBrowserLifecycle?.()
    this.detachBrowserLifecycle = null
    this.unsubscribeConnection?.()
    this.unsubscribeConnection = null
    this.mediaLoader.cancelAll()
    this.mediaRepository.clear()
    const task = this.finishStop()
    this.stopTask = task
    const clearStopTask = () => {
      if (this.stopTask === task) {
        this.stopTask = null
      }
    }
    void task.then(clearStopTask, clearStopTask)
    return task
  }

  private async finishStop() {
    const errors: unknown[] = []
    let persistenceClosed = false
    const startTask = this.startTask
    try {
      await this.realtime.stop()
    } catch (error) {
      errors.push(error)
    }
    if (startTask) {
      try {
        await startTask
      } catch (error) {
        if (!errors.includes(error)) errors.push(error)
      }
    }
    try {
      await this.messageDrafts.drain()
    } catch (error) {
      errors.push(error)
    }
    try {
      await this.db.closePersistence()
      persistenceClosed = true
    } catch (error) {
      errors.push(error)
    }
    const ownership = persistenceClosed
      ? this.ownership
      : undefined
    if (persistenceClosed) this.ownership = undefined
    if (ownership) {
      try {
        await ownership.release()
      } catch (error) {
        errors.push(error)
      }
    }
    this.updateSnapshot(
      persistenceClosed
        ? {
            phase: "stopped",
            connectionState: "idle",
          }
        : {
            phase: "error",
            connectionState: "idle",
            blockingFailure: {
              code: "storage-unavailable",
              message:
                "Inline could not safely close its local replica. Reload before reopening this account.",
              recoveryAction: "reload",
            },
          },
    )
    this.log.info("core.stopped", { errorCount: errors.length })
    if (errors.length === 1) throw errors[0]
    if (errors.length > 1) {
      throw new AggregateError(
        errors,
        "Inline account core could not stop cleanly",
      )
    }
  }

  private async bootstrap(generation: number) {
    if (!(await this.acquireOwnership(generation))) return
    try {
      this.updateSnapshot({
        phase: "openingStorage",
        blockingFailure: undefined,
        syncIssue: undefined,
      })
      if (!this.hasDurablePersistence) {
        throw new Error(
          "Inline requires durable browser storage to start.",
        )
      }
      await this.db.openPersistence()
      this.log.info("storage.open.ready", { generation })
      if (!this.isCurrent(generation)) return
      await this.db.hydrateKinds([
        DbObjectKind.User,
        DbObjectKind.Space,
        DbObjectKind.Chat,
        DbObjectKind.Dialog,
      ])
      if (!this.isCurrent(generation)) return

      this.updateSnapshot({ phase: "hydratingNavigation" })
      const cachedChats = this.db.queryCollection<
        DbObjectKind.Chat,
        Chat,
        DbQueryPlanType.Objects
      >(DbQueryPlanType.Objects, DbObjectKind.Chat)
      await Promise.all([
        this.db.hydrateObjects(
          DbObjectKind.Message,
          cachedChats.flatMap((chat) =>
            chat.lastMsgId == null
              ? []
              : [messageKey(chat.id, chat.lastMsgId)],
          ),
        ),
        hydrateReplyThreadAnchors(this.db, cachedChats),
      ])
      if (!this.isCurrent(generation)) return

      this.updateSnapshot({
        phase: "cacheReady",
        cacheReady: true,
      })
      this.log.info("runtime.cache.ready", { generation })
    } catch (error) {
      if (!this.isCurrent(generation)) return
      if (isStoppedTransactionFailure(error)) {
        this.updateSnapshot({
          phase: "cacheReady",
          connectionState: "idle",
          syncIssue: undefined,
        })
        this.log.debug("runtime.initial_sync.cancelled", {
          generation,
        })
        return
      }
      this.updateSnapshot({
        phase: "error",
        blockingFailure: {
          code: "storage-unavailable",
          message:
            error instanceof Error
              ? error.message
              : "Inline’s local cache could not open.",
          recoveryAction: "reload",
        },
      })
      this.log.error("storage.open.failed", {
        generation,
        error,
      })
      return
    }

    try {
      await this.realtime.start()
      if (!this.isCurrent(generation)) return

      this.updateSnapshot({ phase: "connecting" })
      void this.realtime.query(getMe()).catch(() => undefined)
      await this.realtime.query(getChats())
      if (!this.isCurrent(generation)) return

      const refreshedChats = this.db.queryCollection<
        DbObjectKind.Chat,
        Chat,
        DbQueryPlanType.Objects
      >(DbQueryPlanType.Objects, DbObjectKind.Chat)
      await hydrateReplyThreadAnchors(this.db, refreshedChats)
      await refreshMissingReplyThreadAnchors(
        this.db,
        this.realtime,
        refreshedChats,
      ).catch(() => undefined)
      if (!this.isCurrent(generation)) return

      this.updateSnapshot({
        phase: "ready",
        syncIssue: undefined,
      })
      this.log.info("runtime.sync.ready", { generation })
    } catch (error) {
      if (!this.isCurrent(generation)) return
      if (isStoppedTransactionFailure(error)) {
        this.updateSnapshot({
          phase: "cacheReady",
          connectionState: "idle",
          syncIssue: undefined,
        })
        this.log.debug("runtime.initial_sync.cancelled", {
          generation,
        })
        return
      }
      this.updateSnapshot({
        phase: "cacheReady",
        syncIssue: {
          code: "initial-sync-unavailable",
          message:
            error instanceof Error
              ? error.message
              : "Inline could not refresh yet.",
        },
      })
      this.log.warn("runtime.initial_sync.unavailable", {
        generation,
        error,
      })
    }
  }

  private async acquireOwnership(generation: number) {
    if (!this.acquireAccountOwnership || this.ownership) return true
    let ownership: InlineCoreAccountOwnership | null
    try {
      ownership = await this.acquireAccountOwnership(this.accountId)
    } catch (error) {
      if (!this.isCurrent(generation)) return false
      this.updateSnapshot({
        phase: "error",
        blockingFailure: {
          code: "owner-unavailable",
          message: "Inline could not acquire its browser storage lock.",
          recoveryAction: "reload",
        },
      })
      this.log.error("runtime.owner.acquire_failed", { error })
      return false
    }
    if (!this.isCurrent(generation)) {
      await ownership?.release().catch(() => undefined)
      return false
    }
    if (!ownership) {
      this.updateSnapshot({
        phase: "error",
        blockingFailure: {
          code: "owner-unavailable",
          message: "Inline is already open in another tab.",
          recoveryAction: "reload",
        },
      })
      this.log.warn("runtime.owner.unavailable")
      return false
    }
    this.ownership = ownership
    this.log.info("runtime.owner.acquired")
    return true
  }

  private handleConnectionState(
    connectionState: RealtimeConnectionState,
    generation: number,
  ) {
    if (!this.isCurrent(generation)) return
    const phase =
      connectionState === "connected"
        ? this.snapshot.phase === "ready"
          ? "ready"
          : "syncing"
        : connectionState === "connecting" &&
            this.snapshot.cacheReady
          ? "connecting"
          : this.snapshot.phase
    this.updateSnapshot({ connectionState, phase })
  }

  private isCurrent(generation: number) {
    return this.running && generation === this.generation
  }

  private updateSnapshot(
    update: Partial<InlineCoreSnapshot>,
  ) {
    const next = { ...this.snapshot, ...update }
    if (
      next.phase === this.snapshot.phase &&
      next.cacheReady === this.snapshot.cacheReady &&
      next.connectionState === this.snapshot.connectionState &&
      next.blockingFailure?.code ===
        this.snapshot.blockingFailure?.code &&
      next.blockingFailure?.message ===
        this.snapshot.blockingFailure?.message &&
      next.blockingFailure?.recoveryAction ===
        this.snapshot.blockingFailure?.recoveryAction &&
      next.syncIssue?.code === this.snapshot.syncIssue?.code &&
      next.syncIssue?.message === this.snapshot.syncIssue?.message
    ) {
      return
    }
    this.snapshot = next
    for (const listener of this.listeners) listener()
  }
}
