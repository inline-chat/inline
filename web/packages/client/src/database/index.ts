import { type ChatID, type MessageID } from "@inline/ids"
import {
  type DbModel,
  DbModels,
  DbObjectKind,
  MessageSendingStatus,
  type MessageKey,
} from "./models"
import { FullChatWindowState } from "./full-chat-window"
import {
  type CollectionStorage,
  createIndexedDbPersistenceStore,
} from "./storage"
import type {
  InlinePersistenceOperation,
  InlinePersistenceStore,
} from "./persistence"
import { type DbObjectId, DbObjectRef, DbQueryPlan, DbQueryPlanType } from "./types"
import {
  compareMessagesByWindow,
  type MessageWindowCursor,
} from "./message-window"

export type DbStorageByKind = Partial<{
  [K in DbObjectKind]: CollectionStorage<DbModels[K]> | null
}>

export type DbOptions = {
  storageByKind?: DbStorageByKind
  storageNamespace?: string
  /**
   * Account-owned persistence adapter. Passing `null` creates an in-memory
   * projection. When omitted, Db retains the IndexedDB compatibility default.
   */
  persistenceStore?: InlinePersistenceStore | null
  autoHydrate?: boolean
  /**
   * Disable the default IndexedDB owner entirely. Use this for read
   * projections that are populated by another process (for example a
   * renderer mirror of the SharedWorker-owned account core).
   */
  persistence?: boolean
}

export type MessageWindowOptions = {
  limit: number
  before?: MessageWindowCursor
  after?: MessageWindowCursor
}

export type LocalMessageWindowAroundOptions = {
  messageId: MessageID
  beforeLimit: number
  afterLimit: number
}

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
] as const

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
  hasHydrated = false
  hydrationState: "pending" | "skipped" | "done" | "failed"

  // Batching
  private batchDepth = 0
  private pendingRefs: Set<DbObjectRef<DbObjectKind>> = new Set()
  private pendingPersistenceOperations: InlinePersistenceOperation[] = []
  private pendingFallbackOperations: Array<() => Promise<void>> = []
  private undoJournal = new Map<string, UndoEntry>()
  private hydrationPromise: Promise<void> | null = null
  private storageByKind?: DbStorageByKind
  private persistenceStore: InlinePersistenceStore | null
  private pendingPersistence = new Set<Promise<void>>()
  private persistenceErrors: unknown[] = []
  private commitQueue: Promise<void> = Promise.resolve()
  private residentRevision = 0
  private residentChangeListeners = new Set<
    (batch: DbResidentChangeBatch) => void
  >()

  constructor(options: DbOptions = {}) {
    const autoHydrate = options.autoHydrate ?? true
    this.storageByKind = options.storageByKind
    this.persistenceStore =
      options.persistenceStore !== undefined
        ? options.persistenceStore
        : options.persistence === false
          ? null
          : createIndexedDbPersistenceStore(
              options.storageNamespace,
            )
    this.hasHydrated = !autoHydrate
    this.hydrationState = autoHydrate ? "pending" : "skipped"
    this.ready = autoHydrate ? this.hydrate() : Promise.resolve()
  }

  insert<K extends DbObjectKind, O extends DbModels[K]>(object: O) {
    this.collection(object.kind).insert(object)
    this.notify(this.ref(object.kind, object.id))
  }

  /** Replace a complete object, including clearing optional fields. */
  replace<K extends DbObjectKind, O extends DbModels[K]>(object: O) {
    this.collection(object.kind).replace(object)
    this.notify(this.ref(object.kind, object.id))
  }

  delete(ref: DbObjectRef<DbObjectKind>) {
    this.collection(ref.kind).delete(ref.id)
    this.notify(ref)
  }

  /**
   * Remove every message for a chat from memory and persistence. The storage
   * operation uses the chat/message index, so unloaded history cannot return
   * during a later selective hydration.
   */
  clearMessagesForChat(chatId: ChatID) {
    const collection = this.collection<
      DbObjectKind.Message,
      DbModels[DbObjectKind.Message]
    >(DbObjectKind.Message)
    const removedIds = collection.clearMessagesForChat(chatId)

    if (removedIds.length === 0) return
    for (const id of removedIds) {
      this.notify(this.ref(DbObjectKind.Message, id))
    }
  }

  update<K extends DbObjectKind, O extends DbModels[K]>(object: O) {
    this.collection(object.kind).update(object)
    this.notify(this.ref(object.kind, object.id))
  }

  /**
   * Apply an in-memory mutation transaction and persist account-store
   * operations in one adapter transaction. Synchronous failure restores the
   * previous memory state before any observer is notified.
   */
  batch(fn: () => void): void {
    const outermost = this.batchDepth === 0
    if (outermost) {
      this.undoJournal.clear()
      this.pendingPersistenceOperations = []
      this.pendingFallbackOperations = []
    }

    this.batchDepth++
    let succeeded = false
    try {
      fn()
      succeeded = true
    } finally {
      this.batchDepth--
      if (outermost && succeeded) {
        this.commitPendingPersistence()
        this.flushPendingNotifications()
        this.undoJournal.clear()
      } else if (outermost) {
        this.rollbackBatch()
      }
    }
  }

  /**
   * Serialize a mutation recipe with its persistence commit. Unlike `batch`,
   * observers are notified only after storage accepts the transaction; an
   * asynchronous storage failure restores the complete in-memory recipe.
   *
   * Production collections share one persistence transaction. Injected
   * per-kind test adapters retain their compatibility behavior and cannot
   * provide cross-adapter disk atomicity.
   */
  commit(fn: () => void): Promise<void> {
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
    await this.flushPersistence()

    this.undoJournal.clear()
    this.pendingPersistenceOperations = []
    this.pendingFallbackOperations = []
    this.pendingRefs.clear()
    this.batchDepth = 1
    try {
      fn()
    } catch (error) {
      this.batchDepth = 0
      this.rollbackBatch()
      throw error
    }
    this.batchDepth = 0

    const undoEntries = Array.from(
      this.undoJournal.values(),
    )
    const changedRefs = new Set(this.pendingRefs)
    this.pendingRefs.clear()
    const persistence = this.commitPendingPersistence(false)
    this.undoJournal.clear()

    try {
      await Promise.all(persistence)
      this.notifyCommittedRefs(changedRefs)
    } catch (error) {
      this.restoreUndoEntries(undoEntries)
      throw new DatabaseCommitError(error)
    }
  }

  private notify<K extends DbObjectKind>(ref: DbObjectRef<K>) {
    if (this.batchDepth > 0) {
      this.pendingRefs.add(ref)
    } else {
      this.triggerQueries(ref)
      this.triggerObjectSubscriptions(ref)
      this.emitResidentChanges(
        new Set<DbObjectRef<DbObjectKind>>([
          ref as DbObjectRef<DbObjectKind>,
        ]),
      )
    }
  }

  private flushPendingNotifications() {
    if (this.pendingRefs.size === 0) return

    const changedRefs = new Set(this.pendingRefs)
    // Collect affected kinds for query invalidation
    let affectedKinds = new Set<DbObjectKind>()
    for (const ref of this.pendingRefs) {
      affectedKinds.add(ref.kind)
      this.triggerObjectSubscriptions(ref)
    }

    // Invalidate and notify queries once per kind
    for (const kind of affectedKinds) {
      this.querySubscriptions.markKindDirty(kind)
      let queriesForKind = this.querySubscriptions.getQueriesByKind(kind)
      for (const query of queriesForKind) {
        let callbacks = this.querySubscriptions.getCallbacksForKey(query.key)
        for (let callback of callbacks) {
          callback()
        }
      }
    }

    this.pendingRefs.clear()
    this.emitResidentChanges(changedRefs)
  }

  subscribeToResidentChanges(
    listener: (batch: DbResidentChangeBatch) => void,
  ) {
    this.residentChangeListeners.add(listener)
    return () => {
      this.residentChangeListeners.delete(listener)
    }
  }

  residentSnapshot(
    kinds: readonly DbObjectKind[] = Object.values(
      DbObjectKind,
    ),
  ): DbResidentSnapshot {
    const objects: DbModel[] = []
    for (const kind of kinds) {
      objects.push(
        ...this.queryCollection(
          DbQueryPlanType.Objects,
          kind,
        ),
      )
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

  private triggerQueries<K extends DbObjectKind>(ref: DbObjectRef<K>) {
    // Mark all queries for this kind as dirty
    // Future: check predicates here to skip unaffected queries
    this.querySubscriptions.markKindDirty(ref.kind)

    // Notify subscribers
    let queriesForKind = this.querySubscriptions.getQueriesByKind(ref.kind)
    for (const query of queriesForKind) {
      let callbacks = this.querySubscriptions.getCallbacksForKey(query.key)
      for (let callback of callbacks) {
        callback()
      }
    }
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
        const results = await Promise.all(
          DEFAULT_HYDRATION_KINDS.map(async (kind) => {
            const collection = this.collection(kind)
            const objects = await collection.hydrate()
            return { kind, objects }
          }),
        )

        this.batch(() => {
          for (const { kind, objects } of results) {
            for (const object of objects) {
              this.notify(this.ref(kind, object.id))
            }
          }
        })
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
    const results = await Promise.all(
      kinds.map(async (kind) => {
        const objects = await this.collection(kind).hydrate()
        return { kind, objects }
      }),
    )
    this.notifyHydrated(results)
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
    const collection = this.collection<DbObjectKind.Message, DbModels[DbObjectKind.Message]>(
      DbObjectKind.Message,
    )
    const { objects, inserted } =
      await collection.hydrateMessageWindowByChatId(
        chatId,
        options.limit,
        options.before,
        options.after,
      )
    const deferred = await this.loadDeferredUpdatesForMessageKeys(
      objects.map((message) => message.id),
    )
    if (this.fullChatWindows.isActive(chatId)) {
      const beforeKeys = this.fullChatWindows.keys(chatId)
      if (options.before == null && options.after == null) {
        this.fullChatWindows.replace(
          chatId,
          objects.map((message) => message.id),
          true,
        )
      } else {
        this.fullChatWindows.extend(
          chatId,
          objects.map((message) => message.id),
        )
      }
      this.notifyMessageWindowMembership(
        beforeKeys,
        this.fullChatWindows.keys(chatId),
      )
    }
    this.notifyHydrated([
      { kind: DbObjectKind.DeferredUpdate, objects: deferred },
      { kind: DbObjectKind.Message, objects: inserted },
    ])
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
      )
    ).found
  }

  async loadLocalWindowAroundMessageDetails(
    chatId: ChatID,
    options: LocalMessageWindowAroundOptions,
    replaceResidentWindow = true,
  ): Promise<{ found: boolean; messageKeys: MessageKey[] }> {
    const collection = this.collection<
      DbObjectKind.Message,
      DbModels[DbObjectKind.Message]
    >(DbObjectKind.Message)
    const objects = await collection.loadLocalWindowAroundMessage(
      chatId,
      options.messageId,
      options.beforeLimit,
      options.afterLimit,
    )
    if (objects.length === 0) {
      return { found: false, messageKeys: [] }
    }

    const deferred = await this.loadDeferredUpdatesForMessageKeys(
      objects.map((message) => message.id),
    )

    if (this.fullChatWindows.isActive(chatId)) {
      const beforeKeys = this.fullChatWindows.keys(chatId)
      this.fullChatWindows.replace(
        chatId,
        objects.map((message) => message.id),
        false,
      )
      this.notifyMessageWindowMembership(
        beforeKeys,
        this.fullChatWindows.keys(chatId),
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
    return {
      found: objects.some(
        (message) => message.messageId === options.messageId,
      ),
      messageKeys: objects.map((message) => message.id),
    }
  }

  /**
   * Release an inactive FullChatProgressive history window from memory while
   * preserving its durable IndexedDB rows. The sidebar's last message and
   * local send state remain resident. A reaction intent is owner-local and
   * deliberately non-persistent, so reclamation defers until it settles.
   */
  releaseResidentMessageWindow(chatId: ChatID): number {
    this.fullChatWindows.release(chatId)
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
    return this.fullChatWindows.activate(
      chatId,
      collection
        .getAll((message) => message.chatId === chatId)
        .map((message) => message.id),
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
    const objects = await this.collection<K, DbModels[K]>(kind).hydrateIds(uniqueIds)
    const deferred =
      kind === DbObjectKind.Message
        ? await this.loadDeferredUpdatesForMessageKeys(
            objects.map((object) => String(object.id)),
          )
        : []
    this.notifyHydrated([
      { kind: DbObjectKind.DeferredUpdate, objects: deferred },
      { kind, objects },
    ])
    return objects.length
  }

  /**
   * Selectively materialize deferred sidecars for the supplied message keys.
   * The IndexedDB target index keeps RPC/sync preparation proportional to the
   * payload being applied rather than the account's deferred-update history.
   */
  async hydrateDeferredUpdatesForMessageKeys(
    targetKeys: string[],
  ): Promise<number> {
    const objects = await this.loadDeferredUpdatesForMessageKeys(
      targetKeys,
    )
    this.notifyHydrated([
      { kind: DbObjectKind.DeferredUpdate, objects },
    ])
    return objects.length
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
    return this.collection<K, DbModels[K]>(kind).readStoredIds(
      Array.from(new Set(ids)),
    )
  }

  /** Persist a side-reference object without hydrating it into memory. */
  storeNonResidentObject<K extends DbObjectKind>(
    object: DbModels[K],
  ) {
    const collection = this.collection<K, DbModels[K]>(
      object.kind as K,
    )
    const resident = collection.get(object.id)
    if (resident) {
      this.replace(object)
      return
    }
    collection.persistNonResident(object)
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

    while (this.pendingPersistence.size > 0) {
      await Promise.all(this.pendingPersistence)
    }

    if (this.persistenceErrors.length > 0) {
      const errors = this.persistenceErrors.splice(0)
      throw new AggregateError(errors, "Inline database persistence failed")
    }
  }

  /** Open and migrate the account-owned store before product hydration. */
  async openPersistence(): Promise<void> {
    await this.persistenceStore?.open()
  }

  /**
   * Flush accepted local work and release this account owner's durable handle.
   * The adapter may reopen if the same core is started again.
   */
  async closePersistence(): Promise<void> {
    await this.flushPersistence()
    await this.persistenceStore?.close()
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

  private loadDeferredUpdatesForMessageKeys(
    targetKeys: string[],
  ) {
    return this.collection<
      DbObjectKind.DeferredUpdate,
      DbModels[DbObjectKind.DeferredUpdate]
    >(DbObjectKind.DeferredUpdate).hydrateDeferredTargetKeys(
      Array.from(new Set(targetKeys)),
    )
  }

  // Private
  private collection<K extends DbObjectKind, O extends DbModels[K]>(kind: K): Collection<K, O> {
    if (!this.collections[kind]) {
      const hasInjectedStorage =
        this.storageByKind != null &&
        Object.prototype.hasOwnProperty.call(this.storageByKind, kind)
      const storage = hasInjectedStorage
        ? (this.storageByKind?.[kind] as CollectionStorage<O> | null)
        : (this.persistenceStore?.collection(kind) as
            | CollectionStorage<O>
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
      )
    }
    return this.collections[kind] as Collection<K, O>
  }

  private trackPersistence(operation: Promise<void>) {
    const tracked = operation.catch((error: unknown) => {
      this.persistenceErrors.push(error)
    })
    this.pendingPersistence.add(tracked)
    void tracked.then(() => {
      this.pendingPersistence.delete(tracked)
    })
  }

  private schedulePersistence(
    operation: InlinePersistenceOperation,
    fallback: () => Promise<void>,
    usesPersistenceStore: boolean,
  ) {
    if (this.batchDepth > 0) {
      if (usesPersistenceStore) {
        this.pendingPersistenceOperations.push(operation)
      } else {
        this.pendingFallbackOperations.push(fallback)
      }
      return
    }

    this.trackPersistence(
      usesPersistenceStore
        ? this.persistenceStore!.write([operation])
        : Promise.resolve().then(fallback),
    )
  }

  private commitPendingPersistence(
    track = true,
  ): Promise<void>[] {
    const persistenceOperations = this.pendingPersistenceOperations
    const fallbackOperations = this.pendingFallbackOperations
    this.pendingPersistenceOperations = []
    this.pendingFallbackOperations = []
    const persistence: Promise<void>[] = []

    if (persistenceOperations.length > 0) {
      persistence.push(
        this.persistenceStore!.write(persistenceOperations),
      )
    }
    if (fallbackOperations.length > 0) {
      persistence.push(
        Promise.all(
          fallbackOperations.map((operation) =>
            Promise.resolve().then(operation),
          ),
        ).then(() => undefined),
      )
    }
    if (track) {
      for (const operation of persistence) {
        this.trackPersistence(operation)
      }
    }
    return persistence
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
    this.restoreUndoEntries(
      Array.from(this.undoJournal.values()),
    )
    this.undoJournal.clear()
    this.pendingRefs.clear()
    this.pendingPersistenceOperations = []
    this.pendingFallbackOperations = []
  }

  private restoreUndoEntries(entries: UndoEntry[]) {
    for (const entry of entries.slice().reverse()) {
      entry.collection.restoreLocal(entry.id, entry.previous)
    }
  }

  private notifyCommittedRefs(
    refs: Set<DbObjectRef<DbObjectKind>>,
  ) {
    for (const ref of refs) this.pendingRefs.add(ref)
    this.flushPendingNotifications()
  }

  private emitResidentChanges(
    refs: Set<DbObjectRef<DbObjectKind>>,
  ) {
    if (
      refs.size === 0 ||
      this.residentChangeListeners.size === 0
    ) {
      return
    }

    const changes: DbResidentChange[] = []
    for (const ref of refs) {
      const object = this.get(
        ref,
      ) as DbModel | undefined
      changes.push({
        kind: ref.kind,
        id: ref.id,
        ...(object ? { object } : {}),
      })
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
  private storage: CollectionStorage<O> | null

  constructor(
    kind: K,
    storage: CollectionStorage<O> | null,
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

  async hydrate(): Promise<O[]> {
    if (!this.storage) {
      console.error("No storage for collection", this.kind)
      this.hasHydrated = true
      return []
    }
    if (this.hydrationPromise) return this.hydrationPromise

    this.hydrationPromise = (async () => {
      try {
        await this.storage!.init()
        const objects = await this.storage!.getAll()
        const inserted: O[] = []
        for (const object of objects) {
          if (this.objectsById.has(object.id)) continue
          this.insertLocal(object)
          inserted.push(object)
        }
        return inserted
      } finally {
        this.hasHydrated = true
      }
    })()

    return this.hydrationPromise
  }

  async hydrateMessageWindowByChatId(
    chatId: ChatID,
    limit: number,
    before?: MessageWindowCursor,
    after?: MessageWindowCursor,
  ): Promise<{ objects: O[]; inserted: O[] }> {
    if (!this.storage?.getMessageWindowByChatId) {
      return { objects: [], inserted: [] }
    }

    await this.storage.init()
    const objects =
      await this.storage.getMessageWindowByChatId(
        chatId,
        limit,
        before,
        after,
      )
    const inserted: O[] = []
    for (const object of objects) {
      if (this.objectsById.has(object.id)) continue
      this.insertLocal(object)
      inserted.push(object)
    }
    return { objects, inserted }
  }

  async hydrateDeferredTargetKeys(
    targetKeys: string[],
  ): Promise<O[]> {
    if (
      !this.storage?.getDeferredUpdatesByTargetKeys ||
      targetKeys.length === 0
    ) {
      return []
    }

    await this.storage.init()
    const objects =
      await this.storage.getDeferredUpdatesByTargetKeys(
        targetKeys,
      )
    const inserted: O[] = []
    for (const object of objects) {
      if (this.objectsById.has(object.id)) continue
      this.insertLocal(object)
      inserted.push(object)
    }
    return inserted
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

  async hydrateIds(ids: O["id"][]): Promise<O[]> {
    if (!this.storage || ids.length === 0) return []

    await this.storage.init()
    let objects: O[]
    if (this.storage.getMany) {
      objects = await this.storage.getMany(ids)
    } else {
      objects = []
      for (const id of ids) {
        const object = await this.storage.get(id)
        if (object) objects.push(object)
      }
    }
    const inserted: O[] = []
    for (const object of objects) {
      if (this.objectsById.has(object.id)) continue
      this.insertLocal(object)
      inserted.push(object)
    }
    return inserted
  }

  async readStoredIds(ids: O["id"][]): Promise<O[]> {
    if (ids.length === 0) return []

    const found = new Map<O["id"], O>()
    const missing: O["id"][] = []
    for (const id of ids) {
      const resident = this.objectsById.get(id)
      if (resident) found.set(id, resident)
      else missing.push(id)
    }

    if (this.storage && missing.length > 0) {
      await this.storage.init()
      if (this.storage.getMany) {
        for (const object of await this.storage.getMany(missing)) {
          found.set(object.id, object)
        }
      } else {
        for (const id of missing) {
          const object = await this.storage.get(id)
          if (object) found.set(id, object)
        }
      }
    }

    return ids.flatMap((id) => {
      const object = found.get(id)
      return object ? [object] : []
    })
  }

  persistNonResident(object: O) {
    this.persistPut(object)
  }

  private persistPut(object: O) {
    if (!this.storage) return
    this.schedulePersistence(
      { type: "put", object },
      () => this.storage!.put(object),
      this.usesPersistenceStore,
    )
  }

  private persistDelete(id: O["id"]) {
    if (!this.storage) return
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
