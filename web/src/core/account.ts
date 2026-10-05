import type { AuthStore } from "@inline/auth/core"
import {
  Db,
  DbObjectKind,
  DbQueryPlanType,
  RealtimeClient,
  createIndexedDbPersistenceStore,
  getMe,
  messageKey,
  type Chat,
  type InlineClientContextValue,
  type RealtimeConnectionState,
  type RealtimeClientOptions,
} from "@inline/client/core"
import { getRealtimeUrl, getServerUrl, resolveRealtimeUrl } from "@inline/config"
import type { UserID } from "@inline/ids"
import { acquireAccountWriter, type AccountWriter } from "./account-writer"
import { BrowserLifecycle } from "./browser-lifecycle"
import { NavigationRefresh } from "./navigation-refresh"

export type AccountSnapshot = {
  phase: "loading" | "ready" | "waiting" | "error"
  connectionState: RealtimeConnectionState
  authUnavailable?: boolean
  error?: string
}

export type AccountOptions = {
  auth: AuthStore
  serverUrl?: string
  observeBrowserLifecycle?: boolean
  /** Transport injection for protocol/host qualification; normal browsers use WebSocket. */
  transport?: RealtimeClientOptions["transport"]
}

export const accountStorageNamespace = (accountId: UserID, serverUrl: string) =>
  `inline-web:${encodeURIComponent(serverUrl.replace(/\/+$/, ""))}:${accountId}`

/** One account cache, realtime client, and exclusive browser writer lifetime. */
export class Account {
  readonly auth: AuthStore
  readonly db: Db
  readonly realtime: RealtimeClient
  readonly client: InlineClientContextValue

  private snapshot: AccountSnapshot = { phase: "loading", connectionState: "idle" }
  private readonly listeners = new Set<() => void>()
  private readonly hasPersistence: boolean
  private readonly lifecycle: BrowserLifecycle | undefined
  private writer: AccountWriter | undefined
  private acquisition: AbortController | undefined
  private startTask: Promise<void> | undefined
  private stopTask: Promise<void> | undefined
  private detachConnection: (() => void) | undefined
  private detachAuth: (() => void) | undefined
  private running = false
  private generation = 0
  private closeFailure: Error | undefined
  private retired = false
  private connectionGeneration = 0
  private refreshTask: Promise<void> | undefined
  private retryTask: Promise<void> | undefined
  private refreshAgain = false
  private viewCleanup: { retire: () => void | Promise<void> } | undefined
  private viewDrain: Promise<void> = Promise.resolve()

  constructor(readonly accountId: UserID, options: AccountOptions) {
    this.auth = options.auth
    const serverUrl = options.serverUrl ?? getServerUrl()
    const persistenceStore = createIndexedDbPersistenceStore(
      accountStorageNamespace(accountId, serverUrl),
    )
    this.hasPersistence = persistenceStore != null
    this.db = new Db({ autoHydrate: false, persistenceStore })
    this.realtime = new RealtimeClient({
      auth: this.auth,
      db: this.db,
      url: options.serverUrl == null ? getRealtimeUrl() : resolveRealtimeUrl(serverUrl),
      transport: options.transport,
    })
    this.client = { auth: this.auth, db: this.db, realtime: this.realtime }
    if (options.observeBrowserLifecycle !== false) {
      this.lifecycle = new BrowserLifecycle(
        this.realtime.connection,
        (error) => {
          if (this.running) this.update({ error: errorMessage(error) })
        },
        () => { void this.stop().catch(() => undefined) },
      )
    }
  }

  getSnapshot = () => this.snapshot

  subscribe = (listener: () => void) => {
    this.listeners.add(listener)
    return () => { this.listeners.delete(listener) }
  }

  /** Retire one pane synchronously, then drain its accepted local work before close. */
  attachViewCleanup(cleanup: () => void | Promise<void>): () => void {
    if (!this.running || this.snapshot.phase !== "ready" || this.stopTask) {
      throw new Error("Cannot attach a view to an account that is closing.")
    }
    if (this.viewCleanup) throw new Error("This account already has a view owner.")
    const attachment = { retire: cleanup }
    this.viewCleanup = attachment
    return () => { if (this.viewCleanup === attachment) this.retireView() }
  }

  private retireView() {
    const attachment = this.viewCleanup
    if (!attachment) return
    this.viewCleanup = undefined
    let pending: Promise<void>
    try { pending = Promise.resolve(attachment.retire()) }
    catch (error) { pending = Promise.reject(error) }
    // Detached/HMR views lose their registration, never their accepted draft
    // tail. A later stop still owns this barrier, including its failure.
    this.viewDrain = Promise.allSettled([this.viewDrain, pending]).then((results) => {
      const failures = results.flatMap((result) => result.status === "rejected" ? [result.reason] : [])
      if (failures.length === 1) throw failures[0]
      if (failures.length > 1) throw new AggregateError(failures, "Inline view work could not drain")
    })
    // Preserve rejection for the account stop barrier without an unhandled
    // rejection during React's synchronous detach callback.
    void this.viewDrain.catch(() => undefined)
  }

  start(): Promise<void> {
    if (this.stopTask) return this.stopTask.then(() => this.start())
    if (this.closeFailure) return Promise.reject(this.closeFailure)
    if (this.retired) return Promise.reject(new Error("Create a new Inline account owner after closing its writer."))
    if (this.snapshot.phase === "error") return Promise.reject(new Error(this.snapshot.error))
    if (this.running) return this.startTask ?? Promise.resolve()
    this.running = true
    const generation = ++this.generation
    this.update({ phase: "loading", connectionState: "idle", authUnavailable: false, error: undefined })
    const task = this.bootstrap(generation)
    this.startTask = task
    void task.then(
      () => { if (this.startTask === task) this.startTask = undefined },
      () => { if (this.startTask === task) this.startTask = undefined },
    )
    return task
  }

  /** Retry a preserved session on the existing writer/cache, without discarding data. */
  retry(): Promise<void> {
    if (this.retryTask) return this.retryTask
    if (!this.running || this.snapshot.phase !== "ready" || !this.writer) {
      return Promise.reject(new Error("This account is not available for connection recovery."))
    }
    const task = this.recoverConnection(this.generation)
    this.retryTask = task
    const clear = () => { if (this.retryTask === task) this.retryTask = undefined }
    void task.then(clear, clear)
    return task
  }

  private async recoverConnection(generation: number) {
    const refreshConnected = this.realtime.connectionState === "connected"
    try {
      this.assertSession()
      if (this.snapshot.authUnavailable || this.realtime.connectionState === "idle") {
        await this.realtime.stop()
        if (!this.isCurrent(generation)) return
        this.assertSession()
      }
      this.update({ authUnavailable: false, error: undefined })
      await this.realtime.start()
      if (this.isCurrent(generation) && refreshConnected) await this.refresh(generation)
    } catch (error) {
      if (this.isCurrent(generation)) this.update({ authUnavailable: !this.realtime.connection.constraints.authAvailable, error: errorMessage(error) })
      throw error
    }
  }

  stop(): Promise<void> {
    if (this.stopTask) return this.stopTask
    if (this.closeFailure) return Promise.reject(this.closeFailure)
    this.running = false
    this.generation += 1
    this.acquisition?.abort()
    this.detachConnection?.()
    this.detachConnection = undefined
    this.detachAuth?.()
    this.detachAuth = undefined
    const errors: unknown[] = []
    this.retireView()
    const task = this.finishStop(errors)
    this.stopTask = task
    void task.then(
      () => { if (this.stopTask === task) this.stopTask = undefined },
      () => { if (this.stopTask === task) this.stopTask = undefined },
    )
    return task
  }

  private async bootstrap(generation: number) {
    try {
      await this.auth.ready
      if (!this.isCurrent(generation)) return
      this.assertSession()
      const sessionToken = this.auth.getToken()
      this.detachAuth = this.auth.subscribe((state) => {
        if (state.currentUserId !== this.accountId || state.token == null || state.token !== sessionToken) {
          void this.stop().catch(() => undefined)
        }
      })
      if (!this.hasPersistence) throw new Error("Inline requires IndexedDB to save messages on this browser.")
      const locks = typeof navigator === "undefined" ? undefined : navigator.locks
      if (!locks) throw new Error("Inline requires browser Web Locks. Open it in a supported browser over HTTPS.")
      const acquisition = new AbortController()
      this.acquisition = acquisition
      this.update({ phase: "waiting" })
      const writer = await acquireAccountWriter(locks, this.accountId, acquisition.signal)
      this.acquisition = undefined
      if (!this.isCurrent(generation)) { await writer.release(); return }
      this.writer = writer
      this.update({ phase: "loading" })
      await this.db.openPersistence()
      if (!this.isCurrent(generation)) return
      await this.db.hydrate()
      if (!this.isCurrent(generation)) return
      const chats = this.db.queryCollection<DbObjectKind.Chat, Chat, DbQueryPlanType.Objects>(
        DbQueryPlanType.Objects, DbObjectKind.Chat,
      )
      await this.db.hydrateObjects(
        DbObjectKind.Message,
        chats.flatMap((chat) => chat.lastMsgId == null ? [] : [messageKey(chat.id, chat.lastMsgId)]),
      )
      if (!this.isCurrent(generation)) return
      this.assertSession()
      this.detachConnection = this.realtime.onConnectionState((connectionState) => {
        if (!this.isCurrent(generation)) return
        ++this.connectionGeneration
        const authUnavailable = connectionState === "idle" && !this.realtime.connection.constraints.authAvailable
        this.update({
          connectionState, authUnavailable,
          ...(authUnavailable ? { error: "Inline could not authenticate this connection. Retry or sign in again. Your saved session and messages have been preserved." } : {}),
        })
        if (connectionState === "connected") {
          // Realtime's synchronous emitter runs before its session requeue.
          // Admit fresh queries after that requeue has captured the old work.
          queueMicrotask(() => {
            if (this.isCurrent(generation) && this.realtime.connectionState === "connected") void this.refresh(generation)
          })
        }
      })
      await this.lifecycle?.attach()
      if (!this.isCurrent(generation)) return
      // Display hydrated navigation without waiting for an online refresh.
      this.update({ phase: "ready" })
      await this.realtime.start()
    } catch (error) {
      if (!this.isCurrent(generation)) return
      this.update({ phase: "error", error: errorMessage(error) })
      throw error
    }
  }

  private refresh(generation: number): Promise<void> {
    if (this.refreshTask) { this.refreshAgain = true; return this.refreshTask }
    const task = this.performRefresh(generation)
    this.refreshTask = task
    const clear = () => { if (this.refreshTask === task) this.refreshTask = undefined }
    void task.then(clear, clear)
    return task
  }

  private async performRefresh(generation: number) {
    // One overlap/invalidated response may reschedule once. Busy traffic cannot
    // turn snapshot refresh into a retry loop; live sync keeps its authority.
    for (let attempt = 0; attempt < 2; attempt += 1) {
      this.refreshAgain = false
      const connectionGeneration = this.connectionGeneration
      const current = () => this.isCurrent(generation) && connectionGeneration === this.connectionGeneration && this.realtime.connectionState === "connected" && !this.snapshot.authUnavailable
      let discarded = false
      try {
        // Apply getMe before observing getChats, so our own bootstrap does not
        // invalidate its navigation snapshot.
        await this.realtime.query(getMe())
        if (!current()) discarded = true
        else {
          const refresh = new NavigationRefresh(current)
          try { await this.realtime.query(refresh) }
          finally { refresh.dispose() }
          discarded = refresh.discarded
        }
        if (current()) this.update({ error: discarded ? "Chats changed during refresh. Live updates remain active; retry to refresh the chat list." : undefined })
      } catch (error) {
        if (current()) this.update({ error: `Could not refresh chats: ${errorMessage(error)}` })
      }
      if (!(attempt === 0 && (discarded || this.refreshAgain) && this.isCurrent(generation) && this.realtime.connectionState === "connected")) break
    }
  }

  private async finishStop(errors: unknown[]) {
    await this.lifecycle?.detach()
    // An opening/hydrating owner must finish before its handles are closed.
    await this.startTask?.catch(() => undefined)
    try {
      await this.realtime.stop()
      // Stop settles queries a manual refresh may be awaiting. Recovery checks
      // the owner generation before it can restart after its own stop barrier.
      await this.retryTask?.catch(() => undefined)
      await this.refreshTask
    } catch (error) { errors.push(error) }
    try { await this.viewDrain } catch (error) { errors.push(error) }
    try { await this.db.closePersistence() } catch (error) { errors.push(error) }
    if (errors.length > 0) {
      this.closeFailure = new AggregateError(errors, "Inline could not safely close this account. Reload this page before reopening it.")
      // A failed drain must never permit another tab to become the writer.
      this.update({ phase: "error", connectionState: "idle", error: this.closeFailure.message })
      throw this.closeFailure
    }
    if (this.writer) {
      await this.writer.release()
      // Shared Db hydration is lifetime-cached. A new owner must re-read the
      // replica after another tab could have held the writer in between.
      this.retired = true
    }
    this.writer = undefined
    this.update({ phase: "loading", connectionState: "idle", authUnavailable: false, error: undefined })
  }

  private assertSession() {
    const session = this.auth.getState()
    if (session.currentUserId !== this.accountId || session.token == null) {
      throw new Error("The Inline session does not match this account.")
    }
  }

  private isCurrent(generation: number) {
    return this.running && generation === this.generation
  }

  private update(update: Partial<AccountSnapshot>) {
    const next = { ...this.snapshot, ...update }
    if (next.phase === this.snapshot.phase && next.connectionState === this.snapshot.connectionState && next.authUnavailable === this.snapshot.authUnavailable && next.error === this.snapshot.error) return
    this.snapshot = next
    for (const listener of this.listeners) listener()
  }
}

const errorMessage = (error: unknown) =>
  error instanceof Error ? error.message : "Inline could not complete this operation."
