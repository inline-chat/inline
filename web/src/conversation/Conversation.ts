import {
  DbObjectKind,
  DbQueryPlanType,
  MessageSendingStatus,
  compareMessagesByWindow,
  getChatHistory,
  messageDraftKey,
  messageKey,
  sendMessage,
  type Chat,
  type Db,
  type Message,
  type MessageKey,
  type MessageDraft,
  type MessageDraftPeer,
  type RealtimeService,
} from "@inline/client/core"
import { GetChatHistoryMode, type InputPeer } from "@inline-chat/protocol/core"
import { compareInlineIds, messageId, protocolId, type MessageID } from "@inline/ids"

export const CONVERSATION_PAGE_SIZE = 60
export const CONVERSATION_WINDOW_LIMIT = 200

export type ConversationSnapshot = {
  messages: Message[]
  loading: boolean
  loadingOlder: boolean
  refreshingLatest: boolean
  hasOlder: boolean
  historyCertified: boolean
  atLatest: boolean
  error?: string
  errorRetry?: { kind: "history" } | { kind: "send" } | { kind: "resend"; messageId: MessageID }
  draftError?: string
  draft: string
  replyTo?: MessageID
  sending: boolean
  unavailable: boolean
}

const errorMessage = (error: unknown) =>
  error instanceof Error ? error.message : "Inline could not complete this action"

// Db rebuilds protocol DTOs on duplicate updates. Compare every value, including
// entities/media/byte arrays, only while admitting a pending history response.
const sameValue = (left: unknown, right: unknown): boolean => {
  if (left === right) return true
  if (left == null || right == null || typeof left !== "object" || typeof right !== "object")
    return false
  if (Array.isArray(left) !== Array.isArray(right)) return false
  if (Array.isArray(left) && Array.isArray(right) && left.length !== right.length) return false
  if (left instanceof Uint8Array || right instanceof Uint8Array) {
    return (
      left instanceof Uint8Array &&
      right instanceof Uint8Array &&
      left.length === right.length &&
      left.every((byte, index) => byte === right[index])
    )
  }
  const a = left as Record<string, unknown>
  const b = right as Record<string, unknown>
  return [...new Set([...Object.keys(a), ...Object.keys(b)])].every((key) =>
    sameValue(a[key], b[key]),
  )
}

const messageContent = (message: Message) => {
  const {
    randomId: _randomId,
    status: _status,
    reactionIntents: _reactionIntents,
    ...content
  } = message
  return {
    ...content,
    rev: message.rev ?? 0n,
    out: message.out ?? false,
    mentioned: message.mentioned ?? false,
    isSticker: message.isSticker ?? false,
    hasLink: message.hasLink ?? false,
  }
}

const sameMessage = (left: Message, right: Message) =>
  left === right || sameValue(messageContent(left), messageContent(right))
const provisionalMessage = (message: Message) =>
  BigInt(message.messageId) < 0n ||
  (message.out === true &&
    message.randomId != null &&
    (message.status === MessageSendingStatus.Sending ||
      message.status === MessageSendingStatus.Failed))

// updateMessageId first creates an outgoing Sent clone without a server rev.
// Its first canonical push may add parsed entities/peer metadata. Real edits
// increment rev, even when the server suppresses their edit timestamp.
// This identifies one quiet fresh request; it never admits a changed old page.
const firstCanonicalization = (previous: Message, message: Message) =>
  previous.out === true &&
  previous.status === MessageSendingStatus.Sent &&
  previous.rev == null &&
  previous.editDate == null &&
  message.out === true &&
  message.status === MessageSendingStatus.Sent &&
  (message.rev ?? 0n) === 0n &&
  message.editDate == null &&
  previous.fromId === message.fromId &&
  previous.message === message.message &&
  previous.replyToMsgId === message.replyToMsgId

/** One visible conversation; Db and RealtimeService retain storage/sync authority. */
export class Conversation {
  private snapshot: ConversationSnapshot = {
    messages: [],
    loading: true,
    loadingOlder: false,
    refreshingLatest: false,
    hasOlder: false,
    historyCertified: false,
    atLatest: true,
    draft: "",
    sending: false,
    unavailable: false,
  }
  private readonly listeners = new Set<() => void>()
  private readonly peer: InputPeer
  private readonly draftPeer: MessageDraftPeer
  private active = false
  private generation = 0
  private historyRequest = 0
  private pendingHistory?: {
    request: number
    messages: Map<MessageKey, Message>
    awaitingCanonical: Set<MessageKey>
    userSnapshotRetryAvailable: boolean
  }
  private oldestCertifiedId?: MessageID
  private unsubscribeDb?: () => void
  private starting?: Promise<void>
  private draftVersion = 0
  private pendingDraftWrites = 0
  private draftQueue: Promise<void> = Promise.resolve()
  private draftTail: Promise<void> = Promise.resolve()
  private pendingDraftRecipe?: { version: number; write: () => void }
  private acceptingSend?: Promise<void>
  private refreshing = false
  private retainingOlder = false
  private readonly settlingHistory = new Set<number>()
  private sending = false

  constructor(
    private readonly db: Db,
    private readonly realtime: RealtimeService,
    readonly chat: Chat,
  ) {
    this.peer =
      chat.peerUserId != null
        ? { type: { oneofKind: "user", user: { userId: protocolId(chat.peerUserId) } } }
        : { type: { oneofKind: "chat", chat: { chatId: protocolId(chat.id) } } }
    this.draftPeer =
      chat.peerUserId != null
        ? { peerKind: "user", peerUserId: chat.peerUserId }
        : { peerKind: "chat", peerThreadId: chat.id }
  }

  readonly getSnapshot = () => this.snapshot

  readonly subscribe = (listener: () => void) => {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  start(): Promise<void> {
    if (this.active) return this.starting ?? Promise.resolve()
    this.active = true
    const generation = ++this.generation
    const draftVersion = this.draftVersion
    this.oldestCertifiedId = undefined
    this.db.activateResidentMessageWindow(this.chat.id)
    this.unsubscribeDb = this.db.subscribeToResidentChanges((batch) => {
      if (!this.current(generation)) return
      if (
        batch.changes.some(
          (change) =>
            change.kind === DbObjectKind.Chat &&
            change.id === this.chat.id &&
            change.object == null,
        ) &&
        this.db.get(this.db.ref(DbObjectKind.Chat, this.chat.id)) == null
      ) {
        this.stop()
        this.patch({
          messages: [],
          loading: false,
          refreshingLatest: false,
          loadingOlder: false,
          hasOlder: false,
          historyCertified: false,
          unavailable: true,
          error: "This conversation is no longer available",
        })
        return
      }
      const pending = this.pendingHistory
      if (pending?.request === this.historyRequest) {
        const userSnapshot =
          batch.changes.some(
            (change) => change.kind === DbObjectKind.SyncBucketState && change.id === "user",
          ) &&
          batch.changes.some(
            (change) => change.kind === DbObjectKind.Chat && change.id === this.chat.id,
          )
        const localReconciliation = new Set<MessageKey>()
        for (const change of batch.changes) {
          // Resident publication contains final objects. Concurrent cache
          // hydration can retain the old provisional row through this commit,
          // so acknowledgement is established by its canonical counterpart.
          if (change.kind !== DbObjectKind.Message) continue
          const previous = pending.messages.get(change.id as MessageKey)
          if (!previous?.out || previous.randomId == null || !provisionalMessage(previous)) continue
          const candidate = batch.changes.find((candidate) => {
            const message =
              candidate.object?.kind === DbObjectKind.Message ? candidate.object : undefined
            if (
              !message ||
              message.chatId !== this.chat.id ||
              BigInt(message.messageId) <= 0n ||
              message.status !== MessageSendingStatus.Sent
            )
              return false
            const migrated = {
              ...previous,
              id: message.id,
              messageId: message.messageId,
              randomId: undefined,
              status: MessageSendingStatus.Sent,
            }
            return sameMessage(migrated, message) || firstCanonicalization(migrated, message)
          })
          if (candidate?.object?.kind === DbObjectKind.Message) {
            localReconciliation.add(candidate.object.id)
            if (candidate.object.rev == null) pending.awaitingCanonical.add(candidate.object.id)
          }
        }
        let canonicalRefresh = false
        let rowsChanged = false
        let otherRowsChanged = false
        for (const change of batch.changes) {
          if (
            change.kind !== DbObjectKind.Message ||
            typeof change.id !== "string" ||
            !change.id.startsWith(`${this.chat.id}:`)
          )
            continue
          const previous = pending.messages.get(change.id as MessageKey)
          const message = change.object?.kind === DbObjectKind.Message ? change.object : undefined
          if (previous && provisionalMessage(previous)) continue
          const changed = !message
            ? BigInt(change.id.slice(this.chat.id.length + 1)) > 0n
            : !previous
              ? message.editDate != null || (message.rev != null && message.rev > 0n)
              : !sameMessage(previous, message)
          if (!changed) {
            if (message && previous) pending.awaitingCanonical.delete(message.id)
            continue
          }
          rowsChanged = true
          if (
            message &&
            previous &&
            pending.awaitingCanonical.delete(message.id) &&
            firstCanonicalization(previous, message)
          )
            canonicalRefresh = true
          else otherRowsChanged = true
        }
        // Reconnect catchup can publish Chat sidecars after RPC reconciliation,
        // or before this pane observes any mapping. Fence its old page and try
        // one newly authorized page. Carry the spent allowance through every
        // automatic successor; repeated snapshots cannot form a fetch loop.
        const snapshotRefresh =
          userSnapshot &&
          !rowsChanged &&
          localReconciliation.size === 0 &&
          pending.userSnapshotRetryAvailable
        if (snapshotRefresh) pending.userSnapshotRetryAvailable = false
        if (userSnapshot || rowsChanged) {
          this.invalidatePendingHistory(
            !otherRowsChanged &&
              (snapshotRefresh ||
                canonicalRefresh ||
                (userSnapshot && localReconciliation.size > 0)),
          )
        } else
          for (const change of batch.changes) {
            if (
              change.object?.kind === DbObjectKind.Message &&
              change.object.chatId === this.chat.id
            ) {
              pending.messages.set(change.object.id, change.object)
            } else if (change.kind === DbObjectKind.Message && change.object == null) {
              pending.messages.delete(change.id as MessageKey)
            }
          }
      }
      if (
        this.pendingDraftWrites === 0 &&
        batch.changes.some(
          (change) =>
            change.kind === DbObjectKind.MessageDraft &&
            change.id === messageDraftKey(this.draftPeer),
        )
      ) {
        const draft = this.db.get(
          this.db.ref(DbObjectKind.MessageDraft, messageDraftKey(this.draftPeer)),
        )
        this.patch({ draft: draft?.text ?? "" })
      }
      if (
        batch.changes.some(
          (change) =>
            change.kind === DbObjectKind.Message ||
            (change.kind === DbObjectKind.Chat && change.id === this.chat.id),
        ) &&
        this.settlingHistory.size === 0
      )
        this.refreshMessages()
    })
    this.patch({
      loading: true,
      loadingOlder: false,
      hasOlder: false,
      historyCertified: false,
      unavailable: false,
      error: undefined,
      errorRetry: undefined,
    })
    this.starting = (async () => {
      try {
        await this.db.ready
        if (!this.current(generation)) return
        if (this.db.get(this.db.ref(DbObjectKind.Chat, this.chat.id)) == null) {
          this.patch({ unavailable: true })
          throw new Error("This conversation is no longer available")
        }
        await this.db.hydrateObjects(DbObjectKind.MessageDraft, [messageDraftKey(this.draftPeer)])
        if (!this.current(generation)) return
        if (this.draftVersion === draftVersion) {
          const draft = this.db.get(
            this.db.ref(DbObjectKind.MessageDraft, messageDraftKey(this.draftPeer)),
          )
          this.patch({ draft: draft?.text ?? "" })
        }
        await this.db.hydrateMessageWindow(this.chat.id, { limit: CONVERSATION_PAGE_SIZE })
        if (!this.current(generation)) return
        this.refreshMessages()
        this.patch({ loading: false })
        void this.fetchHistory(false, generation)
      } catch (error) {
        if (this.current(generation)) {
          this.patch({
            loading: false,
            error: errorMessage(error),
            errorRetry: { kind: "history" },
          })
          throw error
        }
      }
    })()
    return this.starting
  }

  stop() {
    if (!this.active) return
    this.active = false
    ++this.generation
    ++this.historyRequest
    this.pendingHistory = undefined
    this.unsubscribeDb?.()
    this.unsubscribeDb = undefined
    this.starting = undefined
    this.db.releaseResidentMessageWindow(this.chat.id)
  }

  /** Retire synchronously with stop(), then drain compose before closing Db. */
  async drain(): Promise<void> {
    // Local acceptance may consume an otherwise failed compose write. It does
    // not wait for server delivery, and a failed acceptance leaves compose.
    await this.acceptingSend?.catch(() => undefined)
    await this.draftTail
  }

  /** Explicit navigation recovery of accepted compose, including after stop. */
  async retryDraftDrain(): Promise<void> {
    try {
      await this.drain()
    } catch (error) {
      const pending = this.pendingDraftRecipe
      if (!pending) throw error
      await this.enqueueDraft(pending.write)
      if (this.pendingDraftRecipe === pending) {
        this.pendingDraftRecipe = undefined
        if (this.active && pending.version === this.draftVersion)
          this.patch({ draftError: undefined })
      }
    }
  }

  async loadLatest() {
    if (!this.active) return
    await this.fetchHistory(false, this.generation)
  }

  async loadOlder() {
    if (
      !this.active ||
      this.snapshot.loading ||
      this.snapshot.loadingOlder ||
      !this.snapshot.hasOlder
    )
      return
    await this.fetchHistory(true, this.generation)
  }

  /** A failed draft must be written again before its warning can disappear. */
  async retryError() {
    if (this.snapshot.draftError) await this.setDraft(this.snapshot.draft)
    else if (this.snapshot.errorRetry?.kind === "send") await this.send()
    else if (this.snapshot.errorRetry?.kind === "resend")
      await this.retry(this.snapshot.errorRetry.messageId)
    else await this.loadLatest()
  }

  setDraft(text: string): Promise<void> {
    if (!this.active) return Promise.reject(new Error("This conversation is closed"))
    const version = ++this.draftVersion
    const generation = this.generation
    ++this.pendingDraftWrites
    this.patch({ draft: text })
    const pending = {
      version,
      write: () => {
        const id = messageDraftKey(this.draftPeer)
        const existing = this.db.get(this.db.ref(DbObjectKind.MessageDraft, id))
        this.db.replace({
          kind: DbObjectKind.MessageDraft,
          id,
          ...this.draftPeer,
          text,
          revision: (existing?.revision ?? 0) + 1,
          updatedAt: Date.now(),
        })
      },
    }
    this.pendingDraftRecipe = pending
    const write = this.enqueueDraft(pending.write)
    return write
      .then(() => {
        if (this.pendingDraftRecipe === pending) this.pendingDraftRecipe = undefined
        if (this.current(generation) && version === this.draftVersion)
          this.patch({ draftError: undefined })
      })
      .catch((error: unknown) => {
        if (this.current(generation) && version === this.draftVersion) {
          this.patch({ draftError: `Draft was not saved: ${errorMessage(error)}` })
        }
        throw error
      })
      .finally(() => {
        --this.pendingDraftWrites
      })
  }

  setReplyTo(replyTo?: MessageID) {
    this.patch({ replyTo })
  }

  async send(text = this.snapshot.draft, replyTo = this.snapshot.replyTo) {
    if (!text.trim() || this.sending) return
    if (!this.active || this.snapshot.loading) throw new Error("Conversation is still opening")
    const generation = this.generation
    const version = this.draftVersion
    this.sending = true
    let acceptance: Promise<void> | undefined
    this.patch({ sending: true, historyCertified: false, error: undefined, errorRetry: undefined })
    try {
      // All previous draft writes settle before the mutation recipe can consume it.
      await this.draftQueue
      if (!this.current(generation)) return
      const ref = this.db.ref(DbObjectKind.MessageDraft, messageDraftKey(this.draftPeer))
      const draft = this.db.get(ref)
      const consumesCompose = version === this.draftVersion && this.snapshot.draft === text
      const consumedDraft: MessageDraft | undefined = consumesCompose ? draft : undefined
      const transaction = sendMessage({
        chatId: this.chat.id,
        peerId: this.peer,
        text,
        replyToMsgId: replyTo,
      })
      const optimistic = transaction.optimistic.bind(transaction)
      transaction.optimistic = (db, auth) => {
        optimistic(db, auth)
        // Message, existing outbox, and consumed draft commit together. A failed
        // local acceptance keeps all three unchanged, including compose text.
        const currentDraft = db.get(ref)
        if (
          consumedDraft &&
          currentDraft?.revision === consumedDraft.revision &&
          currentDraft.text === consumedDraft.text
        ) {
          db.delete(ref)
        }
      }
      acceptance = this.realtime.mutateAccepted(transaction)
      this.acceptingSend = acceptance
      await acceptance
      const consumedCompose =
        consumesCompose &&
        version === this.draftVersion &&
        (this.snapshot.draft === text || this.snapshot.draft === "")
      if (consumedCompose) {
        this.pendingDraftRecipe = undefined
        this.draftTail = this.draftQueue
      }
      if (!this.current(generation)) return
      if (consumedCompose) {
        ++this.draftVersion
        this.patch({
          draft: "",
          draftError: undefined,
          replyTo: this.snapshot.replyTo === replyTo ? undefined : this.snapshot.replyTo,
        })
      }
      // An accepted send changes the core's window intent to latest. Refresh
      // server coverage instead of extending the former historical boundary.
      void this.fetchHistory(false, generation)
    } catch (error) {
      if (this.current(generation))
        this.patch({ error: errorMessage(error), errorRetry: { kind: "send" } })
      throw error
    } finally {
      if (this.acceptingSend === acceptance) this.acceptingSend = undefined
      this.sending = false
      if (this.current(generation)) this.patch({ sending: false })
    }
  }

  async retry(id: MessageID) {
    if (!this.active) throw new Error("This conversation is closed")
    const generation = this.generation
    this.oldestCertifiedId = undefined
    this.patch({ hasOlder: false, historyCertified: false })
    try {
      await this.realtime.resendMessage(this.chat.id, id)
      if (!this.current(generation)) return
      if (this.snapshot.errorRetry?.kind === "resend" && this.snapshot.errorRetry.messageId === id)
        this.patch({ error: undefined, errorRetry: undefined })
      void this.fetchHistory(false, generation)
    } catch (error) {
      if (this.current(generation))
        this.patch({ error: errorMessage(error), errorRetry: { kind: "resend", messageId: id } })
      throw error
    }
  }

  private enqueueDraft(recipe: () => void) {
    const write = this.draftQueue.then(() => this.db.commit(recipe))
    this.draftQueue = write.catch(() => undefined)
    this.draftTail = write
    return write
  }

  private async fetchHistory(
    older: boolean,
    generation: number,
    awaitingCanonical = new Set<MessageKey>(),
    userSnapshotRetryAvailable = true,
  ) {
    const beforeId = older ? this.oldestCertifiedId : undefined
    if (older && beforeId == null) return
    const request = ++this.historyRequest
    this.retainingOlder = older
    if (!this.db.fullChatWindows.isActive(this.chat.id))
      this.db.activateResidentMessageWindow(this.chat.id)
    const residentKeys = this.db.fullChatWindows.keys(this.chat.id)
    const availableKeys = residentKeys.filter(
      (key) => this.db.get(this.db.ref(DbObjectKind.Message, key)) != null,
    )
    if (availableKeys.length !== residentKeys.length) {
      this.db.replaceResidentMessageWindow(
        this.chat.id,
        availableKeys,
        this.db.fullChatWindows.isAtLatest(this.chat.id),
      )
    }
    const intent = this.db.beginResidentMessageWindowIntent(this.chat.id)
    this.pendingHistory = {
      request,
      awaitingCanonical,
      userSnapshotRetryAvailable,
      messages: new Map(
        this.db
          .queryCollection(
            DbQueryPlanType.Objects,
            DbObjectKind.Message,
            (message) => message.chatId === this.chat.id,
          )
          .map((message) => [message.id, message]),
      ),
    }
    const requestedKeys = new Set(this.db.fullChatWindows.keys(this.chat.id))
    let keysBeforeApply = this.db.fullChatWindows.keys(this.chat.id)
    this.patch(
      older
        ? { loadingOlder: true, error: undefined, errorRetry: undefined }
        : {
            refreshingLatest: true,
            loadingOlder: false,
            hasOlder: false,
            historyCertified: false,
            error: undefined,
            errorRetry: undefined,
          },
    )
    try {
      const transaction = getChatHistory({
        peerId: this.peer,
        mode: older
          ? GetChatHistoryMode.HISTORY_MODE_OLDER
          : GetChatHistoryMode.HISTORY_MODE_LATEST,
        beforeId,
        limit: CONVERSATION_PAGE_SIZE + 1,
      })
      const apply = transaction.apply.bind(transaction)
      const afterCommit = transaction.afterCommit.bind(transaction)
      transaction.apply = (result, db) => {
        // Core commits rows before publishing history-window membership. Do
        // not compact or reclaim that intermediate state from a Db observer.
        const currentIntent = db.captureResidentMessageWindowIntents().get(this.chat.id)
        const ownsWindow =
          this.current(generation) &&
          request === this.historyRequest &&
          currentIntent === intent &&
          db.get(db.ref(DbObjectKind.Chat, this.chat.id)) != null
        if (!ownsWindow) return
        keysBeforeApply = db.fullChatWindows.keys(this.chat.id)
        this.settlingHistory.add(request)
        apply(result, db)
        // The observer must recognize this response's own materialized rows;
        // later committed edits/deletions still invalidate its pending page.
        if (result?.oneofKind === "getChatHistory" && this.pendingHistory?.request === request) {
          for (const message of result.getChatHistory.messages) {
            if (message.chatId !== protocolId(this.chat.id)) continue
            const model = db.get(
              db.ref(DbObjectKind.Message, messageKey(this.chat.id, messageId(message.id))),
            )
            if (model) {
              this.pendingHistory.awaitingCanonical.delete(model.id)
              this.pendingHistory.messages.set(model.id, model)
            }
          }
        }
      }
      transaction.afterCommit = (result, db) => {
        try {
          if (
            this.current(generation) &&
            request === this.historyRequest &&
            db.get(db.ref(DbObjectKind.Chat, this.chat.id)) != null
          )
            afterCommit(result, db)
        } finally {
          this.settlingHistory.delete(request)
        }
      }
      const result = await this.realtime.query(transaction)
      if (!this.current(generation) || request !== this.historyRequest) return
      if (this.db.captureResidentMessageWindowIntents().get(this.chat.id) !== intent) return
      if (result?.oneofKind !== "getChatHistory")
        throw new Error("Inline returned an invalid history response")
      const ordered = result.getChatHistory.messages
        .filter((message) => message.chatId === protocolId(this.chat.id))
        .slice()
        .sort((left, right) => compareInlineIds(messageId(right.id), messageId(left.id)))
      const page = ordered.slice(0, CONVERSATION_PAGE_SIZE)
      const hasOlder = ordered.length > CONVERSATION_PAGE_SIZE
      const oldest = page.at(-1)
      if (oldest) this.oldestCertifiedId = messageId(oldest.id)
      else if (!older) this.oldestCertifiedId = undefined
      const localSends = this.db
        .queryCollection(
          DbQueryPlanType.Objects,
          DbObjectKind.Message,
          (message) =>
            message.chatId === this.chat.id &&
            (message.status === MessageSendingStatus.Sending ||
              message.status === MessageSendingStatus.Failed),
        )
        .map((message) => message.id)
      const lookaheadKeys = new Set(
        ordered
          .slice(CONVERSATION_PAGE_SIZE)
          .map((message) => messageKey(this.chat.id, messageId(message.id))),
      )
      const newestReturnedId = ordered[0] == null ? undefined : messageId(ordered[0].id)
      const existingKeys = older
        ? this.db.fullChatWindows.keys(this.chat.id).filter((key) => !lookaheadKeys.has(key))
        : // The server can read its page before a newer committed update reaches
          // us. Preserve live keys added while this query was in flight; cached
          // keys present before the request do not override a latest response.
          keysBeforeApply.filter((key) => {
            if (requestedKeys.has(key)) return false
            const message = this.db.get(this.db.ref(DbObjectKind.Message, key))
            return (
              message != null &&
              (newestReturnedId == null ||
                compareInlineIds(message.messageId, newestReturnedId) > 0)
            )
          })
      const keys = [
        ...new Set([
          ...existingKeys,
          ...page.map((message) => messageKey(this.chat.id, messageId(message.id))),
          ...localSends,
        ]),
      ]
      // From here, synchronous window compaction may evict cached rows. Those
      // local projection changes are no longer mutations during a pending RPC.
      this.pendingHistory = undefined
      if (
        !this.db.replaceResidentMessageWindow(
          this.chat.id,
          keys,
          !older || this.snapshot.atLatest,
          intent,
        )
      )
        return
      this.refreshMessages(older)
      this.db.reconcileResidentMessageWindow(this.chat.id)
      this.patch({
        hasOlder,
        historyCertified: !older || (this.snapshot.atLatest && this.snapshot.historyCertified),
      })
    } catch (error) {
      if (this.current(generation) && request === this.historyRequest)
        this.patch({ error: errorMessage(error), errorRetry: { kind: "history" } })
    } finally {
      this.settlingHistory.delete(request)
      if (this.pendingHistory?.request === request) this.pendingHistory = undefined
      if (this.current(generation) && request === this.historyRequest)
        this.patch({ loading: false, refreshingLatest: false, loadingOlder: false })
    }
  }

  private invalidatePendingHistory(retryAfterReconciliation = false) {
    if (!this.pendingHistory) return
    const awaitingCanonical = new Set(this.pendingHistory.awaitingCanonical)
    const userSnapshotRetryAvailable = this.pendingHistory.userSnapshotRetryAvailable
    this.settlingHistory.delete(this.pendingHistory.request)
    this.pendingHistory = undefined
    ++this.historyRequest
    this.db.beginResidentMessageWindowIntent(this.chat.id)
    this.oldestCertifiedId = undefined
    this.patch({
      loadingOlder: false,
      refreshingLatest: retryAfterReconciliation,
      hasOlder: false,
      historyCertified: false,
      error: retryAfterReconciliation
        ? undefined
        : "This conversation changed while loading history. Retry latest history.",
      errorRetry: retryAfterReconciliation ? undefined : { kind: "history" },
    })
    if (retryAfterReconciliation) {
      const generation = this.generation
      const request = this.historyRequest
      // Publish the whole acknowledgement commit before opening one fresh
      // page. Its old page stays fenced even if access changed in this batch.
      void Promise.resolve().then(() => {
        if (this.current(generation) && request === this.historyRequest)
          return this.fetchHistory(false, generation, awaitingCanonical, userSnapshotRetryAvailable)
      })
    }
  }

  private refreshMessages(retainOlder = this.retainingOlder) {
    if (!this.active || this.refreshing) return
    this.refreshing = true
    try {
      let messages = this.db.fullChatWindows
        .keys(this.chat.id)
        .flatMap((key) => {
          const message = this.db.get(this.db.ref(DbObjectKind.Message, key))
          return message ? [message] : []
        })
        .sort(compareMessagesByWindow)
      if (messages.length > CONVERSATION_WINDOW_LIMIT) {
        const retained = retainOlder
          ? messages.slice(0, CONVERSATION_WINDOW_LIMIT)
          : messages.slice(-CONVERSATION_WINDOW_LIMIT)
        this.db.compactResidentMessageWindow(
          this.chat.id,
          retained[0]!.id,
          retained.at(-1)!.id,
          CONVERSATION_WINDOW_LIMIT,
        )
        messages = retained
        if (!retainOlder && this.oldestCertifiedId != null) {
          const confirmed = messages.filter(
            (message) =>
              message.status !== MessageSendingStatus.Sending &&
              message.status !== MessageSendingStatus.Failed,
          )
          if (confirmed.length) {
            this.oldestCertifiedId = confirmed.reduce(
              (oldest, message) =>
                compareInlineIds(message.messageId, oldest) < 0 ? message.messageId : oldest,
              confirmed[0]!.messageId,
            )
            this.patch({ hasOlder: true })
          }
        }
      }
      const atLatest = this.db.fullChatWindows.isAtLatest(this.chat.id)
      if (
        messages.length !== this.snapshot.messages.length ||
        messages.some((message, index) => message !== this.snapshot.messages[index]) ||
        atLatest !== this.snapshot.atLatest
      ) {
        this.patch({
          messages,
          atLatest,
          historyCertified: atLatest && this.snapshot.historyCertified,
        })
      }
    } finally {
      this.refreshing = false
    }
  }

  private current(generation: number) {
    return this.active && generation === this.generation
  }

  private patch(patch: Partial<ConversationSnapshot>) {
    if (
      Object.entries(patch).every(
        ([key, value]) => this.snapshot[key as keyof ConversationSnapshot] === value,
      )
    )
      return
    this.snapshot = { ...this.snapshot, ...patch }
    for (const listener of this.listeners) listener()
  }
}
