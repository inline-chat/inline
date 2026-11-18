import {
  messageId,
  parseInlineId,
  type ChatID,
  type MessageID,
} from "@inline/ids"
import { Log } from "@inline/log"
import {
  type DbModel,
  DbModels,
  DbObjectKind,
  MessageSendingStatus,
  type MessageKey,
} from "./models"
import { FullChatWindowState } from "./full-chat-window"
import type {
  ChatMessageScan,
  ChatMessageScanOptions,
  InlinePersistenceCollection,
  InlinePersistenceOperation,
  InlinePersistenceStore,
} from "./persistence"
import { type DbObjectId, DbObjectRef, DbQueryPlan, DbQueryPlanType } from "./types"
import {
  compareMessagesByWindow,
  parseMessageWindowCursor,
  type MessageWindowCursor,
} from "./message-window"
import {
  certifiedRangeAt,
  certifyRanges,
  coverageModelRanges,
  coverageRanges,
  HISTORY_TOP,
  type HistoryRange,
} from "./history-coverage"
import {
  DbReadAdmission,
  dbObjectKey,
  type DbReadStamp,
} from "./read-admission"

export type DbStorageByKind = Partial<{
  [K in DbObjectKind]: InlinePersistenceCollection<DbModels[K]> | null
}>

export type DbOptions = {
  storageByKind?: DbStorageByKind
  /**
   * Account-owned persistence adapter. Without one the Db is an in-memory
   * projection: nothing survives the instance.
   */
  persistenceStore?: InlinePersistenceStore | null
  autoHydrate?: boolean
  /** Shared account logger so database diagnostics follow the live controller. */
  logger?: Log
}

export type MessageWindowOptions = {
  limit: number
  before?: MessageWindowCursor
  after?: MessageWindowCursor
  /**
   * Keep only rows with server IDs in [minMessageId, maxMessageId]. A caller
   * that reads only inside one certified range uses these so a local page
   * never crosses a hole (invariant 5).
   */
  minMessageId?: MessageID
  maxMessageId?: MessageID
}

export type LocalMessageWindowAroundOptions = {
  messageId: MessageID
  beforeLimit: number
  afterLimit: number
}

export const MAX_RESIDENT_MESSAGE_WINDOW_LOAD = 200

export type DbResidentChange = {
  kind: DbObjectKind
  id: DbModel["id"]
  object?: DbModel
}

export type DbResidentChangeBatch = {
  revision: number
  changes: DbResidentChange[]
}

export type DbResidentSnapshot = {
  revision: number
  objects: DbModel[]
}

/**
 * The resident working set. Messages are loaded by indexed windows, pending
 * transactions by the outbox, sync cursors by SyncStorage, and deferred
 * protocol payloads only by a future replay/migration owner.
 */
export const DEFAULT_HYDRATION_KINDS = [
  DbObjectKind.User,
  DbObjectKind.Space,
  DbObjectKind.Chat,
  DbObjectKind.Dialog,
  // Small (one row of ranges per chat) and needed whole: a history page
  // extends the stored ranges, so they must be resident when it commits.
  DbObjectKind.HistoryCoverage,
  // Membership, settings and folders (schema version 4). Their updates are
  // applied synchronously and need the stored row (a member's generation,
  // a grant being removed), so they are resident like the chat list.
  DbObjectKind.SpaceMember,
  DbObjectKind.ChatParticipant,
  DbObjectKind.ChatParticipantGroup,
  DbObjectKind.UserGroup,
  DbObjectKind.DialogFolder,
  DbObjectKind.UserSettings,
] as const

/**
 * One accepted write on its way to disk: a `commit` recipe, a `batch`, or a
 * bare `insert`/`replace`/`update`/`delete`. Memory already holds its result;
 * observers hear about it only after its persistence transaction commits.
 */
type DbWriteEntry = {
  /** First-touch previous values, in the order they were recorded. */
  undo: UndoEntry[]
  refs: DbObjectRef<DbObjectKind>[]
  /** Committed values to publish, captured when the write was accepted. */
  changes: DbResidentChange[]
  operations: InlinePersistenceOperation[]
  fallbacks: Array<() => Promise<void>>
  stamps: DbReadStamp[]
  implicit: boolean
  promise: Promise<void>
  resolve: () => void
  reject: (error: unknown) => void
}

const ignoreRejection = () => undefined

const withinMessageIdBounds = <M extends { messageId: MessageID }>(
  rows: M[],
  options: Pick<MessageWindowOptions, "minMessageId" | "maxMessageId">,
) => {
  if (options.minMessageId == null && options.maxMessageId == null) {
    return rows
  }
  const min =
    options.minMessageId == null ? undefined : BigInt(options.minMessageId)
  const max =
    options.maxMessageId == null ? undefined : BigInt(options.maxMessageId)
  return rows.filter((row) => {
    const id = BigInt(row.messageId)
    return (min == null || id >= min) && (max == null || id <= max)
  })
}

export class DatabaseCommitError extends Error {
  constructor(cause: unknown) {
    super(
      `Inline database commit failed${
        cause instanceof Error ? `: ${cause.message}` : ""
      }`,
      { cause },
    )
    this.name = "DatabaseCommitError"
  }
}

export class Db {
  // node persistence layer
  // hydrate into buckets and form indexes
  // create ref types
  // create query hooks ( that give a light evaluation function for an object and we loop and fetch it )
  // ----- ^ we'll use this function to evaluate if a query needs to re-run on addition/removal of objects WOW.
  // a helper to generate refs from raw IDs
  // create object hooks to go from ref -> object
  // keep a list of subscriptions for objects (for updates) and queries (addition/removal) to trigger
  // goal: 1) to create a lightweight, object-based, simple, reactive cache layer that plays well with React  2) easily expandable/modular for later upgrades to every layer (persistence, hooks, queries, schema, etc)
  // we need stable refs.
  // TODO: Maybe we need to insert a private symbol in refs to ensure they come from us and are stable.

  collections: Partial<Record<DbObjectKind, Collection<DbObjectKind, any>>> = {}
  readonly fullChatWindows = new FullChatWindowState()
  querySubscriptions = new Queries()
  objectSubscriptions = new ObjectSubscriptions()
  ready: Promise<void>
  readonly logger: Log
  hasHydrated = false
  hydrationState: "pending" | "skipped" | "done" | "failed"

  // The open write (the outermost batch or commit recipe being run)
  private batchDepth = 0
  private pendingRefs: Set<DbObjectRef<DbObjectKind>> = new Set()
  private pendingPersistenceOperations: InlinePersistenceOperation[] = []
  private pendingFallbackOperations: Array<() => Promise<void>> = []
  private undoJournal = new Map<string, UndoEntry>()
  private pendingStamps: DbReadStamp[] = []
  // Accepted writes, in acceptance order, waiting for their commit. The
  // head is the one being written; nothing behind it has reached storage.
  private readonly writeQueue: DbWriteEntry[] = []
  private draining = false
  private readonly activeReads = new Set<DbReadAdmission>()
  private hydrationPromise: Promise<void> | null = null
  private storageByKind?: DbStorageByKind
  private persistenceStore: InlinePersistenceStore | null
  private persistenceErrors: unknown[] = []
  private commitQueue: Promise<void> = Promise.resolve()
  private persistenceState: "open" | "closing" | "closed" = "open"
  private closePersistenceTask: Promise<void> | null = null
  private acceptedCommitRecipeActive = false
  private residentRevision = 0
  private readonly messageWindowIntentVersions = new Map<
    ChatID,
    number
  >()
  private residentChangeListeners = new Set<
    (batch: DbResidentChangeBatch) => void
  >()

  constructor(options: DbOptions = {}) {
    this.logger = options.logger ?? new Log("Client.Database")
    const autoHydrate = options.autoHydrate ?? true
    this.storageByKind = options.storageByKind
    this.persistenceStore = options.persistenceStore ?? null
    this.hasHydrated = !autoHydrate
    this.hydrationState = autoHydrate ? "pending" : "skipped"
    this.ready = autoHydrate ? this.hydrate() : Promise.resolve()
  }

  /**
   * Bare writes are one-statement batches: memory changes now, so the caller
   * reads its own write synchronously, and the write joins the ordered queue
   * like any batch or commit (see `batch`).
   */
  insert<K extends DbObjectKind, O extends DbModels[K]>(object: O) {
    this.assertWritable()
    this.batch(() => {
      this.collection(object.kind).insert(object)
      this.notify(this.ref(object.kind, object.id))
    })
  }

  /** Replace a complete object, including clearing optional fields. */
  replace<K extends DbObjectKind, O extends DbModels[K]>(object: O) {
    this.assertWritable()
    this.batch(() => {
      this.collection(object.kind).replace(object)
      this.notify(this.ref(object.kind, object.id))
    })
  }

  delete(ref: DbObjectRef<DbObjectKind>) {
    this.assertWritable()
    this.batch(() => {
      this.collection(ref.kind).delete(ref.id)
      this.notify(ref)
    })
  }

  /**
   * Remove every message for a chat from memory and persistence. The storage
   * operation uses the chat/message index, so unloaded history cannot return
   * during a later selective hydration.
   */
  clearMessagesForChat(chatId: ChatID) {
    this.assertWritable()
    this.batch(() => {
      const collection = this.collection<
        DbObjectKind.Message,
        DbModels[DbObjectKind.Message]
      >(DbObjectKind.Message)
      const removedIds = collection.clearMessagesForChat(chatId)
      for (const id of removedIds) {
        this.notify(this.ref(DbObjectKind.Message, id))
      }
      // Rows are gone, so nothing in this chat is certified any more.
      this.resetHistoryCoverage(chatId)
    })
  }

  /**
   * Invariant 5. The chat's certified history ranges (resident; hydrated
   * with the default kinds). Empty when nothing is certified.
   */
  historyCoverage(chatId: ChatID): HistoryRange[] {
    return coverageRanges(
      this.get(this.ref(DbObjectKind.HistoryCoverage, chatId)),
    )
  }

  /** Forget everything certified for a chat: all of its history is a hole. */
  resetHistoryCoverage(chatId: ChatID) {
    const ref = this.ref(DbObjectKind.HistoryCoverage, chatId)
    if (!this.get(ref)) return
    this.delete(ref)
  }

  /**
   * The history page reducer (InlineKit's `HistoryPageReducer.admitCoverage`).
   * Run it inside the commit that stores the page's rows, so rows and
   * coverage commit or roll back together.
   *
   * For each proven range, stored server rows the page did not return are
   * deleted: the server certified that they no longer exist. Rows above
   * `knownMaxId` (the newest message known when the request was made) are
   * kept, since they may have arrived after the server built the page. Then
   * the ranges join the chat's coverage.
   */
  admitHistoryPage(
    chatId: ChatID,
    ranges: readonly HistoryRange[],
    returned: readonly MessageID[],
    knownMaxId?: MessageID,
  ) {
    if (ranges.length === 0) return
    this.batch(() => {
      const keep = new Set(returned.map(String))
      let knownMax = knownMaxId == null ? 0n : BigInt(knownMaxId)
      for (const id of returned) {
        if (BigInt(id) > knownMax) knownMax = BigInt(id)
      }
      const messages = this.collection<
        DbObjectKind.Message,
        DbModels[DbObjectKind.Message]
      >(DbObjectKind.Message)
      for (const [from, to] of ranges) {
        const upper = to < knownMax ? to : knownMax
        if (from > upper) continue
        for (const message of messages.getAll(
          (candidate) => candidate.chatId === chatId,
        )) {
          if (keep.has(String(message.messageId))) continue
          const id = BigInt(message.messageId)
          if (id < from || id > upper) continue
          this.delete(this.ref(DbObjectKind.Message, message.id))
        }
        messages.deleteStoredInRange(chatId, from, upper, keep)
      }
      this.replace({
        kind: DbObjectKind.HistoryCoverage,
        id: chatId,
        ranges: coverageModelRanges(
          certifyRanges(this.historyCoverage(chatId), ranges),
        ),
      })
    })
  }

  update<K extends DbObjectKind, O extends DbModels[K]>(object: O) {
    this.assertWritable()
    this.batch(() => {
      this.collection(object.kind).update(object)
      this.notify(this.ref(object.kind, object.id))
    })
  }

  /**
   * Apply a synchronous mutation recipe to memory and accept it as one
   * write. Memory changes immediately, so the caller (and any synchronous
   * reader) sees the result at once; persistence joins the account's single
   * ordered write queue behind every write accepted before it (invariant 6).
   *
   * - A recipe that throws restores memory before anything is published.
   * - Observers are told only after the write's storage transaction commits
   *   (invariant 1). A batch with nothing to persist and no write ahead of it
   *   publishes synchronously.
   * - If storage rejects the write, memory is restored for it and for every
   *   write accepted after it (they have not reached storage), so memory
   *   never holds a value that is not on disk or on its way there. The error
   *   is reported by the next `flushPersistence()`.
   *
   * Nested batches (and batches inside a `commit` recipe) join the outer one.
   */
  batch(fn: () => void): void {
    const outermost = this.batchDepth === 0
    if (outermost) {
      this.assertWritable()
      this.openWrite()
    }

    this.batchDepth++
    let succeeded = false
    try {
      fn()
      succeeded = true
    } finally {
      this.batchDepth--
      if (outermost && succeeded) {
        this.acceptWrite(true)
      } else if (outermost) {
        this.rollbackBatch()
      }
    }
  }

  /**
   * Run a mutation recipe once every write accepted before this call has
   * settled, accept it as one write, and resolve when it has committed. On a
   * storage failure memory is restored and the promise rejects with
   * `DatabaseCommitError`. Commits share the queue with `batch` and bare
   * writes, so they commit in the order their memory changes were made.
   *
   * Production collections share one persistence transaction. Injected
   * per-kind test adapters retain their compatibility behavior and cannot
   * provide cross-adapter disk atomicity.
   */
  commit(fn: () => void): Promise<void> {
    if (this.persistenceState !== "open") {
      return Promise.reject(
        new Error("Inline database is closing"),
      )
    }
    const operation = this.commitQueue.then(() =>
      this.performCommit(fn),
    )
    this.commitQueue = operation.catch(() => undefined)
    return operation
  }

  private async performCommit(fn: () => void) {
    if (this.batchDepth !== 0) {
      throw new Error(
        "Cannot start an Inline database commit inside a batch",
      )
    }
    await this.writesSettled()

    this.openWrite()
    this.batchDepth = 1
    this.acceptedCommitRecipeActive = true
    try {
      fn()
    } catch (error) {
      this.batchDepth = 0
      this.rollbackBatch()
      throw error
    } finally {
      this.acceptedCommitRecipeActive = false
    }
    this.batchDepth = 0

    const entry = this.acceptWrite(false)
    if (entry) await entry.promise
  }

  private notify<K extends DbObjectKind>(ref: DbObjectRef<K>) {
    if (this.batchDepth > 0) {
      this.pendingRefs.add(ref)
      // Cached query results must not hide the caller's own write while it
      // waits for its commit; callbacks still fire only after the commit.
      this.querySubscriptions.markKindDirty(ref.kind)
      return
    }
    this.batch(() => {
      this.pendingRefs.add(ref)
    })
  }

  /**
   * Committed changes, in commit order. Each batch is one committed write
   * (or a memory-only change such as a hydrated or evicted row) and carries
   * a revision one higher than the batch before it.
   *
   * The guarantee, for anyone building patches from this stream:
   *
   * - A batch is delivered only after the storage transaction holding its
   *   writes has committed. A write that is rolled back is never delivered.
   * - `object` is the value the write committed, captured when it was
   *   accepted, not the live value at delivery time. A later accepted write
   *   that has not committed yet is not visible here. A missing `object`
   *   means the row is no longer resident (deleted or evicted).
   * - After a storage failure, one extra batch re-delivers the affected keys
   *   with their restored (committed) values. It can repeat values a
   *   subscriber already has; applying it is idempotent.
   * - `residentSnapshot()` returns the committed view at the revision of the
   *   last delivered batch: accepted writes that have not committed are
   *   left out of it and arrive later as batches with higher revisions.
   *   Memory-only changes (hydration, eviction) may appear in a snapshot
   *   before the batch that announces them; that batch repeats them.
   *
   * Synchronous reads (`get`, `queryCollection`) see accepted writes at
   * once. `subscribeToObject` and `subscribeToQuery` callbacks fire at the
   * same point as these batches but read live memory when they run.
   */
  subscribeToResidentChanges(
    listener: (batch: DbResidentChangeBatch) => void,
  ) {
    this.residentChangeListeners.add(listener)
    return () => {
      this.residentChangeListeners.delete(listener)
    }
  }

  /**
   * The committed resident view, at the revision of the last batch
   * delivered by `subscribeToResidentChanges`. See that method for the
   * exact guarantee.
   */
  residentSnapshot(
    kinds: readonly DbObjectKind[] = Object.values(
      DbObjectKind,
    ),
  ): DbResidentSnapshot {
    // The first undo entry for a key across every uncommitted write holds
    // its committed value.
    const uncommitted = new Map<string, UndoEntry>()
    const record = (entries: Iterable<UndoEntry>) => {
      for (const entry of entries) {
        const key = dbObjectKey(entry.collection.kind, entry.id)
        if (!uncommitted.has(key)) uncommitted.set(key, entry)
      }
    }
    for (const write of this.writeQueue) record(write.undo)
    if (this.batchDepth > 0) record(this.undoJournal.values())

    const wanted = new Set(kinds)
    const objects: DbModel[] = []
    for (const kind of kinds) {
      for (const object of this.queryCollection(
        DbQueryPlanType.Objects,
        kind,
      )) {
        if (!uncommitted.has(dbObjectKey(kind, object.id))) {
          objects.push(object)
        }
      }
    }
    for (const entry of uncommitted.values()) {
      if (entry.previous && wanted.has(entry.collection.kind)) {
        objects.push(entry.previous)
      }
    }
    return {
      revision: this.residentRevision,
      objects,
    }
  }

  get<K extends DbObjectKind, O extends DbModels[K]>(ref: DbObjectRef<K>): O | undefined {
    return this.collection(ref.kind).get(ref.id) as O | undefined
  }

  ref<K extends DbObjectKind>(kind: K, id: DbObjectId<K>): DbObjectRef<K> {
    return this.collection(kind).ref(id)
  }

  subscribeToObject<K extends DbObjectKind>(ref: DbObjectRef<K>, callback: () => void): { unsubscribe: () => void } {
    let { unsubscribe } = this.objectSubscriptions.subscribe(ref, callback)
    return { unsubscribe }
  }

  private triggerObjectSubscriptions<K extends DbObjectKind>(ref: DbObjectRef<K>) {
    let subscriptions = this.objectSubscriptions.getSubscriptionsForRef(ref)
    for (const subscription of subscriptions) {
      subscription()
    }
  }

  subscribeToQuery<K extends DbObjectKind, O extends DbModels[K]>(
    key: string,
    type: DbQueryPlanType,
    kind: K,
    predicate: (object: O) => boolean,
    callback: () => void,
  ): { unsubscribe: () => void } {
    let queryPlan: DbQueryPlan<K, O> = { key, type, kind, predicate }
    let { unsubscribe } = this.querySubscriptions.subscribe(queryPlan, callback)
    return { unsubscribe }
  }

  private triggerKindQueries(kind: DbObjectKind) {
    this.querySubscriptions.markKindDirty(kind)
    for (const query of this.querySubscriptions.getQueriesByKind(kind)) {
      for (const callback of this.querySubscriptions.getCallbacksForKey(query.key)) {
        callback()
      }
    }
  }

  queryCollection<K extends DbObjectKind, O extends DbModels[K], T extends DbQueryPlanType>(
    type: T,
    kind: K,
    predicate: (object: O) => boolean = () => true,
  ): T extends DbQueryPlanType.Objects ? O[] : DbObjectRef<K>[] {
    if (type === DbQueryPlanType.Objects) {
      return this.collection<K, O>(kind).getAll(predicate) as T extends DbQueryPlanType.Objects ? O[] : never
    } else {
      return this.collection<K, O>(kind).getAllRefs(predicate) as T extends DbQueryPlanType.Objects
        ? never
        : DbObjectRef<K>[]
    }
  }

  /** Cached version of queryCollection. Returns cached result if valid, otherwise computes fresh. */
  queryCached<K extends DbObjectKind, O extends DbModels[K], T extends DbQueryPlanType>(
    key: string,
    type: T,
    kind: K,
    predicate: (object: O) => boolean = () => true,
  ): T extends DbQueryPlanType.Objects ? O[] : DbObjectRef<K>[] {
    if (!this.querySubscriptions.isDirty(key)) {
      return this.querySubscriptions.getCachedResult(key)!
    }
    const result = this.queryCollection<K, O, T>(type, kind, predicate)
    this.querySubscriptions.setCachedResult(key, result)
    return result
  }

  async hydrate(): Promise<void> {
    if (this.hydrationPromise) return this.hydrationPromise

    this.hydrationPromise = (async () => {
      if (this.hydrationState === "skipped") {
        this.hydrationState = "pending"
      }
      try {
        await this.hydrateKinds([...DEFAULT_HYDRATION_KINDS])
        this.hydrationState = "done"
      } catch (error) {
        this.hydrationState = "failed"
        throw error
      } finally {
        this.hasHydrated = true
      }
    })()

    return this.hydrationPromise
  }

  async hydrateKinds(kinds: DbObjectKind[]): Promise<void> {
    const admission = this.beginRead()
    try {
      const results = await Promise.all(
        kinds.map(async (kind) => {
          const objects = await this.collection(kind).hydrate(
            admission,
          )
          return { kind, objects }
        }),
      )
      this.notifyHydrated(results)
    } finally {
      this.endRead(admission)
    }
  }

  async hydrateMessageWindow(
    chatId: ChatID,
    options: MessageWindowOptions,
  ): Promise<number> {
    return (await this.hydrateMessageWindowDetails(chatId, options))
      .count
  }

  async hydrateMessageWindowDetails(
    chatId: ChatID,
    options: MessageWindowOptions,
  ): Promise<{ count: number; messageKeys: MessageKey[] }> {
    this.validateMessageWindowOptions(options)
    const intentVersion = this.beginResidentMessageWindowIntent(
      chatId,
    )
    return await this.hydrateMessageWindowDetailsForIntent(
      chatId,
      options,
      intentVersion,
    )
  }

  private async hydrateMessageWindowDetailsForIntent(
    chatId: ChatID,
    options: MessageWindowOptions,
    intentVersion: number | undefined,
  ): Promise<{ count: number; messageKeys: MessageKey[] }> {
    const collection = this.collection<DbObjectKind.Message, DbModels[DbObjectKind.Message]>(
      DbObjectKind.Message,
    )
    const admission = this.beginRead()
    let objects: DbModels[DbObjectKind.Message][]
    try {
      const stored = withinMessageIdBounds(
        await collection.readMessageWindowByChatId(
          chatId,
          options.limit,
          options.before,
          options.after,
        ),
        options,
      )
      const storedDeferred = await this.readDeferredUpdatesForMessageKeys(
        stored.map((message) => message.id),
      )
      // One synchronous step from here: reconcile, admit, set membership.
      const admitted = collection.admitStored(stored, admission)
      objects = admitted.objects
      const deferred = this.admitDeferredUpdates(
        storedDeferred,
        admission,
      )
      if (
        intentVersion != null &&
        this.isCurrentResidentMessageWindowIntent(
          chatId,
          intentVersion,
        )
      ) {
        const messageKeys = objects.map((message) => message.id)
        if (options.before == null && options.after == null) {
          this.replaceResidentMessageWindow(
            chatId,
            this.messageKeysRetainingLocalSends(chatId, [
              ...messageKeys,
              ...this.windowKeysWrittenDuringRead(chatId, admission),
              ...this.windowKeysContiguousWith(chatId, messageKeys),
            ]),
            true,
            intentVersion,
          )
        } else {
          this.extendResidentMessageWindow(
            chatId,
            messageKeys,
            intentVersion,
          )
        }
      }
      this.notifyHydrated([
        { kind: DbObjectKind.DeferredUpdate, objects: deferred },
        { kind: DbObjectKind.Message, objects: admitted.inserted },
      ])
    } finally {
      this.endRead(admission)
    }
    const newest = objects
      .slice()
      .sort((left, right) =>
        compareMessagesByWindow(right, left),
      )
      .at(0)
    const chatRef = this.ref(DbObjectKind.Chat, chatId)
    const chat = this.get(chatRef)
    if (
      newest &&
      chat &&
      (chat.lastMsgId == null ||
        compareMessagesByWindow(newest, {
          messageId: chat.lastMsgId,
          date: chat.date,
        }) > 0)
    ) {
      this.update({
        ...chat,
        lastMsgId: newest.messageId,
        date: newest.date ?? chat.date,
      })
    }
    const currentLastMessageId = this.get(chatRef)?.lastMsgId
    if (
      this.fullChatWindows.isActive(chatId) &&
      intentVersion != null &&
      this.isCurrentResidentMessageWindowIntent(
        chatId,
        intentVersion,
      ) &&
      options.after != null &&
      currentLastMessageId != null &&
      objects.some(
        (message) => message.messageId === currentLastMessageId,
      )
    ) {
      this.fullChatWindows.setAtLatest(chatId, true)
    }
    return {
      count: objects.length,
      messageKeys: objects.map((message) => message.id),
    }
  }

  /**
   * Replace one chat's resident message window with a bounded local window
   * around a persisted message. Persistence is untouched: this mirrors
   * Inline Apple's FullChatProgressive jump-to-message behavior while keeping
   * the renderer working set bounded.
   */
  async loadLocalWindowAroundMessage(
    chatId: ChatID,
    options: LocalMessageWindowAroundOptions,
  ): Promise<boolean> {
    return (
      await this.loadLocalWindowAroundMessageDetails(
        chatId,
        options,
        true,
        this.beginResidentMessageWindowIntent(chatId),
      )
    ).found
  }

  async loadLocalWindowAroundMessageForIntent(
    chatId: ChatID,
    options: LocalMessageWindowAroundOptions,
    intentVersion: number | undefined,
  ): Promise<boolean> {
    return (
      await this.loadLocalWindowAroundMessageDetails(
        chatId,
        options,
        true,
        intentVersion,
      )
    ).found
  }

  async loadLocalWindowAroundMessageDetails(
    chatId: ChatID,
    options: LocalMessageWindowAroundOptions,
    replaceResidentWindow = true,
    expectedIntentVersion =
      this.beginResidentMessageWindowIntent(chatId),
  ): Promise<{ found: boolean; messageKeys: MessageKey[] }> {
    this.validateLocalMessageWindowAroundOptions(options)
    const collection = this.collection<
      DbObjectKind.Message,
      DbModels[DbObjectKind.Message]
    >(DbObjectKind.Message)
    const admission = this.beginRead()
    let objects: DbModels[DbObjectKind.Message][]
    try {
      const stored = await collection.loadLocalWindowAroundMessage(
        chatId,
        options.messageId,
        options.beforeLimit,
        options.afterLimit,
      )
      if (stored.length === 0) {
        return { found: false, messageKeys: [] }
      }

      if (
        expectedIntentVersion != null &&
        !this.isCurrentResidentMessageWindowIntent(
          chatId,
          expectedIntentVersion,
        )
      ) {
        return { found: false, messageKeys: [] }
      }

      const storedDeferred =
        await this.readDeferredUpdatesForMessageKeys(
          stored.map((message) => message.id),
        )

      // One synchronous step from here, after every await: reconcile the
      // rows against writes accepted since the read began, then admit them.
      objects = collection.reconcileStored(stored, admission)
      const deferred = this.admitDeferredUpdates(
        storedDeferred,
        admission,
      )

      if (this.fullChatWindows.isActive(chatId)) {
        this.replaceResidentMessageWindow(
          chatId,
          objects.map((message) => message.id),
          false,
          expectedIntentVersion,
        )
      }

      this.batch(() => {
        for (const object of deferred) {
          this.notify(
            this.ref(DbObjectKind.DeferredUpdate, object.id),
          )
        }
        if (
          this.fullChatWindows.isActive(chatId) ||
          !replaceResidentWindow
        ) {
          for (const object of objects) {
            if (!collection.get(object.id)) {
              collection.insertResident(object)
            }
            this.notify(this.ref(DbObjectKind.Message, object.id))
          }
          if (this.fullChatWindows.isActive(chatId)) {
            this.reconcileResidentMessageWindow(chatId)
          }
        } else {
          for (const id of collection.replaceResidentMessagesForChat(
            chatId,
            objects,
          )) {
            this.notify(this.ref(DbObjectKind.Message, id))
          }
        }
      })
    } finally {
      this.endRead(admission)
    }
    return {
      found: objects.some(
        (message) => message.messageId === options.messageId,
      ),
      messageKeys: objects.map((message) => message.id),
    }
  }

  /**
   * Release an inactive FullChatProgressive history window from memory while
   * preserving its durable rows. The sidebar's last message and
   * local send state remain resident. A reaction intent is owner-local and
   * deliberately non-persistent, so reclamation defers until it settles.
   */
  releaseResidentMessageWindow(chatId: ChatID): number {
    this.fullChatWindows.release(chatId)
    this.invalidateResidentMessageWindowIntent(chatId)
    const collection = this.collection<
      DbObjectKind.Message,
      DbModels[DbObjectKind.Message]
    >(DbObjectKind.Message)
    const resident = collection.getAll(
      (message) => message.chatId === chatId,
    )
    if (
      resident.some(
        (message) => (message.reactionIntents?.length ?? 0) > 0,
      )
    ) {
      return 0
    }

    const chat = this.get(this.ref(DbObjectKind.Chat, chatId))
    const removedIds = collection.retainResidentMessagesForChat(
      chatId,
      (message) =>
        message.messageId === chat?.lastMsgId ||
        message.status === MessageSendingStatus.Sending ||
        message.status === MessageSendingStatus.Failed,
    )
    this.batch(() => {
      for (const id of removedIds) {
        this.notify(this.ref(DbObjectKind.Message, id))
      }
    })
    return removedIds.length
  }

  activateResidentMessageWindow(chatId: ChatID) {
    const collection = this.collection<
      DbObjectKind.Message,
      DbModels[DbObjectKind.Message]
    >(DbObjectKind.Message)
    const activated = this.fullChatWindows.activate(
      chatId,
      collection
        .getAll((message) => message.chatId === chatId)
        .map((message) => message.id),
    )
    if (activated) this.invalidateResidentMessageWindowIntent(chatId)
    return activated
  }

  beginResidentMessageWindowIntent(chatId: ChatID) {
    if (!this.fullChatWindows.isActive(chatId)) return undefined
    const next =
      (this.messageWindowIntentVersions.get(chatId) ?? 0) + 1
    this.messageWindowIntentVersions.set(chatId, next)
    return next
  }

  captureResidentMessageWindowIntents() {
    return new Map(this.messageWindowIntentVersions)
  }

  replaceResidentMessageWindow(
    chatId: ChatID,
    messageKeys: readonly MessageKey[],
    atLatest: boolean,
    expectedIntentVersion?: number,
  ) {
    if (
      expectedIntentVersion != null &&
      !this.isCurrentResidentMessageWindowIntent(
        chatId,
        expectedIntentVersion,
      )
    ) {
      return false
    }
    const beforeKeys = this.fullChatWindows.keys(chatId)
    if (!this.fullChatWindows.replace(chatId, messageKeys, atLatest)) {
      return false
    }
    this.notifyMessageWindowMembership(
      beforeKeys,
      this.fullChatWindows.keys(chatId),
    )
    return true
  }

  replaceResidentMessageWindowWithLatest(
    chatId: ChatID,
    messageKeys: readonly MessageKey[],
    expectedIntentVersion?: number,
  ) {
    return this.replaceResidentMessageWindow(
      chatId,
      this.messageKeysRetainingLocalSends(chatId, [
        ...messageKeys,
        ...this.windowKeysContiguousWith(chatId, messageKeys),
      ]),
      true,
      expectedIntentVersion,
    )
  }

  extendResidentMessageWindow(
    chatId: ChatID,
    messageKeys: readonly MessageKey[],
    expectedIntentVersion?: number,
  ) {
    if (
      expectedIntentVersion != null &&
      !this.isCurrentResidentMessageWindowIntent(
        chatId,
        expectedIntentVersion,
      )
    ) {
      return false
    }
    const beforeKeys = this.fullChatWindows.keys(chatId)
    if (!this.fullChatWindows.extend(chatId, messageKeys)) {
      return false
    }
    this.notifyMessageWindowMembership(
      beforeKeys,
      this.fullChatWindows.keys(chatId),
    )
    return true
  }

  setResidentMessageWindowAtLatest(
    chatId: ChatID,
    expectedIntentVersion?: number,
  ) {
    if (
      expectedIntentVersion != null &&
      !this.isCurrentResidentMessageWindowIntent(
        chatId,
        expectedIntentVersion,
      )
    ) {
      return false
    }
    return this.fullChatWindows.setAtLatest(chatId, true)
  }

  includeMessageInActiveLatestWindow(
    message: DbModels[DbObjectKind.Message],
  ) {
    if (!this.fullChatWindows.isAtLatest(message.chatId)) return false
    const chat = this.get(
      this.ref(DbObjectKind.Chat, message.chatId),
    )
    if (chat?.lastMsgId !== message.messageId) return false
    return this.extendResidentMessageWindow(message.chatId, [
      message.id,
    ])
  }

  /** Keep visible-window membership stable while a local message gets its server ID. */
  migrateResidentMessageWindowKey(
    chatId: ChatID,
    previousKey: MessageKey,
    nextKey: MessageKey,
  ) {
    if (!this.fullChatWindows.contains(chatId, previousKey)) {
      return false
    }
    const beforeKeys = this.fullChatWindows.keys(chatId)
    const nextKeys = beforeKeys.map((key) =>
      key === previousKey ? nextKey : key,
    )
    const atLatest = this.fullChatWindows.isAtLatest(chatId)
    if (!this.fullChatWindows.replace(chatId, nextKeys, atLatest)) {
      return false
    }
    this.notifyMessageWindowMembership(
      beforeKeys,
      this.fullChatWindows.keys(chatId),
    )
    return true
  }

  /**
   * Show an accepted send (or an explicit "latest") in the chat's open
   * window. The send wins over a window move in flight: the intent version
   * is bumped either way.
   *
   * - At latest, the window already is the latest contiguous run, so the
   *   local sends only join it, in the same step. Nothing else moves.
   * - Elsewhere in history, the latest page is read from disk and replaces
   *   the window once, sends included. While the chat's latest history is
   *   certified, the read stays inside that run (invariant 5).
   *
   * This used to replace the window at once with its members "contiguous
   * with the chat's last message", then re-read the latest page. Called
   * after a send's optimistic commit, the last message is the send's
   * temporary (negative) ID, which no certified range holds, so that set was
   * always empty: the window collapsed to the send alone for a patch, then
   * came back as the latest `limit` rows, and history paged back beyond
   * them was dropped.
   */
  async promoteResidentMessageWindowToLatest(
    chatId: ChatID,
    limit = 60,
  ) {
    this.validateMessageWindowOptions({ limit })
    const atLatest = this.fullChatWindows.isAtLatest(chatId)
    const intentVersion = this.beginResidentMessageWindowIntent(
      chatId,
    )
    if (intentVersion == null) return
    if (atLatest) {
      this.extendResidentMessageWindow(
        chatId,
        this.messageKeysRetainingLocalSends(chatId, []),
        intentVersion,
      )
      return
    }
    const top = this.historyCoverage(chatId).at(-1)
    await this.hydrateMessageWindowDetailsForIntent(
      chatId,
      {
        limit,
        ...(top && top[1] >= HISTORY_TOP
          ? { minMessageId: messageId(top[0]) }
          : {}),
      },
      intentVersion,
    )
  }

  isMessageInHistoryWindow(
    chatId: ChatID,
    key: MessageKey,
  ) {
    return this.fullChatWindows.contains(chatId, key)
  }

  compactResidentMessageWindow(
    chatId: ChatID,
    firstVisibleKey: MessageKey,
    lastVisibleKey: MessageKey,
    maximumMessages: number,
  ) {
    const collection = this.collection<
      DbObjectKind.Message,
      DbModels[DbObjectKind.Message]
    >(DbObjectKind.Message)
    const ordered = this.fullChatWindows
      .keys(chatId)
      .flatMap((key) => {
        const message = collection.get(key)
        return message ? [message] : []
      })
      .sort(compareMessagesByWindow)
    const removed = this.fullChatWindows.compact(
      chatId,
      ordered.map((message) => message.id),
      firstVisibleKey,
      lastVisibleKey,
      maximumMessages,
    )
    if (removed.length === 0) return 0
    this.notifyMessageWindowMembership(
      [...this.fullChatWindows.keys(chatId), ...removed],
      this.fullChatWindows.keys(chatId),
    )
    this.reconcileResidentMessageWindow(chatId)
    return removed.length
  }

  reconcileResidentMessageWindow(
    chatId: ChatID,
    externalRetainedKeys?: ReadonlySet<MessageKey>,
  ) {
    const collection = this.collection<
      DbObjectKind.Message,
      DbModels[DbObjectKind.Message]
    >(DbObjectKind.Message)
    const chat = this.get(this.ref(DbObjectKind.Chat, chatId))
    const retainedKeys = externalRetainedKeys ?? new Set(
      this.fullChatWindows.keys(chatId),
    )
    const removedIds = collection.retainResidentMessagesForChat(
      chatId,
      (message) =>
        retainedKeys.has(message.id) ||
        message.messageId === chat?.lastMsgId ||
        message.status === MessageSendingStatus.Sending ||
        message.status === MessageSendingStatus.Failed ||
        (message.reactionIntents?.length ?? 0) > 0,
    )
    for (const id of removedIds) {
      this.notify(this.ref(DbObjectKind.Message, id))
    }
  }

  private isCurrentResidentMessageWindowIntent(
    chatId: ChatID,
    intentVersion: number,
  ) {
    return (
      this.fullChatWindows.isActive(chatId) &&
      this.messageWindowIntentVersions.get(chatId) === intentVersion
    )
  }

  private invalidateResidentMessageWindowIntent(chatId: ChatID) {
    const next =
      (this.messageWindowIntentVersions.get(chatId) ?? 0) + 1
    this.messageWindowIntentVersions.set(chatId, next)
    return next
  }

  /**
   * Window members that certified history (invariant 5) proves contiguous
   * with a latest page: those in the certified range holding the page's
   * oldest server row (or, for no rows, the chat's last message). Replacing
   * a window with its latest page keeps them, so a reader who paged back
   * keeps their place; members across a hole are dropped.
   */
  private windowKeysContiguousWith(
    chatId: ChatID,
    pageKeys: readonly MessageKey[],
  ): MessageKey[] {
    const messages = this.collection<
      DbObjectKind.Message,
      DbModels[DbObjectKind.Message]
    >(DbObjectKind.Message)
    const serverId = (key: MessageKey) => {
      const id = messages.get(key)?.messageId
      return id != null && parseInlineId<"message">(id, { positive: true }) != null
        ? BigInt(id)
        : undefined
    }
    let anchor: bigint | undefined
    for (const key of pageKeys) {
      const id = serverId(key)
      if (id != null && (anchor == null || id < anchor)) anchor = id
    }
    if (anchor == null) {
      const lastMsgId = this.get(this.ref(DbObjectKind.Chat, chatId))?.lastMsgId
      if (lastMsgId != null && parseInlineId<"message">(lastMsgId, { positive: true }) != null) {
        anchor = BigInt(lastMsgId)
      }
    }
    if (anchor == null) return []
    const run = certifiedRangeAt(this.historyCoverage(chatId), anchor)
    if (!run) return []
    return this.fullChatWindows.keys(chatId).filter((key) => {
      const id = serverId(key)
      return id != null && id >= run[0] && id <= run[1]
    })
  }

  private messageKeysRetainingLocalSends(
    chatId: ChatID,
    messageKeys: readonly MessageKey[],
  ) {
    const pendingKeys = this.collection<
      DbObjectKind.Message,
      DbModels[DbObjectKind.Message]
    >(DbObjectKind.Message)
      .getAll(
        (message) =>
          message.chatId === chatId &&
          (message.status === MessageSendingStatus.Sending ||
            message.status === MessageSendingStatus.Failed),
      )
      .map((message) => message.id)
    return Array.from(new Set([...messageKeys, ...pendingKeys]))
  }

  private validateMessageWindowOptions(
    options: MessageWindowOptions,
  ) {
    if (
      !Number.isSafeInteger(options.limit) ||
      options.limit < 1 ||
      options.limit > MAX_RESIDENT_MESSAGE_WINDOW_LOAD ||
      (options.before != null &&
        parseMessageWindowCursor(options.before) == null) ||
      (options.after != null &&
        parseMessageWindowCursor(options.after) == null) ||
      (options.before != null && options.after != null)
    ) {
      throw new RangeError("Invalid Inline message window")
    }
  }

  private validateLocalMessageWindowAroundOptions(
    options: LocalMessageWindowAroundOptions,
  ) {
    if (
      parseInlineId<"message">(options.messageId, {
        positive: true,
      }) == null ||
      !Number.isSafeInteger(options.beforeLimit) ||
      options.beforeLimit < 0 ||
      !Number.isSafeInteger(options.afterLimit) ||
      options.afterLimit < 0 ||
      options.beforeLimit + options.afterLimit + 1 >
        MAX_RESIDENT_MESSAGE_WINDOW_LOAD
    ) {
      throw new RangeError("Invalid Inline around-message window")
    }
  }

  private notifyMessageWindowMembership(
    before: readonly MessageKey[],
    after: readonly MessageKey[],
  ) {
    const beforeSet = new Set(before)
    const afterSet = new Set(after)
    const changed = new Set<MessageKey>()
    for (const key of beforeSet) {
      if (!afterSet.has(key)) changed.add(key)
    }
    for (const key of afterSet) {
      if (!beforeSet.has(key)) changed.add(key)
    }
    this.batch(() => {
      for (const key of changed) {
        this.notify(this.ref(DbObjectKind.Message, key))
      }
    })
  }

  async hydrateObjects<K extends DbObjectKind>(kind: K, ids: DbObjectId<K>[]): Promise<number> {
    const uniqueIds = Array.from(new Set(ids))
    const admission = this.beginRead()
    try {
      const objects = await this.collection<K, DbModels[K]>(
        kind,
      ).hydrateIds(uniqueIds, admission)
      const deferred =
        kind === DbObjectKind.Message
          ? this.admitDeferredUpdates(
              await this.readDeferredUpdatesForMessageKeys(
                objects.map((object) => String(object.id)),
              ),
              admission,
            )
          : []
      this.notifyHydrated([
        { kind: DbObjectKind.DeferredUpdate, objects: deferred },
        { kind, objects },
      ])
      return objects.length
    } finally {
      this.endRead(admission)
    }
  }

  /**
   * Make the stored deferred updates of these kinds resident (invariant 13
   * admission applies), oldest first. The update layer uses it to replay raw
   * rows of a kind that gained a model; it never reads the whole log.
   */
  async hydrateDeferredUpdatesByTypes(
    updateTypes: string[],
  ): Promise<DbModels[DbObjectKind.DeferredUpdate][]> {
    const admission = this.beginRead()
    try {
      const collection = this.collection<
        DbObjectKind.DeferredUpdate,
        DbModels[DbObjectKind.DeferredUpdate]
      >(DbObjectKind.DeferredUpdate)
      const stored = await collection.readDeferredUpdateTypes(
        Array.from(new Set(updateTypes)),
      )
      const { objects, inserted } = collection.admitStored(stored, admission)
      this.notifyHydrated([
        { kind: DbObjectKind.DeferredUpdate, objects: inserted },
      ])
      return objects
    } finally {
      this.endRead(admission)
    }
  }

  /**
   * Selectively materialize deferred sidecars for the supplied message keys.
   * The target index keeps RPC/sync preparation proportional to the
   * payload being applied rather than the account's deferred-update history.
   */
  async hydrateDeferredUpdatesForMessageKeys(
    targetKeys: string[],
  ): Promise<number> {
    const admission = this.beginRead()
    try {
      const objects = this.admitDeferredUpdates(
        await this.readDeferredUpdatesForMessageKeys(targetKeys),
        admission,
      )
      this.notifyHydrated([
        { kind: DbObjectKind.DeferredUpdate, objects },
      ])
      return objects.length
    } finally {
      this.endRead(admission)
    }
  }

  /**
   * A chat's stored messages that pass `match`, newest first, below
   * `beforeMessageId` (a `chatMedia` list read from disk). The rows found
   * become resident (invariant 13 admission: a write accepted during the
   * read wins, and a row it changed is matched again). `undefined` when the
   * store cannot scan (a store without SQLite): memory is all there is.
   *
   * Cost: one backwards walk of the `message` primary key, decoding every
   * row read, so it is proportional to the rows scanned, not to the matches;
   * `maxScanned` bounds one call.
   */
  async scanChatMessages(
    chatId: ChatID,
    match: (message: DbModels[DbObjectKind.Message]) => boolean,
    options: ChatMessageScanOptions,
  ): Promise<ChatMessageScan<DbModels[DbObjectKind.Message]> | undefined> {
    const collection = this.collection<
      DbObjectKind.Message,
      DbModels[DbObjectKind.Message]
    >(DbObjectKind.Message)
    const admission = this.beginRead()
    try {
      const scan = await collection.scanChatMessages(chatId, match, options)
      if (!scan) return undefined
      const admitted = collection.admitStored(scan.matches, admission)
      this.notifyHydrated([
        { kind: DbObjectKind.Message, objects: admitted.inserted },
      ])
      return { ...scan, matches: admitted.objects.filter(match) }
    } finally {
      this.endRead(admission)
    }
  }

  /**
   * Read exact persisted objects without making them part of the resident
   * reactive working set. This is used for bounded side references (for
   * example a message embedded by a reply) that must not widen the visible
   * chat history window.
   */
  async readStoredObjects<K extends DbObjectKind>(
    kind: K,
    ids: DbObjectId<K>[],
  ): Promise<DbModels[K][]> {
    const admission = this.beginRead()
    try {
      return await this.collection<K, DbModels[K]>(
        kind,
      ).readStoredIds(Array.from(new Set(ids)), admission)
    } finally {
      this.endRead(admission)
    }
  }

  /**
   * Run a disk read that bypasses the collections (local message search)
   * under read admission (invariant 13). `admit` runs synchronously after
   * the read's last await: a row it takes from disk goes through
   * `admission.reconcile`, so a write accepted before or during the read
   * wins over what the disk returned.
   */
  async readThroughAdmission<T, R>(
    read: () => Promise<T>,
    admit: (value: T, admission: DbReadAdmission) => R,
  ): Promise<R> {
    const admission = this.beginRead()
    try {
      const value = await read()
      return admit(value, admission)
    } finally {
      this.endRead(admission)
    }
  }

  /** The persistence store this Db writes through, if any. */
  get persistence(): InlinePersistenceStore | null {
    return this.persistenceStore
  }

  /** Persist a side-reference object without hydrating it into memory. */
  storeNonResidentObject<K extends DbObjectKind>(
    object: DbModels[K],
  ) {
    this.assertWritable()
    const collection = this.collection<K, DbModels[K]>(
      object.kind as K,
    )
    const resident = collection.get(object.id)
    if (resident) {
      this.replace(object)
      return
    }
    this.batch(() => {
      collection.persistNonResident(object)
    })
  }

  /**
   * Wait until every write scheduled before or during this call has settled.
   * Sync cursors must call this before advancing so a crash can only cause
   * idempotent replay, never a cursor ahead of persisted objects.
   */
  async flushPersistence(): Promise<void> {
    if (this.batchDepth > 0) {
      throw new Error(
        "Cannot flush Inline persistence inside a database batch",
      )
    }

    await this.writesSettled(true)

    if (this.persistenceErrors.length > 0) {
      const errors = this.persistenceErrors.splice(0)
      throw new AggregateError(errors, "Inline database persistence failed")
    }
  }

  /** Open and migrate the account-owned store before product hydration. */
  async openPersistence(): Promise<void> {
    const closing = this.closePersistenceTask
    if (closing) await closing
    await this.persistenceStore?.open()
    this.persistenceState = "open"
    this.closePersistenceTask = null
  }

  /**
   * Flush accepted local work and release this account owner's durable handle.
   * The adapter may reopen if the same core is started again.
   */
  async closePersistence(): Promise<void> {
    if (this.closePersistenceTask) return this.closePersistenceTask
    this.persistenceState = "closing"
    const acceptedCommits = this.commitQueue
    const task = (async () => {
      const errors: unknown[] = []
      try {
        await acceptedCommits
        await this.flushPersistence()
      } catch (error) {
        errors.push(error)
      }
      try {
        await this.persistenceStore?.close()
      } catch (error) {
        errors.push(error)
      } finally {
        this.persistenceState = "closed"
      }
      if (errors.length === 1) throw errors[0]
      if (errors.length > 1) {
        throw new AggregateError(
          errors,
          "Inline database could not close cleanly",
        )
      }
    })()
    this.closePersistenceTask = task
    return task
  }

  private assertWritable() {
    if (
      this.persistenceState !== "open" &&
      !this.acceptedCommitRecipeActive
    ) {
      throw new Error("Inline database is closing")
    }
  }

  private notifyHydrated(results: Array<{ kind: DbObjectKind; objects: DbModels[DbObjectKind][] }>) {
    this.batch(() => {
      for (const { kind, objects } of results) {
        for (const object of objects) {
          this.notify(this.ref(kind, object.id))
        }
      }
    })
  }

  private readDeferredUpdatesForMessageKeys(targetKeys: string[]) {
    return this.collection<
      DbObjectKind.DeferredUpdate,
      DbModels[DbObjectKind.DeferredUpdate]
    >(DbObjectKind.DeferredUpdate).readDeferredTargetKeys(
      Array.from(new Set(targetKeys)),
    )
  }

  private admitDeferredUpdates(
    stored: DbModels[DbObjectKind.DeferredUpdate][],
    admission: DbReadAdmission,
  ) {
    return this.collection<
      DbObjectKind.DeferredUpdate,
      DbModels[DbObjectKind.DeferredUpdate]
    >(DbObjectKind.DeferredUpdate).admitStored(stored, admission)
      .inserted
  }

  /**
   * Window members of this chat that a write touched while a read was in
   * flight and that are still resident (for example a sent message that got
   * its server ID). A latest-window read that started earlier cannot know
   * them, so replacing the window from it must keep them.
   */
  private windowKeysWrittenDuringRead(
    chatId: ChatID,
    admission: DbReadAdmission,
  ): MessageKey[] {
    return this.fullChatWindows
      .keys(chatId)
      .filter(
        (key) =>
          admission.touched(DbObjectKind.Message, key) &&
          this.get(this.ref(DbObjectKind.Message, key)) != null,
      )
  }

  // Private
  private collection<K extends DbObjectKind, O extends DbModels[K]>(kind: K): Collection<K, O> {
    if (!this.collections[kind]) {
      const hasInjectedStorage =
        this.storageByKind != null &&
        Object.prototype.hasOwnProperty.call(this.storageByKind, kind)
      const storage = hasInjectedStorage
        ? (this.storageByKind?.[kind] as InlinePersistenceCollection<O> | null)
        : (this.persistenceStore?.collection(kind) as
            | InlinePersistenceCollection<O>
            | undefined) ?? null
      this.collections[kind] = new Collection<K, O>(
        kind,
        storage,
        !hasInjectedStorage && storage != null,
        (operation, fallback, usesPersistenceStore) =>
          this.schedulePersistence(
            operation,
            fallback,
            usesPersistenceStore,
          ),
        (collection, id, previous) =>
          this.recordUndo(collection, id, previous),
        (stamp) => this.recordStamp(stamp),
        this.logger.withScope(`Collection.${kind}`),
      )
    }
    return this.collections[kind] as Collection<K, O>
  }

  private schedulePersistence(
    operation: InlinePersistenceOperation,
    fallback: () => Promise<void>,
    usesPersistenceStore: boolean,
  ) {
    if (this.batchDepth === 0) {
      // Every write path opens a batch; a stray caller still gets one.
      this.batch(() => {
        this.schedulePersistence(
          operation,
          fallback,
          usesPersistenceStore,
        )
      })
      return
    }
    if (usesPersistenceStore) {
      this.pendingPersistenceOperations.push(operation)
    } else {
      this.pendingFallbackOperations.push(fallback)
    }
  }

  // ---- The ordered writer (invariant 6) ----

  private openWrite() {
    this.undoJournal.clear()
    this.pendingRefs.clear()
    this.pendingPersistenceOperations = []
    this.pendingFallbackOperations = []
    this.pendingStamps = []
  }

  /**
   * Turn the open recipe into an accepted write. Called with memory already
   * changed. Returns undefined when the recipe changed nothing at all.
   */
  private acceptWrite(implicit: boolean): DbWriteEntry | undefined {
    const refs = Array.from(this.pendingRefs)
    const undo = Array.from(this.undoJournal.values())
    const operations = this.pendingPersistenceOperations
    const fallbacks = this.pendingFallbackOperations
    const stamps = this.pendingStamps
    this.openWrite()
    if (
      refs.length === 0 &&
      undo.length === 0 &&
      operations.length === 0 &&
      fallbacks.length === 0
    ) {
      return undefined
    }

    let resolve!: () => void
    let reject!: (error: unknown) => void
    const promise = new Promise<void>((settle, fail) => {
      resolve = settle
      reject = fail
    })
    // Implicit writes report failures through flushPersistence.
    promise.catch(ignoreRejection)
    const entry: DbWriteEntry = {
      undo,
      refs,
      changes: this.captureChanges(refs),
      operations,
      fallbacks,
      stamps,
      implicit,
      promise,
      resolve,
      reject,
    }

    if (
      operations.length === 0 &&
      fallbacks.length === 0 &&
      this.writeQueue.length === 0
    ) {
      // Nothing to persist and nothing ahead of it: already "committed".
      this.publish(entry.refs, entry.changes)
      entry.resolve()
      return entry
    }

    this.writeQueue.push(entry)
    this.drainWrites()
    return entry
  }

  private drainWrites() {
    if (this.draining) return
    this.draining = true
    void this.drainWriteQueue()
  }

  private async drainWriteQueue() {
    try {
      while (this.writeQueue.length > 0) {
        const entry = this.writeQueue[0]!
        if (
          entry.operations.length > 0 ||
          entry.fallbacks.length > 0
        ) {
          try {
            await this.persistWrite(entry)
          } catch (error) {
            this.failQueuedWrites(error)
            continue
          }
        }
        this.writeQueue.shift()
        this.publish(entry.refs, entry.changes)
        entry.resolve()
      }
    } finally {
      this.draining = false
    }
  }

  private async persistWrite(entry: DbWriteEntry) {
    const persistence: Promise<void>[] = []
    if (entry.operations.length > 0) {
      persistence.push(
        this.persistenceStore!.write(entry.operations),
      )
    }
    for (const fallback of entry.fallbacks) {
      persistence.push(Promise.resolve().then(fallback))
    }
    await Promise.all(persistence)
  }

  /**
   * Storage rejected the head write. Nothing behind it has reached storage,
   * and some of it may have been computed from the failed write's memory,
   * so every queued write that persists something is undone, newest first,
   * and rejected. Memory is then equal to what has committed. Observers
   * never heard of the undone writes, so nothing is published for them.
   * Memory-only changes queued behind the failure (rows read from disk,
   * evictions) are not undone; they are published now, with current values.
   */
  private failQueuedWrites(error: unknown) {
    const queued = this.writeQueue.splice(0)
    const persists = (entry: DbWriteEntry) =>
      entry.operations.length > 0 || entry.fallbacks.length > 0
    const failed = queued.filter(persists)
    for (const entry of failed.slice().reverse()) {
      this.restoreUndoEntries(entry.undo)
    }

    const memoryOnly = new Set<DbObjectRef<DbObjectKind>>()
    for (const entry of queued) {
      if (persists(entry)) continue
      for (const ref of entry.refs) memoryOnly.add(ref)
      entry.resolve()
    }
    const republished = Array.from(memoryOnly)
    this.publish(republished, this.captureChanges(republished))

    let reportedImplicitFailure = false
    for (const entry of failed) {
      if (entry.implicit) {
        if (!reportedImplicitFailure) {
          this.persistenceErrors.push(error)
          reportedImplicitFailure = true
        }
        entry.reject(error)
      } else {
        entry.reject(new DatabaseCommitError(error))
      }
    }
  }

  /**
   * Wait until every write accepted before this call has settled. With
   * `untilIdle`, also wait for writes accepted while waiting.
   */
  private async writesSettled(untilIdle = false) {
    let tail = this.writeQueue.at(-1)
    while (tail) {
      await tail.promise.catch(ignoreRejection)
      if (!untilIdle) return
      tail = this.writeQueue.at(-1)
    }
  }

  private captureChanges(
    refs: readonly DbObjectRef<DbObjectKind>[],
  ): DbResidentChange[] {
    return refs.map((ref) => {
      const object = this.get(ref) as DbModel | undefined
      return {
        kind: ref.kind,
        id: ref.id,
        ...(object ? { object } : {}),
      }
    })
  }

  private publish(
    refs: readonly DbObjectRef<DbObjectKind>[],
    changes: DbResidentChange[],
  ) {
    if (refs.length === 0) return
    // The resident stream goes first: a callback below may write, and its
    // batch must carry a higher revision than this one.
    this.emitResidentChanges(changes)
    const affectedKinds = new Set<DbObjectKind>()
    for (const ref of refs) {
      affectedKinds.add(ref.kind)
      this.triggerObjectSubscriptions(ref)
    }
    for (const kind of affectedKinds) {
      this.triggerKindQueries(kind)
    }
  }

  // ---- Read admission (invariant 13) ----

  private beginRead(): DbReadAdmission {
    const admission = new DbReadAdmission()
    for (const entry of this.writeQueue) {
      for (const stamp of entry.stamps) admission.stamp(stamp)
    }
    if (this.batchDepth > 0) {
      for (const stamp of this.pendingStamps) admission.stamp(stamp)
    }
    this.activeReads.add(admission)
    return admission
  }

  private endRead(admission: DbReadAdmission) {
    this.activeReads.delete(admission)
  }

  private recordStamp(stamp: DbReadStamp) {
    if (this.batchDepth > 0) this.pendingStamps.push(stamp)
    for (const admission of this.activeReads) {
      admission.stamp(stamp)
    }
  }

  private recordUndo(
    collection: Collection<
      DbObjectKind,
      DbModels[DbObjectKind]
    >,
    id: DbModel["id"],
    previous: DbModel | undefined,
  ) {
    if (this.batchDepth === 0) return
    const key = `${collection.kind}\0${String(id)}`
    if (this.undoJournal.has(key)) return
    this.undoJournal.set(key, {
      collection,
      id,
      previous,
    })
  }

  private rollbackBatch() {
    const entries = Array.from(this.undoJournal.values())
    this.openWrite()
    this.restoreUndoEntries(entries)
  }

  private restoreUndoEntries(entries: UndoEntry[]) {
    for (const entry of entries.slice().reverse()) {
      entry.collection.restoreLocal(entry.id, entry.previous)
      // A read in flight must not trust either the undone value or the
      // disk row it may have read meanwhile.
      if (this.activeReads.size > 0) {
        this.recordStamp({
          type: "write",
          kind: entry.collection.kind,
          id: entry.id,
          value: null,
        })
      }
    }
  }

  private emitResidentChanges(changes: DbResidentChange[]) {
    if (
      changes.length === 0 ||
      this.residentChangeListeners.size === 0
    ) {
      return
    }

    const batch = {
      revision: ++this.residentRevision,
      changes,
    }
    for (const listener of this.residentChangeListeners) {
      listener(batch)
    }
  }
}

type UndoEntry = {
  collection: Collection<
    DbObjectKind,
    DbModels[DbObjectKind]
  >
  id: DbModel["id"]
  previous: DbModel | undefined
}

class Collection<K extends DbObjectKind, O extends DbModels[K] = DbModels[K]> {
  kind: K
  ids: Set<O["id"]> = new Set()
  objectsById: Map<O["id"], O> = new Map()
  // stable refs by ID
  refs: Map<O["id"], DbObjectRef<K>> = new Map()
  hasHydrated = false
  private hydrationPromise: Promise<O[]> | null = null
  private storage: InlinePersistenceCollection<O> | null

  constructor(
    kind: K,
    storage: InlinePersistenceCollection<O> | null,
    private readonly usesPersistenceStore: boolean,
    private readonly schedulePersistence: (
      operation: InlinePersistenceOperation,
      fallback: () => Promise<void>,
      usesPersistenceStore: boolean,
    ) => void,
    private readonly recordUndo: (
      collection: Collection<
        DbObjectKind,
        DbModels[DbObjectKind]
      >,
      id: DbModel["id"],
      previous: DbModel | undefined,
    ) => void,
    private readonly recordStamp: (stamp: DbReadStamp) => void,
    private readonly logger: Log,
  ) {
    this.kind = kind
    this.storage = storage
  }

  ref(id: O["id"]): DbObjectRef<K> {
    let ref = this.refs.get(id)
    if (!ref) {
      ref = { kind: this.kind, id } as DbObjectRef<K>
      this.refs.set(id, ref)
    }
    return ref
  }

  insert(object: O) {
    this.insertLocal(object)
    this.persistPut(object)
  }

  replace(object: O) {
    this.insertLocal(object)
    this.persistPut(object)
  }

  private insertLocal(object: O) {
    this.recordBeforeChange(
      object.id,
      this.objectsById.get(object.id),
    )
    this.ids.add(object.id)
    // Insert is a replace if the object already exists.
    this.objectsById.set(object.id, object)
  }

  delete(id: O["id"]) {
    this.recordBeforeChange(id, this.objectsById.get(id))
    this.ids.delete(id)
    this.objectsById.delete(id)
    this.persistDelete(id)
  }

  clearMessagesForChat(chatId: ChatID): O["id"][] {
    const removedIds: O["id"][] = []
    for (const id of this.ids) {
      const object = this.objectsById.get(id)
      if (!object || !("chatId" in object) || object.chatId !== chatId) continue
      this.recordBeforeChange(id, object)
      this.ids.delete(id)
      this.objectsById.delete(id)
      removedIds.push(id)
    }

    if (this.storage) {
      this.recordStamp({ type: "clear-chat", chatId })
      this.schedulePersistence(
        { type: "deleteMessagesByChat", chatId },
        () =>
          this.storage!.deleteAllByChatId
            ? this.storage!.deleteAllByChatId(chatId)
            : Promise.reject(
                new Error(
                  `Storage for ${this.kind} cannot clear unloaded chat history`,
                ),
              ),
        this.usesPersistenceStore,
      )
    }

    return removedIds
  }

  update(object: O): O {
    const merged = this.updateLocal(object)
    this.persistPut(merged)
    return merged
  }

  private updateLocal(object: O): O {
    const existing = this.objectsById.get(object.id)
    if (!existing) {
      this.insertLocal(object)
      return object
    }

    this.recordBeforeChange(object.id, existing)
    const merged = { ...existing }
    for (const [key, value] of Object.entries(object) as [keyof O, O[keyof O]][]) {
      if (value !== undefined) {
        merged[key] = value
      }
    }

    this.objectsById.set(object.id, merged)
    return merged
  }

  get(id: O["id"]): O | undefined {
    return this.objectsById.get(id)
  }

  insertResident(object: O) {
    if (this.objectsById.has(object.id)) return false
    this.insertLocal(object)
    return true
  }

  getAll(predicate: (object: O) => boolean = () => true): O[] {
    // optimize memory???
    let objects: O[] = []
    for (const id of this.ids) {
      const object = this.objectsById.get(id)
      if (object && predicate(object)) {
        objects.push(object)
      }
    }
    return objects
  }

  getAllRefs(predicate: (object: O) => boolean = () => true): DbObjectRef<K>[] {
    let refs: DbObjectRef<K>[] = []
    for (const id of this.ids) {
      const object = this.objectsById.get(id)
      if (object && predicate(object)) {
        refs.push(this.ref(id))
      }
    }
    return refs
  }

  /**
   * Admit stored rows into memory in one synchronous step (invariant 13).
   * A resident row always wins; otherwise the read's admission decides
   * between the stored row, a newer stamped value, or nothing. Returns the
   * reconciled view of the read (what memory now holds for each row that
   * survives) and the rows newly made resident.
   */
  admitStored(
    stored: readonly O[],
    admission: DbReadAdmission,
  ): { objects: O[]; inserted: O[] } {
    const objects: O[] = []
    const inserted: O[] = []
    for (const row of stored) {
      const resident = this.objectsById.get(row.id)
      if (resident) {
        objects.push(resident)
        continue
      }
      const admitted = admission.reconcile(this.kind, row)
      if (!admitted) continue
      this.insertLocal(admitted)
      inserted.push(admitted)
      objects.push(admitted)
    }
    return { objects, inserted }
  }

  /** The reconciled view of stored rows, without admitting anything. */
  reconcileStored(
    stored: readonly O[],
    admission: DbReadAdmission,
  ): O[] {
    return stored.flatMap((row) => {
      const current =
        this.objectsById.get(row.id) ??
        admission.reconcile(this.kind, row)
      return current ? [current] : []
    })
  }

  hydrate(admission: DbReadAdmission): Promise<O[]> {
    if (!this.storage) {
      this.logger.debug("storage.collection.unavailable", {
        kind: this.kind,
      })
      this.hasHydrated = true
      return Promise.resolve([])
    }
    if (this.hydrationPromise) return this.hydrationPromise

    this.hydrationPromise = (async () => {
      try {
        await this.storage!.init()
        const stored = await this.storage!.getAll()
        return this.admitStored(stored, admission).inserted
      } finally {
        this.hasHydrated = true
      }
    })()

    return this.hydrationPromise
  }

  async readMessageWindowByChatId(
    chatId: ChatID,
    limit: number,
    before?: MessageWindowCursor,
    after?: MessageWindowCursor,
  ): Promise<O[]> {
    if (!this.storage?.getMessageWindowByChatId) return []

    await this.storage.init()
    return await this.storage.getMessageWindowByChatId(
      chatId,
      limit,
      before,
      after,
    )
  }

  async scanChatMessages(
    chatId: ChatID,
    match: (object: O) => boolean,
    options: ChatMessageScanOptions,
  ): Promise<ChatMessageScan<O> | undefined> {
    if (!this.storage?.scanChatMessages) return undefined
    await this.storage.init()
    return await this.storage.scanChatMessages(chatId, match, options)
  }

  async readDeferredTargetKeys(targetKeys: string[]): Promise<O[]> {
    if (
      !this.storage?.getDeferredUpdatesByTargetKeys ||
      targetKeys.length === 0
    ) {
      return []
    }

    await this.storage.init()
    return await this.storage.getDeferredUpdatesByTargetKeys(
      targetKeys,
    )
  }

  async readDeferredUpdateTypes(updateTypes: string[]): Promise<O[]> {
    if (
      !this.storage?.getDeferredUpdatesByUpdateTypes ||
      updateTypes.length === 0
    ) {
      return []
    }
    await this.storage.init()
    return await this.storage.getDeferredUpdatesByUpdateTypes(updateTypes)
  }

  async loadLocalWindowAroundMessage(
    chatId: ChatID,
    messageId: MessageID,
    beforeLimit: number,
    afterLimit: number,
  ): Promise<O[]> {
    if (!this.storage?.getMessageWindowAroundMessageId) return []

    await this.storage.init()
    return await this.storage.getMessageWindowAroundMessageId(
      chatId,
      messageId,
      beforeLimit,
      afterLimit,
    )
  }

  replaceResidentMessagesForChat(
    chatId: ChatID,
    objects: O[],
  ): O["id"][] {
    const incomingIds = new Set(objects.map((object) => object.id))
    const changedIds = new Set<O["id"]>()

    for (const id of this.ids) {
      const object = this.objectsById.get(id)
      if (
        !object ||
        !("chatId" in object) ||
        object.chatId !== chatId ||
        incomingIds.has(id)
      ) {
        continue
      }
      this.recordBeforeChange(id, object)
      this.ids.delete(id)
      this.objectsById.delete(id)
      changedIds.add(id)
    }

    for (const object of objects) {
      if (this.objectsById.get(object.id) === object) continue
      this.insertLocal(object)
      changedIds.add(object.id)
    }
    return Array.from(changedIds)
  }

  retainResidentMessagesForChat(
    chatId: ChatID,
    retain: (object: O) => boolean,
  ): O["id"][] {
    const removedIds: O["id"][] = []
    for (const id of Array.from(this.ids)) {
      const object = this.objectsById.get(id)
      if (
        !object ||
        !("chatId" in object) ||
        object.chatId !== chatId ||
        retain(object)
      ) {
        continue
      }
      this.recordBeforeChange(id, object)
      this.ids.delete(id)
      this.objectsById.delete(id)
      removedIds.push(id)
    }
    return removedIds
  }

  private async readStoredRows(ids: O["id"][]): Promise<O[]> {
    if (!this.storage || ids.length === 0) return []
    await this.storage.init()
    if (this.storage.getMany) {
      return await this.storage.getMany(ids)
    }
    const objects: O[] = []
    for (const id of ids) {
      const object = await this.storage.get(id)
      if (object) objects.push(object)
    }
    return objects
  }

  async hydrateIds(
    ids: O["id"][],
    admission: DbReadAdmission,
  ): Promise<O[]> {
    const stored = await this.readStoredRows(ids)
    return this.admitStored(stored, admission).inserted
  }

  async readStoredIds(
    ids: O["id"][],
    admission: DbReadAdmission,
  ): Promise<O[]> {
    if (ids.length === 0) return []

    const missing = ids.filter((id) => !this.objectsById.has(id))
    const found = new Map<O["id"], O>()
    for (const object of this.reconcileStored(
      await this.readStoredRows(missing),
      admission,
    )) {
      found.set(object.id, object)
    }

    return ids.flatMap((id) => {
      const object = this.objectsById.get(id) ?? found.get(id)
      return object ? [object] : []
    })
  }

  /** Delete stored (possibly unloaded) rows of a chat in an ID range. */
  deleteStoredInRange(
    chatId: ChatID,
    from: bigint,
    to: bigint,
    keep: ReadonlySet<string>,
  ) {
    if (!this.storage) return
    this.recordStamp({ type: "clear-range", chatId, from, to, keep })
    this.schedulePersistence(
      {
        type: "deleteMessagesInRange",
        chatId,
        fromId: messageId(from),
        toId: messageId(to),
        keep: Array.from(keep, (id) => messageId(id)),
      },
      // Injected per-kind test adapters have no range delete; the resident
      // rows were removed individually.
      () => Promise.resolve(),
      this.usesPersistenceStore,
    )
  }

  persistNonResident(object: O) {
    this.persistPut(object)
  }

  private persistPut(object: O) {
    if (!this.storage) return
    this.recordStamp({
      type: "write",
      kind: this.kind,
      id: object.id,
      value: object,
    })
    this.schedulePersistence(
      { type: "put", object },
      () => this.storage!.put(object),
      this.usesPersistenceStore,
    )
  }

  private persistDelete(id: O["id"]) {
    if (!this.storage) return
    this.recordStamp({
      type: "write",
      kind: this.kind,
      id,
      value: null,
    })
    this.schedulePersistence(
      { type: "delete", kind: this.kind, id },
      () => this.storage!.delete(id),
      this.usesPersistenceStore,
    )
  }

  restoreLocal(id: DbModel["id"], previous: DbModel | undefined) {
    const exactId = id as O["id"]
    if (previous == null) {
      this.ids.delete(exactId)
      this.objectsById.delete(exactId)
      return
    }
    this.ids.add(exactId)
    this.objectsById.set(exactId, previous as O)
  }

  private recordBeforeChange(
    id: O["id"],
    previous: O | undefined,
  ) {
    this.recordUndo(
      this as unknown as Collection<
        DbObjectKind,
        DbModels[DbObjectKind]
      >,
      id,
      previous,
    )
  }
}

type QueryKey = string

class Queries {
  // Current state
  private queries: Map<QueryKey, DbQueryPlan<DbObjectKind, DbModels[DbObjectKind]>> = new Map()
  private queriesByKind: Map<DbObjectKind, Set<QueryKey>> = new Map()
  private subscriptions: Map<QueryKey, Set<() => void>> = new Map()

  // Cache
  private cachedResults: Map<QueryKey, unknown> = new Map()
  private dirtyQueries: Set<QueryKey> = new Set()

  subscribe<K extends DbObjectKind, O extends DbModels[K]>(query: DbQueryPlan<K, O>, callback: () => void) {
    this.queries.set(query.key, query as unknown as DbQueryPlan<DbObjectKind, DbModels[DbObjectKind]>)
    this.queriesByKindSet(query.kind).add(query.key)
    this.subscriptionSet(query.key).add(callback)
    this.dirtyQueries.add(query.key) // Needs initial compute

    // Unsubscribe
    return {
      unsubscribe: () => {
        this.subscriptions.get(query.key)?.delete(callback)

        // Do this with a delay to avoid immediate deletion of the query if the callback is re-added immediately
        // TODO: create a garbage collection mechanism for house keeping instead of setTimeout on every unsubscribe
        setTimeout(() => {
          this.maybeDeleteQueryIfNoSubscriptions(query.key)
        }, 50)
      },
    }
  }

  getQueriesByKind<K extends DbObjectKind, O extends DbModels[K], P extends DbQueryPlan<K, O>>(kind: K): P[] {
    let queryKeys = this.queriesByKind.get(kind)
    if (!queryKeys) return []
    let queries: P[] = []
    for (const queryKey of queryKeys) {
      let query = this.queries.get(queryKey) as P | undefined
      if (!query) continue
      queries.push(query)
    }
    return queries
  }

  getCallbacksForKey(key: QueryKey): (() => void)[] {
    return Array.from(this.subscriptions.get(key) ?? new Set())
  }

  // Cache methods

  /** Mark all queries for a kind as dirty. Future: check predicates here. */
  markKindDirty(kind: DbObjectKind) {
    let queryKeys = this.queriesByKind.get(kind)
    if (!queryKeys) return
    for (const key of queryKeys) {
      this.dirtyQueries.add(key)
    }
  }

  isDirty(key: QueryKey): boolean {
    return this.dirtyQueries.has(key) || !this.cachedResults.has(key)
  }

  getCachedResult<T>(key: QueryKey): T | undefined {
    return this.cachedResults.get(key) as T | undefined
  }

  setCachedResult(key: QueryKey, result: unknown) {
    this.cachedResults.set(key, result)
    this.dirtyQueries.delete(key)
  }

  // Private
  private queriesByKindSet(kind: DbObjectKind): Set<QueryKey> {
    if (!this.queriesByKind.has(kind)) {
      this.queriesByKind.set(kind, new Set())
    }
    return this.queriesByKind.get(kind) as Set<QueryKey>
  }

  private subscriptionSet(key: QueryKey): Set<() => void> {
    if (!this.subscriptions.has(key)) {
      this.subscriptions.set(key, new Set())
    }
    return this.subscriptions.get(key)!
  }

  private deleteQuery<K extends DbObjectKind, O extends DbModels[K]>(key: QueryKey) {
    let query = this.queries.get(key) as DbQueryPlan<K, O> | undefined
    if (!query) return
    this.queries.delete(key)
    this.queriesByKindSet(query.kind).delete(key)
    this.cachedResults.delete(key)
    this.dirtyQueries.delete(key)
  }

  private maybeDeleteQueryIfNoSubscriptions(key: QueryKey) {
    if (this.subscriptions.get(key)?.size === 0) {
      this.deleteQuery(key)
    }
  }
}

// TODO: Improve type-safety of object here

class ObjectSubscriptions {
  private subscriptions: Map<DbObjectRef<DbObjectKind>, Set<() => void>> = new Map()

  subscribe<K extends DbObjectKind>(ref: DbObjectRef<K>, callback: () => void) {
    this.subscriptionSet(ref).add(callback)

    return {
      unsubscribe: () => {
        this.subscriptionSet(ref).delete(callback)
      },
    }
  }

  getSubscriptionsForRef<K extends DbObjectKind>(ref: DbObjectRef<K>): Set<() => void> {
    return this.subscriptions.get(ref) ?? new Set()
  }

  private subscriptionSet(ref: DbObjectRef<DbObjectKind>): Set<() => void> {
    if (!this.subscriptions.has(ref)) {
      this.subscriptions.set(ref, new Set())
    }
    return this.subscriptions.get(ref)!
  }
}
