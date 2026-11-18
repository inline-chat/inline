/**
 * Everything one signed-in session owns: the replica (`Db` on the injected
 * store), the realtime client, an in-memory auth store, message identity,
 * chat windows. Created by `CoreHost` on `session start` and dropped on
 * sign-out or shutdown.
 */
import { Method } from "@inline-chat/protocol/core"
import type { ConnectionState, StorageState, SyncStall } from "@inline/core-protocol"
import type { ChatID, MessageID, SpaceID, UserID } from "@inline/ids"
import { Log } from "@inline/log"
import { AuthStore, type AuthSession } from "../auth"
import { Db, type DbResidentChangeBatch } from "../database"
import {
  DbObjectKind,
  messageKey,
  MessageSendingStatus,
  type Chat,
  type Message,
  type MessageKey,
  type PendingTransaction,
} from "../database/models"
import { DbQueryPlanType } from "../database/types"
import type { InlinePersistenceStore } from "../database/persistence"
import { isInlineSqliteSchemaTooNew } from "../database/sqlite/schema"
import type { QueryAccount } from "../queries/compute"
import { CommittedView, VIEW_KINDS, type ReplicaView } from "../queries/view"
import { RealtimeClient, type RealtimeClientOptions } from "../realtime/realtime"
import type { SyncEngine } from "../realtime/sync"
import { logOutOnServer } from "../realtime/transactions/log-out-rpc"
import { getChatParticipants, getSpaceMembers, getUserSettings } from "../realtime/transactions"
import {
  deleteHostRecord,
  hostRecordPayload,
  hostRecords,
  resumeHostRecords,
  SEND_TX_RECORD,
} from "./durable"
import { decodeSettingsRecord } from "./settings-intents"
import { decodeParticipantRecord } from "./participants"
import { HostChatMedia } from "./chat-media"
import { HostRemoteSearch } from "./remote-search"
import type {
  ComposeActionKind,
  ComposeActivity,
  MessageRow,
  QueryDescriptor,
  ResourceValue,
  TxId,
} from "@inline/core-protocol"
import {
  MediaCore,
  MediaError,
  type ByteStore,
  type ImagePreparer,
  type MediaAsset,
  type MediaClock,
  type MediaFetch,
  type MediaRpcCall,
  type MediaSettings,
} from "../media"
import { AttachmentCoordinator } from "./attachments"
import { defaultByteStore } from "./erase"
import { ComposeActivityStore } from "./compose"
import { HostMedia } from "./media"
import { HostSearch } from "./search"
import { sendComposeAction } from "../realtime/transactions/send-compose-action"
import { getMessages } from "../realtime/transactions"
import { inputPeerForChat } from "./peers"
import type { Transport } from "../realtime/transport/transport"
import { draftFor } from "./drafts"
import { MessageIdentity } from "./message-identity"
import { NewMessageFeed } from "./new-messages"
import { OverlayView, PendingOverlay } from "./overlay"
import { HostSyncEngine, stalledSync } from "./sync-health"
import { TrackedStore } from "./tracked-store"
import { ChatWindows } from "./windows"
import { hasErrorNamed } from "./errors"

/** The account's storage, opened by whoever knows the platform (worker, Node test). */
export type HostStorage = {
  store: InlinePersistenceStore
  /** `memory` when nothing survives a reload (no OPFS). */
  kind: "persistent" | "memory"
  /** Delete the replica. Called after the store is closed, on sign-out and revocation. */
  erase(): Promise<void>
}

export type HostRealtimeOptions = Pick<
  RealtimeClientOptions,
  "url" | "buildNumber" | "layer" | "sync" | "connection" | "logLevel"
>

/** The replica was written by a newer schema (invariant 9). */
export class OutdatedReplicaError extends Error {
  constructor(options?: ErrorOptions) {
    super("Inline replica was written by a newer build", options)
    this.name = "OutdatedReplicaError"
  }
}


export type BrowserFacts = { online: boolean; visible: boolean }

/**
 * The account's media core. Defaults: an OPFS byte store where the platform
 * has one, else memory; `globalThis.fetch`; RPCs over the realtime socket.
 */
export type HostMediaConfig = {
  /** Byte store for an account (all of it lives under `accounts/<accountKey>/media/`). */
  store?: (userId: UserID) => ByteStore
  /** Path-safe key of the account's media directory. Default `u<userId>`. */
  accountKey?: (userId: UserID) => string
  fetch?: MediaFetch
  /** Replaces the realtime socket for media RPCs (tests). */
  rpc?: MediaRpcCall
  imagePreparer?: ImagePreparer
  clock?: MediaClock
  /** The web has no synced media settings yet: auto-download limits and cache budget. */
  settings?: MediaSettings
}


export type AccountCoreOptions = {
  session: AuthSession
  storage: HostStorage
  transport?: Transport
  realtime?: HostRealtimeOptions
  logger: Log
  pageSize: number
  facts: BrowserFacts
  onChanges: (batch: DbResidentChangeBatch) => void
  onWindowChange: (chatId: ChatID) => void
  /** Connection or storage state changed. */
  onState: () => void
  /** The server revoked the session. */
  onRevoked: () => void
  /**
   * Something queries read changed outside the replica's commits: an
   * intent overlay on these messages, or the new-message feed.
   */
  onDisplayChange?: (change: { messageKeys?: readonly string[]; feed?: boolean }) => void
  /** How long after the first ready publish the search backfill starts. Default 1000 ms. */
  searchStartDelayMs?: number
  /** `false`: no media core (no media queries, no attachments). */
  media?: HostMediaConfig | false
  /** The state behind a handled subscription (media, search) changed. */
  onHandleChange?: (handle: number) => void
  /** Incoming compose activity changed in this chat. */
  onComposeChange?: (chatId: ChatID) => void
  /** A roster fetch started or ended (`chatParticipants`, `spaceMembers`). */
  onRosterChange?: (scope: "chat" | "space", id: string) => void
  /** Milliseconds since the epoch. */
  now?: () => number
  track: <T>(task: Promise<T>) => Promise<T>
}

export class AccountCore implements QueryAccount {
  readonly userId: UserID
  readonly identity = new MessageIdentity()
  /** Committed state, fed only by the resident-change stream. */
  readonly committed = new CommittedView()
  /** Display overlays of intents that are not replay-safe (edit, delete). */
  readonly overlay = new PendingOverlay()
  /** What queries read: the committed state with the overlays applied. */
  readonly view: ReplicaView
  /** Incoming messages that arrived live (the `newMessages` query). */
  readonly feed: NewMessageFeed
  /** The sync engine when the host built it (absent with `sync: false` or an injected engine). */
  readonly hostSync: HostSyncEngine | undefined
  readonly store: TrackedStore
  readonly db: Db
  readonly auth: AuthStore
  readonly realtime: RealtimeClient
  readonly windows: ChatWindows
  readonly storage: HostStorage
  /** Media: the core, what subscriptions show, and attachment sends. Set once started. */
  media: HostMedia | undefined
  sends: AttachmentCoordinator | undefined
  readonly compose: ComposeActivityStore
  /** Local message search, once the replica is open (absent on a memory store). */
  search: HostSearch | undefined
  /** `chatMedia` subscriptions' server pages. */
  readonly chatMedia: HostChatMedia
  /** Server search subscriptions (`searchServerMessages`, `searchUsers`). */
  readonly remoteSearch: HostRemoteSearch
  /** The UI's transaction IDs of `sendText`s in the outbox, by client key (`MessageRow.tx`). */
  private readonly sendTxs = new Map<string, { tx: TxId; recordId: string }>()
  private storageFull = false
  private stopping = false
  /** Signing out: a token cleared by the server's logout is not a revocation. */
  private leaving = false
  private readonly detach: Array<() => void> = []
  private readonly watchers = new Set<() => boolean>()
  /** Roster fetches of this session, by `${scope}:${id}`. */
  private readonly rosters = new Map<string, { loading: boolean; failed: boolean }>()
  private settingsRequested = false
  /** Per-message chains that keep non-replayable mutations in order. */
  readonly chains = new Map<string, Promise<unknown>>()

  private constructor(private readonly options: AccountCoreOptions) {
    this.userId = options.session.userId
    this.storage = options.storage
    this.view = new OverlayView(this.committed, this.overlay)
    const now = options.now ?? Date.now
    this.feed = new NewMessageFeed({
      userId: this.userId,
      now,
      onChange: () => options.onDisplayChange?.({ feed: true }),
    })
    this.store = new TrackedStore(options.storage.store, (error) => {
      const full = error != null && hasErrorNamed(error, "QuotaExceededError")
      // Any successful write shows space is available again.
      if (full !== this.storageFull && (full || error == null)) {
        this.storageFull = full
        options.onState()
      }
    })
    this.db = new Db({
      persistenceStore: this.store,
      autoHydrate: false,
      logger: options.logger.withScope("Database"),
    })
    this.auth = new AuthStore({ persistence: "memory" })
    const injectedSync = options.realtime?.sync
    this.hostSync =
      injectedSync === undefined
        ? new HostSyncEngine({
            db: this.db,
            client: () => this.realtime.client,
            logger: options.logger.withScope("Sync"),
            onDelivered: (updates) => {
              this.feed.noteDelivered(updates)
              this.compose.observe(updates)
            },
            onStallsChanged: () => options.onState(),
          })
        : undefined
    this.realtime = new RealtimeClient({
      ...options.realtime,
      ...(this.hostSync ? { sync: this.hostSync } : {}),
      auth: this.auth,
      db: this.db,
      logger: options.logger.withScope("Realtime"),
      ...(options.transport ? { transport: options.transport } : {}),
    })
    this.compose = new ComposeActivityStore({
      userId: this.userId,
      now,
      send: (chatId, action) =>
        this.realtime.execute(
          sendComposeAction({ peerId: inputPeerForChat(this.db, chatId), ...(action != null ? { action } : {}) }),
        ),
      chatForUser: (userId) =>
        this.committed.all(DbObjectKind.Dialog).find((dialog) => dialog.peerUserId === userId)?.chatId ??
        this.committed.all(DbObjectKind.Chat).find((chat) => chat.peerUserId === userId)?.id,
      onChange: (chatId) => options.onComposeChange?.(chatId),
    })
    const online = () => this.realtime.connectionState === "connected"
    this.chatMedia = new HostChatMedia({
      db: this.db,
      realtime: this.realtime,
      online,
      onChange: (handle) => options.onHandleChange?.(handle),
      track: options.track,
      log: options.logger.withScope("ChatMedia"),
    })
    this.remoteSearch = new HostRemoteSearch({
      db: this.db,
      realtime: this.realtime,
      userId: this.userId,
      online,
      onChange: (handle) => options.onHandleChange?.(handle),
      track: options.track,
      log: options.logger.withScope("RemoteSearch"),
    })
    this.windows = new ChatWindows({
      db: this.db,
      realtime: this.realtime,
      pageSize: options.pageSize,
      logger: options.logger.withScope("Windows"),
      onChange: options.onWindowChange,
      track: options.track,
    })
  }

  /** Open storage, hydrate, start realtime. Throws `OutdatedReplicaError` for a newer replica. */
  static async open(options: AccountCoreOptions): Promise<AccountCore> {
    const core = new AccountCore(options)
    try {
      await core.start()
      return core
    } catch (error) {
      await core.stop().catch(() => undefined)
      throw error
    }
  }

  private async start() {
    const { db, realtime, options } = this
    this.detach.push(
      db.subscribeToResidentChanges((batch) => {
        const inserted = this.feed.insertedCandidates(batch, this.committed)
        this.committed.apply(batch)
        this.identity.observe(batch)
        // A send left the outbox (landed, cancelled): its transaction ID record goes too.
        if (
          this.sendTxs.size > 0 &&
          batch.changes.some((change) => change.kind === DbObjectKind.PendingTransaction && change.object == null)
        ) {
          void options.track(this.forgetSendTxs())
        }
        this.runWatchers()
        options.onChanges(batch)
        this.feed.admit(inserted, this.committed)
        if (this.media) {
          const messages = new Set<string>()
          for (const change of batch.changes) {
            if (change.kind === DbObjectKind.Message) messages.add(String(change.id))
          }
          if (messages.size > 0) this.media.messagesChanged(messages)
        }
      }),
    )
    this.committed.load(db.residentSnapshot(VIEW_KINDS))
    try {
      await db.openPersistence()
    } catch (error) {
      if (isInlineSqliteSchemaTooNew(error)) throw new OutdatedReplicaError({ cause: error })
      throw error
    }
    await db.hydrate()
    this.search = new HostSearch({
      db,
      view: this.committed,
      onChange: (handle) => options.onHandleChange?.(handle),
      onStatus: () => options.onState(),
      startDelayMs: options.searchStartDelayMs ?? 1_000,
      log: options.logger.withScope("Search"),
    })
    if (!this.search.engine) this.search = undefined
    await db.hydrateKinds([DbObjectKind.MessageDraft])
    await this.hydrateLastMessages()
    await this.openMedia()

    this.detach.push(
      realtime.onConnectionState((state) => {
        this.media?.setOnline(state === "connected")
        this.chatMedia.setOnline(state === "connected")
        if (state !== "connected") this.compose.clearIncoming()
        options.onState()
      }),
    )
    this.detach.push(
      this.auth.subscribe((state) => {
        if (state.token == null && !this.stopping && !this.leaving) options.onRevoked()
      }),
    )
    // Browser facts that arrived before the session started.
    if (!options.facts.online) await realtime.connection.setNetworkAvailable(false)
    if (!options.facts.visible) await realtime.connection.setAppActive(false)
    await realtime.startSession(options.session)
    // Host-owned durable intents the realtime outbox cannot restore.
    await resumeHostRecords({
      db,
      auth: this.auth,
      realtime,
      decode: (payload) => decodeSettingsRecord(payload) ?? decodeParticipantRecord(payload),
      skip: (payload) => payload.kind === "mediaSend" || payload.kind === SEND_TX_RECORD,
      onError: (error) => options.logger.warn("host.record.resume.failed", { error }),
    })
    await this.sends?.resume()
    // The outbox is restored: keep the transaction IDs of sends still in it.
    for (const record of hostRecords(db)) {
      const payload = hostRecordPayload(record)
      const context = payload?.context as { clientKey?: unknown } | undefined
      if (payload?.kind !== SEND_TX_RECORD || typeof payload.tx !== "string" || typeof context?.clientKey !== "string") {
        continue
      }
      this.sendTxs.set(context.clientKey, { tx: payload.tx, recordId: record.id })
    }
    await this.forgetSendTxs()
  }

  /** A `sendText`'s transaction ID committed with its outbox entry. */
  rememberSendTx(clientKey: string, tx: TxId, recordId: string) {
    this.sendTxs.set(clientKey, { tx, recordId })
  }

  /**
   * Drop the transaction ID records of sends no longer in the outbox (landed,
   * cancelled). One commit; nothing to do when every record still names one.
   */
  async forgetSendTxs() {
    if (this.sendTxs.size === 0 || this.stopping) return
    const live = new Set<string>()
    for (const record of this.db.queryCollection<DbObjectKind.PendingTransaction, PendingTransaction, DbQueryPlanType.Objects>(
      DbQueryPlanType.Objects,
      DbObjectKind.PendingTransaction,
      (candidate) => candidate.type === "send_message",
    )) {
      const randomId = (record.context as { randomId?: unknown } | undefined)?.randomId
      if (typeof randomId === "bigint") live.add(randomId.toString())
    }
    const gone = Array.from(this.sendTxs).filter(([clientKey]) => !live.has(clientKey))
    if (gone.length === 0) return
    for (const [clientKey] of gone) this.sendTxs.delete(clientKey)
    try {
      await this.db.commit(() => {
        for (const [, entry] of gone) deleteHostRecord(this.db, entry.recordId)
      })
    } catch (error) {
      // A stale record only names a transaction; the next sweep retries.
      this.options.logger.warn("sendTx.forget.failed", { error })
    }
  }

  /** `MessageRow.tx`: the UI's transaction ID of a send from this device still in the outbox. */
  sendTx(message: Message): TxId | undefined {
    if (message.randomId == null || message.status === MessageSendingStatus.Sent) return undefined
    const clientKey = message.randomId.toString()
    return this.sendTxs.get(clientKey)?.tx ?? this.sends?.txFor(clientKey)
  }

  /** A `chatMedia` subscription's server pages and paging state. */
  chatMediaState(handle: number) {
    return this.chatMedia.state(handle)
  }

  /**
   * Open a subscription the host answers itself (other than media and local
   * search). Resolves when its first result can be published (`chatMedia`:
   * after the device's first matches are read from disk).
   */
  openHandled(handle: number, query: QueryDescriptor): Promise<void> {
    if (query.kind === "chatMedia") return this.chatMedia.open(handle, query)
    if (query.kind === "searchServerMessages" || query.kind === "searchUsers") this.remoteSearch.open(handle, query)
    return Promise.resolve()
  }

  closeHandled(handle: number) {
    this.chatMedia.close(handle)
    this.remoteSearch.close(handle)
  }

  /**
   * The server refused a change to this chat's participants: mark the roster
   * incomplete (done by the transaction) and fetch it again now.
   */
  refreshRoster(chatId: ChatID) {
    if (this.stopping) return
    this.rosters.delete(`chat:${chatId}`)
    this.ensureRoster("chat", chatId, { force: true })
  }

  private async openMedia() {
    const config = this.options.media
    if (config === false) return
    const store = config?.store?.(this.userId) ?? defaultByteStore()
    const rpc: MediaRpcCall =
      config?.rpc ??
      ((method, input, signal) =>
        new Promise((resolve, reject) => {
          if (signal?.aborted) {
            reject(signal.reason ?? new MediaError("canceled", "aborted"))
            return
          }
          // The media core bounds every call itself; an abort settles it and
          // a late reply is dropped.
          const onAbort = () => reject(signal?.reason ?? new MediaError("canceled", "aborted"))
          signal?.addEventListener("abort", onAbort, { once: true })
          this.realtime.client.callRpc(method, input, { timeoutMs: 0 }).then(
            (value) => {
              signal?.removeEventListener("abort", onAbort)
              resolve(value)
            },
            (error: unknown) => {
              signal?.removeEventListener("abort", onAbort)
              reject(error)
            },
          )
        }))
    const core = await MediaCore.open({
      accountKey: config?.accountKey?.(this.userId) ?? `u${this.userId}`,
      rpc,
      fetch: config?.fetch ?? ((input, init) => globalThis.fetch(input, init)),
      store,
      ...(config?.clock ? { clock: config.clock } : {}),
      ...(config?.settings ? { settings: config.settings } : {}),
      ...(config?.imagePreparer ? { imagePreparer: config.imagePreparer } : {}),
      refreshUrl: (asset, stale) => this.refreshMediaUrl(asset, stale),
      log: this.options.logger.withScope("Media"),
    })
    core.setOnline(false)
    this.sends = new AttachmentCoordinator({
      db: this.db,
      auth: this.auth,
      realtime: this.realtime,
      identity: this.identity,
      media: core,
      store,
      userId: this.userId,
      ...(config?.imagePreparer ? { imagePreparer: config.imagePreparer } : {}),
      now: this.options.now ?? Date.now,
      onChange: (attachmentId) => this.media?.attachmentChanged(attachmentId),
      track: this.options.track,
      serialize: (chain, task) => this.serialize(chain, task),
      log: this.options.logger.withScope("Attachments"),
    })
    this.media = new HostMedia({
      media: core,
      view: this.committed,
      attachment: (id) => this.sends?.attachment(id),
      want: (keys) => this.wantMessages(keys as MessageKey[]),
      onChange: (handle) => this.options.onHandleChange?.(handle),
      log: this.options.logger.withScope("HostMedia"),
    })
  }

  /**
   * A signed media URL was rejected (expired): fetch the message again
   * (`GET_MESSAGES`), which commits its fresh URLs into the replica (so rows
   * carry them from then on), and hand the downloader the new one.
   */
  private async refreshMediaUrl(
    asset: MediaAsset,
    stale: string,
  ): Promise<string | undefined> {
    const location = asset.message
    if (!location || this.stopping) return undefined
    const chatId = String(location.chatId) as ChatID
    try {
      await this.realtime.execute(
        getMessages({
          peerId: inputPeerForChat(this.db, chatId),
          messageIds: [String(location.messageId) as MessageID],
        }),
      )
    } catch (error) {
      this.options.logger.warn("media.url.refresh.failed", { error })
      return undefined
    }
    return this.media?.freshUrl(asset, stale, this.committed)
  }

  /** The resource of a handled subscription (media, search). */
  handleResource(handle: number): ResourceValue | undefined {
    return this.media?.resource(handle) ?? this.search?.resource(handle) ?? this.remoteSearch.resource(handle)
  }

  composeActivities(chatId?: ChatID): readonly ComposeActivity[] {
    return this.compose.activities(chatId)
  }

  setComposeAction(chatId: ChatID, action: ComposeActionKind | null) {
    this.compose.set(chatId, action)
  }

  localUpload(message: Message): MessageRow["upload"] {
    return this.sends?.localUpload(message)
  }

  /** Fetch state of a roster in this session. */
  roster(scope: "chat" | "space", id: string) {
    return this.rosters.get(`${scope}:${id}`) ?? { loading: false, failed: false }
  }

  /**
   * Fetch a chat's participants or a space's members once per session when
   * the replica does not hold a complete list (first subscribe). The result
   * commits into the replica; the subscription follows it from there.
   */
  ensureRoster(scope: "chat" | "space", id: string, options: { force?: boolean } = {}) {
    const key = `${scope}:${id}`
    const known = this.rosters.get(key)
    // Once per session; a failed fetch is tried again by the next subscribe.
    if ((known && !known.failed) || this.stopping) return
    const complete =
      scope === "chat"
        ? this.committed.get(DbObjectKind.Chat, id)?.participantRosterComplete === true
        : this.committed.get(DbObjectKind.Space, id)?.memberRosterComplete === true
    if (complete && !options.force) return
    const state = { loading: true, failed: false }
    this.rosters.set(key, state)
    this.options.onRosterChange?.(scope, id)
    const transaction =
      scope === "chat"
        ? getChatParticipants({ chatId: id as ChatID })
        : getSpaceMembers({ spaceId: id as SpaceID })
    void this.options.track(
      this.realtime.execute(transaction).then(
        () => {
          state.loading = false
          this.options.onRosterChange?.(scope, id)
        },
        (error: unknown) => {
          state.loading = false
          state.failed = true
          this.options.logger.warn("roster.fetch.failed", { scope, error })
          this.options.onRosterChange?.(scope, id)
        },
      ),
    )
  }

  /** Fetch the account's settings once per session when the replica has none. */
  ensureSettings() {
    if (this.settingsRequested || this.stopping) return
    this.settingsRequested = true
    if (this.committed.get(DbObjectKind.UserSettings, "0")) return
    void this.options.track(
      this.realtime.execute(getUserSettings()).catch((error: unknown) => {
        this.settingsRequested = false
        this.options.logger.warn("settings.fetch.failed", { error })
      }),
    )
  }

  /**
   * Make each chat's last message resident, so the sidebar's first result
   * carries its previews. One indexed read; a missing row is left out.
   */
  async hydrateLastMessages(chatIds?: readonly ChatID[]) {
    const keys: MessageKey[] = []
    const chats: Chat[] = chatIds
      ? chatIds.flatMap((id) => {
          const chat = this.db.get(this.db.ref(DbObjectKind.Chat, id))
          return chat ? [chat] : []
        })
      : this.db.queryCollection<DbObjectKind.Chat, Chat, DbQueryPlanType.Objects>(
          DbQueryPlanType.Objects,
          DbObjectKind.Chat,
          () => true,
        )
    for (const chat of chats) {
      if (chat.lastMsgId == null) continue
      const key = messageKey(chat.id, chat.lastMsgId)
      if (this.db.get(this.db.ref(DbObjectKind.Message, key)) == null) keys.push(key)
    }
    if (keys.length > 0) await this.db.hydrateObjects(DbObjectKind.Message, keys)
  }

  private readonly requestedLastMessages = new Set<string>()

  /**
   * A query needs these messages and they are not resident: read them from
   * disk once (a missing row stays missing; no retry loop).
   */
  wantMessages(keys: readonly MessageKey[]) {
    const wanted = keys.filter((key) => !this.requestedLastMessages.has(key))
    if (wanted.length === 0 || this.stopping) return
    for (const key of wanted) this.requestedLastMessages.add(key)
    if (this.requestedLastMessages.size > 10_000) this.requestedLastMessages.clear()
    void this.options.track(
      this.db.hydrateObjects(DbObjectKind.Message, wanted).catch((error: unknown) => {
        this.options.logger.warn("messages.hydrate.failed", { error })
      }),
    )
  }

  /**
   * Evaluate `check` now and after every committed batch (before it is
   * published) until it returns true or the returned function is called.
   */
  watch(check: () => boolean): () => void {
    if (this.stopping || check()) return () => undefined
    this.watchers.add(check)
    return () => {
      this.watchers.delete(check)
    }
  }

  private runWatchers() {
    for (const check of Array.from(this.watchers)) {
      try {
        if (check()) this.watchers.delete(check)
      } catch (error) {
        this.watchers.delete(check)
        this.options.logger.error("watch.failed", { error })
      }
    }
  }

  /** Run `task` after every earlier task on the same chain has settled. */
  serialize<T>(chain: string, task: () => Promise<T>): Promise<T> {
    const previous = this.chains.get(chain) ?? Promise.resolve()
    const next = previous.then(task, task)
    const settled = next.catch(() => undefined)
    this.chains.set(chain, settled)
    void settled.then(() => {
      if (this.chains.get(chain) === settled) this.chains.delete(chain)
    })
    return next
  }

  newMessages(since: number): readonly string[] {
    return this.feed.since(since)
  }

  /** Sync scopes that stopped retrying. */
  syncStalls(): SyncStall[] | undefined {
    const sync: SyncEngine | undefined = this.realtime.sync
    const stalls = sync?.stalledBuckets() ?? []
    return stalls.length > 0 ? stalledSync(stalls, this.committed) : undefined
  }

  /** Retry stalled sync scopes now. */
  retrySync() {
    this.realtime.sync?.retryStalledBuckets()
    this.options.onState()
  }

  /** Recompute queries that read these messages (an overlay changed). */
  displayChanged(messageKeys: readonly string[]) {
    this.options.onDisplayChange?.({ messageKeys })
  }

  /**
   * Tell the server this session is over (`LOG_OUT`), waiting at most
   * `timeoutMs`. Offline, or on any failure, it returns at once: sign-out
   * always completes locally. The token the server clears is not a
   * revocation.
   */
  async logOutOnServer(timeoutMs: number): Promise<"loggedOut" | "skipped" | "failed"> {
    this.leaving = true
    if (this.realtime.connectionState !== "connected") return "skipped"
    try {
      return (await logOutOnServer(this.realtime, timeoutMs)) ? "loggedOut" : "failed"
    } catch (error) {
      this.options.logger.warn("session.logout.failed", { error })
      return "failed"
    }
  }

  /**
   * Hand `LOG_OUT` to the open connection now, without the outbox, and
   * return its answer (at most `timeoutMs`; offline: `skipped`). Sign-out
   * does not wait for it: the erase starts at once, and the frame already
   * handed to the socket goes out before the socket closes. Best-effort: a
   * session the server never heard about ends when its token is revoked.
   */
  sendLogOut(timeoutMs: number): Promise<"loggedOut" | "skipped" | "failed"> {
    this.leaving = true
    if (this.realtime.connectionState !== "connected") return Promise.resolve("skipped")
    return this.realtime.client
      .callRpc(Method.LOG_OUT, { oneofKind: "logOut", logOut: {} }, { timeoutMs })
      .then(
        (answer) => (answer?.oneofKind === "logOut" && answer.logOut.loggedOut ? "loggedOut" : "failed"),
        () => "failed" as const,
      )
  }

  get isStorageFull() {
    return this.storageFull
  }

  storageState(): StorageState {
    if (this.storageFull) return "full"
    return this.storage.kind
  }

  connectionState(): ConnectionState {
    const state = this.realtime.connectionState
    if (state !== "connected" && !this.realtime.connection.constraints.networkAvailable) {
      return "waitingForNetwork"
    }
    return state
  }

  clientKeyFor(message: Message) {
    return this.identity.clientKeyFor(message)
  }

  windowState(chatId: ChatID) {
    return this.windows.state(chatId)
  }

  draftFor(chatId: ChatID) {
    return draftFor(this.view, chatId)
  }

  windowKeys(chatId: ChatID) {
    return this.db.fullChatWindows.keys(chatId)
  }

  windowAtLatest(chatId: ChatID) {
    const windows = this.db.fullChatWindows
    return windows.isActive(chatId) ? windows.isAtLatest(chatId) : true
  }

  /**
   * Stop realtime and close the replica without deleting it. Accepted local
   * commits are flushed first (`Db.closePersistence`).
   */
  async stop(options: { erase?: boolean } = {}): Promise<void> {
    if (this.stopping) return
    this.stopping = true
    this.feed.stop()
    this.compose.stop()
    this.chatMedia.stop()
    this.remoteSearch.stop()
    this.sends?.stop()
    this.overlay.clear()
    this.watchers.clear()
    const errors: unknown[] = []
    try {
      await this.realtime.stop()
    } catch (error) {
      errors.push(error)
    }
    this.windows.closeAll()
    try {
      // Sign-out erases this account's jobs, staged sources and cache (invariant 10).
      await this.media?.stop({ erase: options.erase === true })
    } catch (error) {
      errors.push(error)
    }
    try {
      await this.auth.logout()
    } catch (error) {
      errors.push(error)
    }
    this.auth.dispose()
    try {
      // A read after close would reopen the replica: the engine stops first.
      await this.search?.stop()
    } catch (error) {
      errors.push(error)
    }
    try {
      await this.db.closePersistence()
    } catch (error) {
      errors.push(error)
    }
    for (const detach of this.detach.splice(0)) detach()
    if (errors.length > 0) {
      this.options.logger.warn("account.stop.unclean", { count: errors.length })
    }
  }
}
