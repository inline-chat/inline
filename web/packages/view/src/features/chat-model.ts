/**
 * The model of one chat: its message window, header inputs, draft, send and
 * read marking. Framework-free; the timeline and composer controllers are
 * fed from it by the view wiring, not wrapped by it.
 *
 * Lifetime: the model is counted by its users (`retain`). The resident chat
 * cache holds one count while the chat is resident; a pane showing it holds
 * one through the cache's lease; a send in flight holds one until its first
 * result. When the count drops to zero the model unsubscribes and disposes.
 */

import {
  newClientKey as defaultClientKey,
  optimisticMessageRow,
  receivedMessageRowId,
  rowKey,
  rowKeyOf,
  type ChatRow,
  type Command,
  type DialogRow,
  type DraftRow,
  type Entity,
  type FormSubmissionValue,
  type Intent,
  type IntentRejection,
  type IntentResult,
  type MessageRow,
  type QueryDescriptor,
  type ReactionSummary,
  type RowKey,
  type TxId,
  type UserRow,
  type WindowAnchor,
  type WindowResource,
} from "@inline/core-protocol"
import type { ChatID, MessageID, SpaceID, UserID } from "@inline/ids"
import {
  computed,
  effect,
  plainEqual,
  scoped,
  StoreDisposedError,
  untracked,
  type Clock,
  type Dispose,
  type ReadSignal,
  type StoreClient,
  type SubscriptionHandle,
} from "@inline/reactive"
import { chatAvatar, chatTitle, compareMessageIds, type AvatarInput } from "./helpers"
import { actionHandle, type ActionHandle, type IntentTracker } from "./intent-outcome"
import { canEditMessage, messageAbilities, type MessageAbilities } from "./message-abilities"
import { ReadMarker } from "./read-marker"

/** The window resource with its defaults before the core has answered. */
export type ChatWindowState = {
  /** False until the core has sent the window's first state. */
  readonly ready: boolean
  readonly hasOlder: boolean
  readonly hasNewer: boolean
  readonly atLatest: boolean
  readonly loading: WindowResource["loading"]
  /** The read marker captured when the window opened (rule 1). Fixed for the visit. */
  readonly unreadBoundary?: MessageID
  /**
   * The newest message up to which the window's history is known to be
   * contiguous (`WindowResource.certifiedThrough`). Read marking never goes
   * past it; pass it to the timeline controller as `contiguousThrough`.
   * Absent: the core has not said (the controller then infers it).
   */
  readonly certifiedThrough?: MessageID
}

/** The inclusive range of message IDs a trimmed window keeps (`trimWindow`). */
export type WindowKeep = { readonly from: MessageID; readonly to: MessageID }

/** Inputs of the chat header. The subtitle also needs the session's connection display. */
export type ChatHeader = {
  readonly chatId: ChatID
  readonly title: string
  readonly emoji?: string
  readonly avatar: AvatarInput
  readonly isDirect: boolean
  readonly peerUserId?: UserID
  readonly peerIsBot: boolean
  readonly spaceId?: SpaceID
  readonly parentChatId?: ChatID
}

/** What the timeline controller's `setReadState` takes. */
export type ChatReadState = { readonly unreadCount: number; readonly readMaxId?: MessageID }

/**
 * The outcome of a send, from its first result.
 *
 * - `accepted`: committed durably with its row. The composer may clear.
 * - `rejected`: not committed (`storageFull`, `unavailable`, `invalid`, ...,
 *   or `disposed` when the session ended first). The overlay row is gone; the
 *   composer keeps the text and says why.
 * - `uncertain`: the core stopped before reporting acceptance. The row may or
 *   may not exist. Keep the text; `retry()` (or sending the same draft
 *   revision again) reuses the client key, so the message cannot be doubled.
 */
export type SendResult =
  | { readonly status: "accepted"; readonly tx: TxId; readonly rowKey: RowKey; readonly clientKey: string }
  | {
      readonly status: "rejected"
      readonly tx: TxId
      readonly reason: IntentRejection | "disposed"
      /** Worth offering "try again": the condition may pass (storage freed, core back). */
      readonly retryable: boolean
    }
  | {
      readonly status: "uncertain"
      readonly tx: TxId
      readonly rowKey: RowKey
      readonly clientKey: string
      readonly retry: () => SendHandle
    }

/** The send's result, with what is known in the same task. */
export type SendHandle = Promise<SendResult> & {
  readonly tx: TxId
  /** The row's key; the row is readable through `row(rowKey)` before this returns. */
  readonly rowKey: RowKey
  readonly clientKey: string
}

export type SendOptions = {
  /**
   * The composer's document revision being sent. It goes on the intent
   * (`sendText.draftRevision`): the core deletes the chat's draft in the
   * send's own commit when the draft's revision is at most this, so the
   * sidebar stops showing "Draft:" once the send is accepted. A send of the
   * same revision and text after an `uncertain` result reuses that send's
   * client key.
   */
  readonly draftRevision?: number
}

/** The shape of `@inline/composer`'s `SendRequest` and `SendOutcome`, kept structural here. */
export type ComposerSendRequest = {
  readonly kind: "send" | "edit"
  readonly text: string
  readonly entities: readonly Entity[]
  readonly revision: number
  readonly replyTo?: { readonly messageId: MessageID }
  /** The message being edited, for `kind: "edit"`. */
  readonly edit?: { readonly messageId: MessageID }
}
export type ComposerSendOutcome = { status: "accepted" } | { status: "rejected"; reason?: string }

const retryableRejections: ReadonlySet<string> = new Set(["storageFull", "unavailable", "server", "disposed"])

export type ChatModelOptions = {
  readonly client: StoreClient
  readonly chatId: ChatID
  /** The signed-in user; the author of optimistic rows. */
  readonly userId: UserID
  /** Where the window opens. Default `unread` (the core falls back to latest). */
  readonly anchor?: WindowAnchor
  readonly clock: Clock
  /** Wall clock in milliseconds since the epoch, for message dates. Default `Date.now`. */
  readonly now?: () => number
  /** Jitter source for read retries. */
  readonly random?: () => number
  readonly newClientKey?: () => string
  /**
   * The chat's dialog row, which the contract delivers only with the sidebar.
   * TODO(contract): `chat` or `chatWindow` should carry the dialog (unread
   * count, read marker) so a chat outside the sidebar list has it too.
   */
  readonly dialog?: ReadSignal<DialogRow | undefined>
  /** Called whenever the user count changes; the cache uses it to evict once a model is idle. */
  readonly onUsersChanged?: (model: ChatModel, users: number) => void
  /**
   * How the model subscribes. Default `client.subscribe`. The session passes
   * one that hands out subscriptions restored from the boot snapshot first,
   * so a chat restored there paints its window before the core answers.
   */
  readonly subscribe?: (query: QueryDescriptor) => SubscriptionHandle
  /**
   * Follows actions to their final result (`ActionHandle.outcome`). The
   * session passes its own. Without it an outcome is the next result the
   * store delivers after acceptance, which can be missed when both arrive in
   * one frame.
   */
  readonly intents?: IntentTracker
  /**
   * Posts a command the store client has no method for (`trimWindow`). The
   * session passes its core endpoint's `post`. Without it `trimWindow` does
   * nothing.
   */
  readonly post?: (command: Command) => void
}

export class ChatModel {
  readonly chatId: ChatID
  /** Message row keys, oldest first. A sent message appears at the end in the same task. */
  readonly rowKeys: ReadSignal<readonly RowKey[]>
  readonly window: ReadSignal<ChatWindowState>
  readonly chat: ReadSignal<ChatRow | undefined>
  readonly peer: ReadSignal<UserRow | undefined>
  readonly header: ReadSignal<ChatHeader>
  /** The saved draft, for the composer's `initial` and `setDraft`. */
  readonly draft: ReadSignal<DraftRow | undefined>
  readonly readState: ReadSignal<ChatReadState | undefined>

  readonly #options: ChatModelOptions
  readonly #client: StoreClient
  readonly #window: SubscriptionHandle
  readonly #chatSub: SubscriptionHandle
  readonly #draftSub: SubscriptionHandle
  #peerSub: SubscriptionHandle | undefined
  readonly #reads: ReadMarker
  readonly #disposeScope: Dispose
  readonly #now: () => number
  readonly #newClientKey: () => string
  /** Client keys of sends that ended `uncertain`, by draft revision and text. */
  readonly #uncertain = new Map<string, string>()
  /** The last range sent with `trimWindow`; a repeat is not sent again until the window moves. */
  #lastTrim: WindowKeep | undefined
  #users = 0
  #disposed = false

  constructor(options: ChatModelOptions) {
    this.#options = options
    this.#client = options.client
    this.chatId = options.chatId
    this.#now = options.now ?? Date.now
    this.#newClientKey = options.newClientKey ?? (() => defaultClientKey())
    const { client, chatId } = options
    const store = client.store
    const subscribe = options.subscribe ?? ((query: QueryDescriptor) => client.subscribe(query))

    this.#window = subscribe({ kind: "chatWindow", chatId, anchor: options.anchor ?? "unread" })
    this.#chatSub = subscribe({ kind: "chat", chatId })
    this.#draftSub = subscribe({ kind: "draft", chatId })

    this.rowKeys = this.#window.list
    const windowResource = this.#window.resource
    this.window = computed(
      () => {
        const value = windowResource.get()
        if (!value || value.kind !== "window") {
          return { ready: false, hasOlder: false, hasNewer: false, atLatest: true, loading: "initial" }
        }
        return {
          ready: true,
          hasOlder: value.hasOlder,
          hasNewer: value.hasNewer,
          atLatest: value.atLatest,
          loading: value.loading,
          ...(value.unreadBoundary ? { unreadBoundary: value.unreadBoundary } : {}),
          ...(value.certifiedThrough ? { certifiedThrough: value.certifiedThrough } : {}),
        }
      },
      { equals: plainEqual },
    )

    const chatRow = store.row("chat", chatId)
    this.chat = { get: () => chatRow.get(), peek: () => chatRow.peek() }
    const draftRow = store.row("draft", chatId)
    const draftKey = rowKey("draft", chatId)
    this.draft = computed(() => {
      const row = draftRow.get()
      // A draft restored from the boot snapshot can be older than the core's:
      // the last keystrokes are saved as the page hides, after the snapshot
      // read the store. The composer starts from the core's draft instead
      // (the sidebar still shows the restored one until then).
      if (store.provisionalSubs.get().size > 0 && store.isProvisional(draftKey)) return undefined
      return row
    })
    const peerUserId = computed(() => options.dialog?.get()?.peerUserId ?? chatRow.get()?.peerUserId)
    this.peer = computed(() => {
      const id = peerUserId.get()
      return id === undefined ? undefined : store.row("user", id).get()
    })
    this.header = computed(
      () => {
        const chat = chatRow.get()
        const peerId = peerUserId.get()
        const peer = this.peer.get()
        return {
          chatId,
          title: chatTitle(chat, peer, peerId),
          ...(chat?.emoji ? { emoji: chat.emoji } : {}),
          avatar: chatAvatar(chatId, chat, peer, peerId),
          isDirect: peerId !== undefined,
          ...(peerId !== undefined ? { peerUserId: peerId } : {}),
          peerIsBot: peer?.bot === true,
          ...(chat?.spaceId ? { spaceId: chat.spaceId } : {}),
          ...(chat?.parentChatId ? { parentChatId: chat.parentChatId } : {}),
        }
      },
      { equals: plainEqual },
    )
    this.readState = computed(
      () => {
        const dialog = options.dialog?.get()
        if (!dialog) return undefined
        return { unreadCount: dialog.unreadCount, ...(dialog.readMaxId ? { readMaxId: dialog.readMaxId } : {}) }
      },
      { equals: plainEqual },
    )

    this.#reads = new ReadMarker({
      clock: options.clock,
      ...(options.random ? { random: options.random } : {}),
      send: (maxId) => this.#client.intent({ kind: "markRead", chatId, maxId }),
    })

    // A direct message's peer gets its own subscription so the header has the
    // user even when no message or sidebar row brought it.
    this.#disposeScope = scoped(() => {
      effect(() => {
        const id = peerUserId.get()
        untracked(() => {
          if (this.#peerSub?.query.kind === "user" && this.#peerSub.query.userId === id) return
          this.#peerSub?.unsubscribe()
          this.#peerSub = id === undefined ? undefined : subscribe({ kind: "user", userId: id })
        })
      })
    })[1]
  }

  /** The row signal of one message key. Each row view observes its own row. */
  row(key: RowKey): ReadSignal<MessageRow | undefined> {
    return this.#client.store.rowByKey(key) as ReadSignal<MessageRow | undefined>
  }

  /** The chat window's subscription (what the boot snapshot exports). */
  get windowSubscription(): SubscriptionHandle {
    return this.#window
  }

  /** The chat window's subscription ID, for `appendTo` and diagnostics. */
  get windowSub(): number {
    return this.#window.sub
  }

  get disposed(): boolean {
    return this.#disposed
  }

  // MARK: - Users

  /** Count one user. Returns the release function (idempotent). */
  retain(): () => void {
    if (this.#disposed) throw new Error(`ChatModel ${this.chatId} is disposed`)
    this.#users += 1
    this.#options.onUsersChanged?.(this, this.#users)
    let released = false
    return () => {
      if (released) return
      released = true
      this.#users -= 1
      this.#options.onUsersChanged?.(this, this.#users)
      if (this.#users === 0) this.dispose()
    }
  }

  get users(): number {
    return this.#users
  }

  // MARK: - Window

  ensureOlder(): void {
    this.request("older")
  }

  ensureNewer(): void {
    this.request("newer")
  }

  ensureLatest(): void {
    this.request("latest")
  }

  ensureAround(messageId: MessageID): void {
    this.request({ around: messageId })
  }

  /** The timeline controller's `request`, mapped onto `ensure`. */
  request(range: "older" | "newer" | "latest" | { around: MessageID }): void {
    // The window grows or moves: a later trim to the same range releases rows again.
    this.#lastTrim = undefined
    this.#window.ensure(range)
  }

  /**
   * Tell the core the window only needs the messages from `keep.from` to
   * `keep.to` (inclusive): the timeline trimmed its rendered range. The core
   * releases the rows outside it (it may keep more). Not sent when it would
   * release nothing, or when it repeats the last range sent before the window
   * moved. Returns whether a command was posted.
   */
  trimWindow(keep: WindowKeep): boolean {
    const post = this.#options.post
    if (this.#disposed || !post || compareMessageIds(keep.from, keep.to) > 0) return false
    const last = this.#lastTrim
    if (last && last.from === keep.from && last.to === keep.to) return false
    const bounds = this.#windowBounds()
    if (!bounds || (compareMessageIds(keep.from, bounds.from) <= 0 && compareMessageIds(keep.to, bounds.to) >= 0)) {
      return false
    }
    this.#lastTrim = { from: keep.from, to: keep.to }
    post({ kind: "trimWindow", sub: this.#window.sub, keep: { from: keep.from, to: keep.to } })
    return true
  }

  /**
   * `trimWindow` for the rows the timeline keeps, by row key (its rendered
   * range of `rowKeys`): keeps from the oldest to the newest of them that
   * has a server ID. Rows still sending have none and are never released.
   */
  trimToRows(keys: readonly RowKey[]): boolean {
    let from: MessageID | undefined
    let to: MessageID | undefined
    for (const key of keys) {
      const id = (this.#client.store.peekRow(key) as MessageRow | undefined)?.messageId
      if (id === undefined) continue
      if (from === undefined || compareMessageIds(id, from) < 0) from = id
      if (to === undefined || compareMessageIds(id, to) > 0) to = id
    }
    return from !== undefined && to !== undefined ? this.trimWindow({ from, to }) : false
  }

  /** The oldest and newest server message IDs in the window. */
  #windowBounds(): WindowKeep | undefined {
    let from: MessageID | undefined
    let to: MessageID | undefined
    for (const key of this.#window.list.peek()) {
      const id = (this.#client.store.peekRow(key) as MessageRow | undefined)?.messageId
      if (id === undefined) continue
      if (from === undefined || compareMessageIds(id, from) < 0) from = id
      if (to === undefined || compareMessageIds(id, to) > 0) to = id
    }
    return from !== undefined && to !== undefined ? { from, to } : undefined
  }

  // MARK: - Send

  /**
   * Send a text message. The optimistic row is in the store, and at the end
   * of the window when the window is at the latest message, before this
   * returns. A window that is not at latest is moved there.
   */
  send(text: string, entities?: readonly Entity[], replyTo?: MessageID, options: SendOptions = {}): SendHandle {
    const uncertainKey = options.draftRevision !== undefined ? `${options.draftRevision}:${text}` : undefined
    const reused = uncertainKey !== undefined ? this.#uncertain.get(uncertainKey) : undefined
    return this.#send(text, entities, replyTo, reused ?? this.#newClientKey(), uncertainKey, options.draftRevision)
  }

  /**
   * The composer's `send` option. An edit maps onto `edit`: `accepted` (the
   * edit is shown; the composer leaves edit mode) or a rejection with its
   * reason (`offline`, `uncertain`, ...), which keeps the text.
   */
  sendFromComposer = async (request: ComposerSendRequest): Promise<ComposerSendOutcome> => {
    if (request.kind === "edit") {
      if (!request.edit) return { status: "rejected", reason: "invalid" }
      const result = await this.edit(request.edit.messageId, request.text, request.entities)
      if (result.status === "accepted") return { status: "accepted" }
      return { status: "rejected", reason: result.status === "uncertain" ? "uncertain" : result.reason }
    }
    const result = await this.send(request.text, request.entities, request.replyTo?.messageId, {
      draftRevision: request.revision,
    })
    return composerOutcome(result)
  }

  #send(
    text: string,
    entities: readonly Entity[] | undefined,
    replyTo: MessageID | undefined,
    clientKey: string,
    uncertainKey: string | undefined,
    draftRevision: number | undefined,
  ): SendHandle {
    const intent: Extract<Intent, { kind: "sendText" }> = {
      kind: "sendText",
      chatId: this.chatId,
      clientKey,
      text,
      ...(entities && entities.length > 0 ? { entities: [...entities] } : {}),
      ...(replyTo ? { replyToMessageId: replyTo } : {}),
      date: Math.floor(this.#now() / 1000),
      ...(draftRevision !== undefined ? { draftRevision } : {}),
    }
    const atLatest = this.window.peek().atLatest
    // A row appended to a window that does not end at latest would sit after
    // a gap. Move the window instead; the core's patch brings the row.
    if (!atLatest) this.#window.ensure("latest")
    const release = this.#disposed ? () => {} : this.retain()
    // The optimistic row carries the transaction ID, as the core's row does
    // while the send is in the outbox (`MessageRow.tx`), so the two are the
    // same row. The ID is allocated by `intent`, so the row is installed
    // right after it, in the same task: patches and results reach the store
    // only in the frame lane, never before this returns.
    const handle = this.#client.intent(intent)
    const tx = handle.tx
    const row = optimisticMessageRow(intent, this.#options.userId, intent.date ?? 0, tx)
    const key = rowKeyOf(row)
    this.#client.store.addOverlay(tx, [{ row, ...(atLatest ? { appendTo: [this.#window.sub] } : {}) }])
    const done = handle.then(
      (result): SendResult => this.#sendResult(result, key, clientKey, uncertainKey, text, entities, replyTo, draftRevision),
      (error: unknown): SendResult => {
        if (error instanceof StoreDisposedError) return { status: "rejected", tx, reason: "disposed", retryable: true }
        return { status: "rejected", tx, reason: "unavailable", retryable: true }
      },
    )
    const settled = done.finally(release)
    return Object.assign(settled, { tx, rowKey: key, clientKey })
  }

  #sendResult(
    result: IntentResult,
    key: RowKey,
    clientKey: string,
    uncertainKey: string | undefined,
    text: string,
    entities: readonly Entity[] | undefined,
    replyTo: MessageID | undefined,
    draftRevision: number | undefined,
  ): SendResult {
    const tx = result.tx
    if (uncertainKey !== undefined) this.#uncertain.delete(uncertainKey)
    switch (result.status) {
      case "accepted":
      case "confirmed":
        return { status: "accepted", tx, rowKey: key, clientKey }
      case "rejected": {
        const reason = result.reason ?? "server"
        return { status: "rejected", tx, reason, retryable: retryableRejections.has(reason) }
      }
      case "uncertain":
        if (uncertainKey !== undefined) this.#uncertain.set(uncertainKey, clientKey)
        return {
          status: "uncertain",
          tx,
          rowKey: key,
          clientKey,
          retry: () => this.#send(text, entities, replyTo, clientKey, uncertainKey, draftRevision),
        }
    }
  }

  // MARK: - Message actions
  //
  // Each returns an `ActionHandle`: its first result (`accepted`, or a
  // refusal such as `offline` before anything showed), and `outcome`, the
  // final one. What the user sees in between is the core's overlay of open
  // edits, deletes and reactions (client host README), except where noted:
  //
  // - Reactions and edits are also predicted in the UI overlay, installed in
  //   the same task as the click or key (reactivity.md: react is a sync-lane
  //   echo), because the core's overlay arrives one worker round trip later,
  //   which can be a frame after the input. The prediction is dropped in the
  //   batch that brings the core's row or settles the transaction, so a
  //   refusal (`offline`) shows the row as it was.
  // - Deletes are not predicted: the overlay cannot remove a row (no
  //   tombstones); the row goes with the core's patch.

  /** Edit one of the viewer's messages. The new text shows in the same task. */
  edit(messageId: MessageID, text: string, entities?: readonly Entity[]): ActionHandle {
    const intent: Intent = {
      kind: "editText",
      chatId: this.chatId,
      messageId,
      text,
      ...(entities && entities.length > 0 ? { entities: [...entities] } : {}),
    }
    const current = this.#messageRow(messageId)
    const predicted: MessageRow | undefined = current
      ? {
          ...withoutEntities(current),
          text,
          ...(entities && entities.length > 0 ? { entities: [...entities] } : {}),
          editDate: Math.floor(this.#now() / 1000),
        }
      : undefined
    return this.#action(intent, "edit the message", predicted)
  }

  /**
   * Delete messages by server ID; `clientKeys` names sends from this device
   * (a send still in flight has no ID: deleting it cancels it).
   */
  delete(messageIds: readonly MessageID[], options: { readonly clientKeys?: readonly string[] } = {}): ActionHandle {
    const clientKeys = options.clientKeys ?? []
    const count = messageIds.length + clientKeys.length
    const cancelOnly = messageIds.length === 0 && clientKeys.length > 0 && this.#allSending(clientKeys)
    const what = cancelOnly ? "cancel the message" : count > 1 ? "delete the messages" : "delete the message"
    return this.#action(
      {
        kind: "deleteMessages",
        chatId: this.chatId,
        messageIds: [...messageIds],
        ...(clientKeys.length > 0 ? { clientKeys: [...clientKeys] } : {}),
      },
      what,
    )
  }

  /**
   * Delete messages by row key: a row with a server ID by that ID, a send
   * from this device without one (sending, failed, uncertain) by its client
   * key, which cancels it if it is still sending.
   */
  deleteRows(keys: readonly RowKey[]): ActionHandle {
    const messageIds: MessageID[] = []
    const clientKeys: string[] = []
    for (const key of keys) {
      const row = this.#client.store.peekRow(key) as MessageRow | undefined
      if (row?.kind !== "message") continue
      if (row.messageId !== undefined) messageIds.push(row.messageId)
      else if (row.clientKey !== undefined) clientKeys.push(row.clientKey)
    }
    return this.delete(messageIds, { clientKeys })
  }

  /** Add a reaction. It shows in the same task. */
  react(messageId: MessageID, emoji: string): ActionHandle {
    return this.#reaction(messageId, emoji, "add")
  }

  /** Remove the viewer's reaction. It goes in the same task. */
  unreact(messageId: MessageID, emoji: string): ActionHandle {
    return this.#reaction(messageId, emoji, "remove")
  }

  /** Add the reaction, or remove it when the viewer's is already there (a reaction chip's click). */
  toggleReaction(messageId: MessageID, emoji: string): ActionHandle {
    const mine = this.#messageRow(messageId)?.reactions?.some((reaction) => reaction.emoji === emoji && reaction.mine)
    return this.#reaction(messageId, emoji, mine ? "remove" : "add")
  }

  /** Press a bot button (`actions` of kind `callback`). `outcome` carries the bot's answer. */
  invokeAction(messageId: MessageID, actionId: string): ActionHandle {
    return this.#action({ kind: "invokeAction", chatId: this.chatId, messageId, actionId }, "run the action")
  }

  /** Submit a form block. `outcome` carries the bot's answer. */
  submitForm(messageId: MessageID, formId: string, values: readonly FormSubmissionValue[]): ActionHandle {
    return this.#action(
      { kind: "submitForm", chatId: this.chatId, messageId, formId, values: [...values] },
      "submit the form",
    )
  }

  /** Send a failed send from this device again (by row key; it keeps its client key). */
  resend(key: RowKey): ActionHandle {
    const row = this.#client.store.peekRow(key) as MessageRow | undefined
    const clientKey = row?.kind === "message" ? row.clientKey : undefined
    return this.#action(
      // An empty client key is refused by the core as invalid, which the notice says.
      { kind: "retrySend", chatId: this.chatId, clientKey: clientKey ?? "" },
      "resend the message",
    )
  }

  /** What the viewer can do with a message row (`messageAbilities`). */
  abilities(key: RowKey): MessageAbilities | undefined {
    const row = this.#client.store.peekRow(key) as MessageRow | undefined
    return row?.kind === "message" ? messageAbilities(row, this.#options.userId) : undefined
  }

  /** The viewer's newest editable message in the window: Up in an empty composer edits it (rule 10). */
  lastEditableMessageId(): MessageID | undefined {
    const keys = this.#window.list.peek()
    for (let index = keys.length - 1; index >= 0; index--) {
      const row = this.#client.store.peekRow(keys[index]!) as MessageRow | undefined
      if (row?.kind === "message" && canEditMessage(row, this.#options.userId)) return row.messageId
    }
    return undefined
  }

  #reaction(messageId: MessageID, emoji: string, action: "add" | "remove"): ActionHandle {
    const current = this.#messageRow(messageId)
    const reactions = current ? predictReactions(current.reactions, emoji, action) : undefined
    const predicted: MessageRow | undefined =
      current && reactions !== current.reactions
        ? { ...withoutReactions(current), ...(reactions && reactions.length > 0 ? { reactions: [...reactions] } : {}) }
        : undefined
    return this.#action(
      { kind: "react", chatId: this.chatId, messageId, emoji, action },
      action === "add" ? "add the reaction" : "remove the reaction",
      predicted,
    )
  }

  #action(intent: Intent, what: string, predicted?: MessageRow): ActionHandle {
    const release = this.#disposed ? () => {} : this.retain()
    const handle = this.#client.intent(intent, predicted ? [{ row: predicted }] : undefined)
    const action = actionHandle(handle, what, {
      store: this.#client.store,
      ...(this.#options.intents ? { tracker: this.#options.intents } : {}),
    })
    void action.finally(release)
    return action
  }

  /** The row of a message by server ID: received by key, or a send from this device found in the window. */
  #messageRow(messageId: MessageID): MessageRow | undefined {
    const store = this.#client.store
    const received = store.peekRow(receivedMessageKey(this.chatId, messageId)) as MessageRow | undefined
    if (received) return received
    for (const key of this.#window.list.peek()) {
      const row = store.peekRow(key) as MessageRow | undefined
      if (row?.messageId === messageId) return row
    }
    return undefined
  }

  #allSending(clientKeys: readonly string[]): boolean {
    const wanted = new Set(clientKeys)
    let found = 0
    for (const key of this.#window.list.peek()) {
      const row = this.#client.store.peekRow(key) as MessageRow | undefined
      if (row?.clientKey !== undefined && wanted.has(row.clientKey)) {
        if (row.state !== "sending") return false
        found += 1
      }
    }
    return found === wanted.size
  }

  // MARK: - Draft and read state

  /** Persist the composer's draft. An older revision than the saved one is ignored by the core. */
  saveDraft(text: string, entities: readonly Entity[] | undefined, revision: number): void {
    if (this.#disposed) return
    this.#client.intent({
      kind: "saveDraft",
      chatId: this.chatId,
      text,
      ...(entities && entities.length > 0 ? { entities: [...entities] } : {}),
      revision,
    })
  }

  /**
   * Move the read frontier to `maxId`, with the Mac client's retry backoff.
   * Never sends a lower frontier than one already sent, and never one past
   * the window's `certifiedThrough` when the core gave it (reading must not
   * cross history that is not known to be contiguous).
   */
  markRead(maxId: MessageID): void {
    if (this.#disposed) return
    const certified = this.window.peek().certifiedThrough
    this.#reads.mark(certified !== undefined && compareMessageIds(maxId, certified) > 0 ? certified : maxId)
  }

  /** The highest frontier the core accepted in this model's life. */
  get readFrontier(): MessageID | undefined {
    return this.#reads.succeeded
  }

  // MARK: - Disposal

  /** Unsubscribe everything. Called when the last user releases; safe to call again. */
  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#disposeScope()
    this.#reads.dispose()
    this.#peerSub?.unsubscribe()
    this.#peerSub = undefined
    this.#window.unsubscribe()
    this.#chatSub.unsubscribe()
    this.#draftSub.unsubscribe()
  }
}

/** Map a send result onto the composer's outcome. Only `accepted` clears the composer. */
export const composerOutcome = (result: SendResult): ComposerSendOutcome => {
  switch (result.status) {
    case "accepted":
      return { status: "accepted" }
    case "rejected":
      return { status: "rejected", reason: result.reason }
    case "uncertain":
      return { status: "rejected", reason: "uncertain" }
  }
}

const withoutEntities = (row: MessageRow): MessageRow => {
  const { entities: _entities, ...rest } = row
  return rest
}

const withoutReactions = (row: MessageRow): MessageRow => {
  const { reactions: _reactions, ...rest } = row
  return rest
}

/**
 * The reactions after the viewer adds or removes one, as the core summarizes
 * them (`queries/rows.ts`): a new emoji goes last; an emoji nobody has left
 * goes. Returns the same array when nothing changes (already there, or not
 * there to remove).
 */
export const predictReactions = (
  reactions: readonly ReactionSummary[] | undefined,
  emoji: string,
  action: "add" | "remove",
): readonly ReactionSummary[] | undefined => {
  const list = reactions ?? []
  const index = list.findIndex((reaction) => reaction.emoji === emoji)
  const existing = index >= 0 ? list[index] : undefined
  if (action === "add") {
    if (existing?.mine) return reactions
    if (!existing) return [...list, { emoji, count: 1, mine: true }]
    return list.map((reaction, i) => (i === index ? { emoji, count: reaction.count + 1, mine: true } : reaction))
  }
  if (!existing?.mine) return reactions
  if (existing.count <= 1) return list.filter((_, i) => i !== index)
  return list.map((reaction, i) => (i === index ? { emoji, count: reaction.count - 1, mine: false } : reaction))
}

/** The key of a message row the server assigned an ID to, for jumping from a link or a reply. */
export const receivedMessageKey = (chatId: ChatID, messageId: MessageID): RowKey =>
  rowKey("message", receivedMessageRowId(chatId, messageId))
