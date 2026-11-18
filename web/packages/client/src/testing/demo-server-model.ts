import {
  DialogFollowMode,
  GetChatHistoryMode,
  Member_Role,
  MessageEntity_Type,
  NotificationSettings_Mode,
  RpcError_Code,
  SearchMessagesFilter,
  SyncSkippedSequence_Reason,
  Update,
  UpdateComposeAction_ComposeAction,
  UserSettings,
  type Chat,
  type Dialog,
  type DialogNotificationSettings_Mode,
  type Member,
  type Message,
  type MessageEntity,
  type Method,
  type RpcCall,
  type RpcResult,
  type Space,
  type User,
} from "@inline-chat/protocol/core"
import type { DemoAccount, DemoChatPlan } from "./demo-account"
import { demoAvatarDataUrl, mixSeed } from "./demo-bytes"
import {
  closeForm,
  encodeExtras,
  extrasFromJson,
  extrasOf,
  extrasToJson,
  mediaKindOf,
  type DemoExtras,
  type DemoModelMessage,
} from "./demo-content"
import { DemoLazyMessages } from "./demo-lazy-messages"
import type { DemoMember, DemoUser } from "./demo-people"
import { chatPeersToUsers, inputPeersToChats, userPeer } from "./demo-peers"
import { DemoTransferError, DemoTransfers } from "./demo-transfers"
import { SeededRandom } from "./rng"
import {
  ServerModel,
  chatPeer,
  encodeDialog,
  encodeMessage,
  type BucketId,
  type ModelChat,
  type ModelMessage,
  type ModelPush,
  type ModelSession,
  type RpcOutcome,
} from "./server-model"
import { inputPeerChatId } from "./server-model/protocol"

/**
 * The server model for the demo: `ServerModel` with the seeded account held
 * lazily (`DemoLazyMessages`), and everything a whole client needs that the
 * test model leaves out:
 *
 * - history in every mode, `getChats`, `getChat`, `getMessages`, answered
 *   from the plan without materializing a chat;
 * - direct messages (user peers on the wire, `demo-peers.ts`), users with
 *   names, usernames and avatars, spaces with rosters and roles, public and
 *   private threads, participants added and removed;
 * - message content (media, entities, forwards, bot blocks, buttons and
 *   forms) on every message the model encodes, pushes included;
 * - uploads and downloads (`demo-transfers.ts`), sends with media and
 *   entities, edits, deletes, reactions, forwards, pins;
 * - dialog actions (pin, archive, open, order, mark unread, notification
 *   and follow modes), read state with "read all", user settings;
 * - compose actions, bot buttons and forms with answers and failures on a
 *   control, server search in a chat and over people.
 *
 * Every change is reported to `onChange`, so the world can persist it. What a
 * restart must keep is exported by `persistedState()` and restored by
 * `restore()`.
 */

/** Sequences and IDs skipped after a restore, so nothing is reused. */
export const DEMO_RESTORE_MARGIN = 10_000

/** 2026-11-01, the zero of `unknownPastMargin`. */
const UNKNOWN_PAST_EPOCH = 1_761_955_200

/**
 * The margin when an earlier session may have run without saving anything:
 * one million, plus 20 a second since 2026-11-01, so two such sessions a
 * minute apart differ by 1,200. It stays a 32-bit sequence until 2030.
 */
export const unknownPastMargin = (nowSeconds: number) =>
  1_000_000 + Math.max(0, nowSeconds - UNKNOWN_PAST_EPOCH) * 20

export type DemoPersistedMessage = {
  id: string
  fromId: string
  text: string
  date: number
  editDate?: number
  replyToMsgId?: string
  randomId?: string
  reactions?: Array<{ userId: string; emoji: string; date: number }>
  extras?: unknown
}

/** Dialog fields the account changed (pin, archive, open, order, unread mark, modes). */
export type DemoDialogOverrides = {
  pinned?: boolean
  pinnedOrder?: string | null
  archived?: boolean
  open?: boolean
  order?: string | null
  unreadMark?: boolean
  followMode?: number | null
  notificationMode?: number | null
}

export type DemoPersistedChat = {
  id: string
  seq: number
  nextId: string
  readMaxId: string
  messages: DemoPersistedMessage[]
  deleted: string[]
  dialog?: DemoDialogOverrides
  /** Pinned message IDs, latest first. */
  pins?: string[]
  /** Participants added (user ID, date) and removed. */
  added?: Array<[string, number]>
  removed?: string[]
}

/** What the simulated server keeps across reloads (in OPFS, in the browser). */
export type DemoPersistedState = {
  version: 2
  seed: number
  scale: string
  /** Seconds; seeded dates are derived from it, so they do not move. */
  anchor: number
  userSeq: number
  chats: DemoPersistedChat[]
  /** `UserSettings` as protobuf JSON, once the account changed them. */
  userSettings?: unknown
}

export type DemoModelChange = { kind: "chat"; chatId: bigint } | { kind: "user" }

export type DemoActionSettings = {
  /** The next N button or form invocations fail. */
  failNext: number
  /** Share of invocations that fail (0 to 1). */
  failureRate: number
  /** How long the bot takes to answer. */
  answerDelayMs: number
}

export type DemoComposeAction = keyof typeof COMPOSE_ACTIONS

const COMPOSE_ACTIONS = {
  typing: UpdateComposeAction_ComposeAction.TYPING,
  uploadingPhoto: UpdateComposeAction_ComposeAction.UPLOADING_PHOTO,
  uploadingDocument: UpdateComposeAction_ComposeAction.UPLOADING_DOCUMENT,
  uploadingVideo: UpdateComposeAction_ComposeAction.UPLOADING_VIDEO,
  recordingVoice: UpdateComposeAction_ComposeAction.RECORDING_VOICE,
  working: UpdateComposeAction_ComposeAction.WORKING,
} as const

export const composeActionFor = (action: DemoComposeAction | null) =>
  action == null ? UpdateComposeAction_ComposeAction.NONE : COMPOSE_ACTIONS[action]

/** `ServerModel`'s private journal and broadcast (see "Needs from others" in the README). */
type ModelInternals = {
  journal<T extends Update | SyncSkippedSequence_Reason>(bucketId: BucketId, build: (seq: number, date: number) => T): T
  broadcast(push: ModelPush, exceptSession?: number): void
}

const ascending = (left: bigint, right: bigint) => (left < right ? -1 : left > right ? 1 : 0)

const fail = (code: RpcError_Code, message: string): RpcOutcome => ({ error: { code, message } })
const badRequest = (what: string) => fail(RpcError_Code.BAD_REQUEST, what)

const SELF_USER: Omit<DemoUser, "id"> = { firstName: "Demo", lastName: "Account", username: "demo", avatar: true }

const TRANSFER_KINDS = new Set(["createUpload", "saveUploadPart", "getUploadState", "finishUpload", "cancelUpload", "getFilePart"])

export class DemoServerModel extends ServerModel {
  readonly account: DemoAccount
  readonly transfers: DemoTransfers
  readonly actionSettings: DemoActionSettings = { failNext: 0, failureRate: 0, answerDelayMs: 600 }
  onChange: ((change: DemoModelChange) => void) | undefined
  /** Runs a server event later (a bot's answer). The world replaces it to track its timers. */
  schedule: (delayMs: number, run: () => void) => void = (delayMs, run) => {
    setTimeout(run, delayMs)
  }
  /** The account's own latest compose action (`SEND_COMPOSE_ACTION`). */
  ownCompose: { chatId: string; action: number; at: number } | undefined

  private readonly internals: ModelInternals
  private readonly plans = new Map<bigint, DemoChatPlan>()
  /** Seeded messages whose stored copy differs from the plan (edited, reacted to). */
  private readonly modified = new Map<bigint, Set<bigint>>()
  private readonly touched = new Set<bigint>()
  private readonly unreadMemo = new Map<bigint, { readMaxId: bigint; version: number; count: number }>()
  private readonly versions = new Map<bigint, number>()
  private readonly dialogState = new Map<bigint, DemoDialogOverrides>()
  private readonly pins = new Map<bigint, bigint[]>()
  private readonly added = new Map<bigint, Map<bigint, number>>()
  private readonly removed = new Map<bigint, Set<bigint>>()
  private readonly rosters = new Map<bigint, Map<bigint, DemoMember>>()
  /** Extras for a message being created right now, before its object exists. */
  private readonly pending = new Map<string, DemoExtras>()
  private readonly chatForUser = new Map<bigint, bigint>()
  private readonly userForChat = new Map<bigint, bigint>()
  private readonly avatars = new Map<bigint, string>()
  private readonly random: SeededRandom
  private userSettings: UserSettings
  private settingsChanged = false
  private nextInteraction = 1n

  constructor(account: DemoAccount, options: { now: () => number }) {
    super({ selfUserId: account.selfUserId, now: options.now })
    this.account = account
    const internals = this as unknown as Partial<ModelInternals>
    if (typeof internals.journal !== "function" || typeof internals.broadcast !== "function") {
      throw new Error("The demo server model needs ServerModel's journal and broadcast")
    }
    this.internals = {
      journal: internals.journal.bind(this) as ModelInternals["journal"],
      broadcast: internals.broadcast.bind(this),
    }
    this.transfers = new DemoTransfers(() => options.now() * 1_000)
    this.random = new SeededRandom(account.seed).fork("demo-server")
    this.users.set(this.selfUserId, { id: this.selfUserId, firstName: SELF_USER.firstName })
    for (const user of account.users) this.addUser(user.id, user.firstName)
    for (const space of account.spaces) {
      const added = this.addSpace(space.id, space.name)
      added.members = space.members.map((member) => member.userId)
      this.rosters.set(space.id, new Map(space.members.map((member) => [member.userId, { ...member }])))
    }
    this.userSettings = UserSettings.create({
      notificationSettings: { mode: NotificationSettings_Mode.ALL, silent: false, disableDmNotifications: false },
      composeSettings: { replacePastedLinksWithTitles: true },
    })
    // A fresh replica starts below the user bucket's head, so its first sync
    // is the snapshot repair (getChats), as a new device's is.
    this.setBucketHead("user", 1, account.anchor)
  }

  /** Add one planned chat, lazily. */
  installChat(plan: DemoChatPlan) {
    const chat = this.addChat({
      id: plan.id,
      title: plan.title,
      ...(plan.spaceId != null ? { spaceId: plan.spaceId } : {}),
      participants: plan.participants,
    })
    chat.messages = new DemoLazyMessages(
      plan.count,
      (id) => this.account.messageAt(plan, id),
      (id) => this.account.holeAt(plan, id),
    )
    chat.nextMessageId = BigInt(plan.count) + 1n
    this.plans.set(plan.id, plan)
    if (plan.peerUserId != null) {
      this.chatForUser.set(plan.peerUserId, plan.id)
      this.userForChat.set(plan.id, plan.peerUserId)
    }
    this.setReadMaxId(plan.id, plan.readMaxId)
    this.setBucketHead(`chat:${plan.id}`, plan.count, plan.lastDate)
  }

  plan(chatId: bigint): DemoChatPlan | undefined {
    return this.plans.get(chatId)
  }

  lazy(chatId: bigint): DemoLazyMessages | undefined {
    const messages = this.chats.get(chatId)?.messages
    return messages instanceof DemoLazyMessages ? messages : undefined
  }

  /** Pinned messages of a chat, latest first. */
  pinnedMessageIds(chatId: bigint): bigint[] {
    return (this.pins.get(chatId) ?? []).slice()
  }

  /** A space's members now (the account included). */
  spaceMembersOf(spaceId: bigint | undefined): bigint[] {
    return spaceId == null ? [] : Array.from(this.rosters.get(spaceId)?.keys() ?? [])
  }

  /** The chat of the direct message with this user. */
  directChat(userId: bigint): bigint | undefined {
    return this.chatForUser.get(userId)
  }

  /** Chats holding every message in memory (for status and tests). */
  materializedChats(): number {
    let count = 0
    for (const chat of this.chats.values()) {
      if (chat.messages instanceof DemoLazyMessages && chat.messages.materialized) count += 1
    }
    return count
  }

  // ---- Changes -------------------------------------------------------------

  private changed(chatId: bigint, user = false) {
    this.touched.add(chatId)
    this.versions.set(chatId, (this.versions.get(chatId) ?? 0) + 1)
    this.onChange?.({ kind: "chat", chatId })
    if (user) this.onChange?.({ kind: "user" })
  }

  private markModified(chatId: bigint, messageId: bigint) {
    if (messageId > BigInt(this.plans.get(chatId)?.count ?? 0)) return
    const set = this.modified.get(chatId) ?? new Set()
    set.add(messageId)
    this.modified.set(chatId, set)
  }

  override postMessage(options: Parameters<ServerModel["postMessage"]>[0]): ModelMessage {
    const message = super.postMessage(options)
    this.changed(options.chatId)
    return message
  }

  /**
   * Post a message with content (media, entities, a forward, bot blocks):
   * the content is in place before the message is journaled and pushed.
   */
  postWithContent(options: {
    chatId: bigint
    fromId: bigint
    text: string
    extras?: DemoExtras
    replyToMsgId?: bigint
  }): DemoModelMessage {
    const chat = this.requireDemoChat(options.chatId)
    const key = `${chat.id}:${chat.nextMessageId}`
    if (options.extras) this.pending.set(key, options.extras)
    try {
      const message = this.postMessage({
        chatId: options.chatId,
        fromId: options.fromId,
        text: options.text,
        ...(options.replyToMsgId != null ? { replyToMsgId: options.replyToMsgId } : {}),
      }) as DemoModelMessage
      if (options.extras) message.extras = options.extras
      return message
    } finally {
      this.pending.delete(key)
    }
  }

  override editMessage(chatId: bigint, messageId: bigint, text: string) {
    super.editMessage(chatId, messageId, text)
    this.markModified(chatId, messageId)
    this.changed(chatId)
  }

  override deleteMessages(chatId: bigint, messageIds: bigint[]) {
    super.deleteMessages(chatId, messageIds)
    for (const id of messageIds) this.modified.get(chatId)?.delete(id)
    this.pins.set(chatId, (this.pins.get(chatId) ?? []).filter((id) => !messageIds.includes(id)))
    this.changed(chatId)
  }

  override addReaction(chatId: bigint, messageId: bigint, userId: bigint, emoji: string) {
    super.addReaction(chatId, messageId, userId, emoji)
    this.markModified(chatId, messageId)
    this.changed(chatId)
  }

  override removeReaction(chatId: bigint, messageId: bigint, userId: bigint, emoji: string) {
    super.removeReaction(chatId, messageId, userId, emoji)
    this.markModified(chatId, messageId)
    this.changed(chatId)
  }

  override readOnOtherDevice(chatId: bigint, maxId: bigint) {
    super.readOnOtherDevice(chatId, maxId)
    this.changed(chatId, true)
  }

  /** Counted from the read boundary; a lazy chat is not materialized. */
  override unreadCount(chatId: bigint): number {
    const messages = this.lazy(chatId)
    if (!messages || messages.materialized) return super.unreadCount(chatId)
    const readMaxId = this.dialogs.get(chatId)?.readMaxId ?? 0n
    const version = this.versions.get(chatId) ?? 0
    const memo = this.unreadMemo.get(chatId)
    if (memo && memo.readMaxId === readMaxId && memo.version === version) return memo.count
    let count = 0
    let after = readMaxId
    while (true) {
      const ids = messages.idsAfter(after, 500)
      for (const id of ids) {
        if (messages.peek(id)?.fromId !== this.selfUserId) count += 1
      }
      if (ids.length < 500) break
      after = ids[ids.length - 1]!
    }
    this.unreadMemo.set(chatId, { readMaxId, version, count })
    return count
  }

  // ---- Server-side events (other people, other devices) ------------------------

  /** Another member (or the agent) starts or stops an action in a chat. Realtime only. */
  composeAction(chatId: bigint, userId: bigint, action: DemoComposeAction | null) {
    this.requireDemoChat(chatId)
    this.push(
      [
        Update.create({
          update: {
            oneofKind: "updateComposeAction",
            updateComposeAction: { userId, peerId: chatPeer(chatId), action: composeActionFor(action) },
          },
        }),
      ],
      "hint",
    )
  }

  /** Someone pins or unpins a message: a chat-bucket `pinnedMessages`. */
  setPinned(chatId: bigint, messageId: bigint, pinned: boolean, exceptSession?: number): Update | undefined {
    const current = this.pins.get(chatId) ?? []
    const next = pinned ? [messageId, ...current.filter((id) => id !== messageId)] : current.filter((id) => id !== messageId)
    if (next.length === current.length && next.every((id, index) => id === current[index])) return undefined
    this.pins.set(chatId, next)
    const ids = next.slice()
    const live = this.internals.journal(`chat:${chatId}`, (seq, date) =>
      Update.create({
        seq,
        date: BigInt(date),
        update: { oneofKind: "pinnedMessages", pinnedMessages: { peerId: chatPeer(chatId), messageIds: ids } },
      }),
    )
    this.push([live], "durable", exceptSession)
    this.changed(chatId)
    return live
  }

  /** Someone adds a person to a private thread: a chat-bucket `participantAdd`. */
  addParticipant(chatId: bigint, userId: bigint, exceptSession?: number) {
    const plan = this.requirePlan(chatId)
    if (plan.peerUserId != null || plan.isPublic) throw new Error("Only private threads have their own participants")
    if (!this.users.has(userId)) throw new Error(`No user ${userId}`)
    if (this.isParticipant(chatId, userId)) {
      return { participant: { userId, date: BigInt(this.participantDate(chatId, userId)) }, update: undefined }
    }
    const date = this.now()
    this.removed.get(chatId)?.delete(userId)
    if (!plan.participants.includes(userId)) {
      const added = this.added.get(chatId) ?? new Map()
      added.set(userId, date)
      this.added.set(chatId, added)
    }
    const participant = { userId, date: BigInt(date) }
    const live = this.internals.journal(`chat:${chatId}`, (seq, journalDate) =>
      Update.create({
        seq,
        date: BigInt(journalDate),
        update: { oneofKind: "participantAdd", participantAdd: { chatId, participant } },
      }),
    )
    this.push([live], "durable", exceptSession)
    this.changed(chatId)
    return { participant, update: live }
  }

  /** Someone removes a person from a private thread: a chat-bucket `participantDelete`. */
  removeParticipant(chatId: bigint, userId: bigint, exceptSession?: number): Update | undefined {
    const plan = this.requirePlan(chatId)
    if (plan.peerUserId != null || plan.isPublic) throw new Error("Only private threads have their own participants")
    if (userId === this.selfUserId) throw new Error("Removing the account itself is not modeled")
    if (!this.isParticipant(chatId, userId)) return undefined
    this.added.get(chatId)?.delete(userId)
    if (plan.participants.includes(userId)) {
      const removed = this.removed.get(chatId) ?? new Set()
      removed.add(userId)
      this.removed.set(chatId, removed)
    }
    const live = this.internals.journal(`chat:${chatId}`, (seq, date) =>
      Update.create({
        seq,
        date: BigInt(date),
        update: { oneofKind: "participantDelete", participantDelete: { chatId, userId } },
      }),
    )
    this.push([live], "durable", exceptSession)
    this.changed(chatId)
    return live
  }

  /**
   * The account changes a dialog on another device (or this one, through an
   * RPC): user-bucket records as the server writes them.
   */
  updateDialog(chatId: bigint, change: DemoDialogOverrides, exceptSession?: number): Update[] {
    const chat = this.requireDemoChat(chatId)
    const state = { ...this.dialogState.get(chatId), ...change }
    this.dialogState.set(chatId, state)
    if (change.notificationMode !== undefined) {
      const dialog = this.dialogs.get(chatId)
      if (dialog) {
        if (change.notificationMode == null) delete dialog.notificationMode
        else dialog.notificationMode = change.notificationMode as DialogNotificationSettings_Mode
      }
    }
    const peerId = chatPeer(chatId)
    const updates: Update[] = []
    const journal = (build: () => Update["update"]) => {
      const payload = build()
      updates.push(
        this.internals.journal("user", (seq, date) => Update.create({ seq, date: BigInt(date), update: payload })),
      )
    }
    if (change.archived !== undefined) {
      journal(() => ({ oneofKind: "dialogArchived", dialogArchived: { peerId, archived: change.archived! } }))
    }
    if (change.unreadMark !== undefined) {
      journal(() => ({ oneofKind: "markAsUnread", markAsUnread: { peerId, unreadMark: change.unreadMark! } }))
    }
    if (change.notificationMode !== undefined) {
      const mode = change.notificationMode
      journal(() => ({
        oneofKind: "dialogNotificationSettings",
        dialogNotificationSettings: {
          peerId,
          ...(mode != null ? { notificationSettings: { mode: mode as DialogNotificationSettings_Mode } } : {}),
        },
      }))
    }
    if (change.followMode !== undefined) {
      const mode = change.followMode
      journal(() => ({
        oneofKind: "dialogFollowMode",
        dialogFollowMode: { peerId, ...(mode != null ? { followMode: mode as DialogFollowMode } : {}) },
      }))
    }
    if (
      change.pinned !== undefined ||
      change.pinnedOrder !== undefined ||
      change.open !== undefined ||
      change.order !== undefined
    ) {
      // The open projection carries the dialog as it is now (`userChatOpen`).
      const open = { chat: this.encodeDemoChat(chat), dialog: this.encodeDemoDialog(chat) }
      journal(() => ({ oneofKind: "chatOpen", chatOpen: open }))
    }
    this.push(updates, "durable", exceptSession)
    this.changed(chatId, true)
    return updates
  }

  // ---- Output decoration -----------------------------------------------------------

  /** Live pushes carry demo content and direct-message peers like results do. */
  override connect(sink: (push: ModelPush) => void): ModelSession {
    return super.connect((push) => sink({ ...push, updates: this.decorateUpdates(push.updates) }))
  }

  private push(updates: Update[], kind: ModelPush["kind"], exceptSession?: number) {
    if (updates.length === 0) return
    this.internals.broadcast({ updates, kind }, exceptSession)
  }

  private storedMessage(chatId: bigint, messageId: bigint): DemoModelMessage | undefined {
    const messages = this.chats.get(chatId)?.messages
    if (!messages) return undefined
    return (messages instanceof DemoLazyMessages ? messages.peek(messageId) : messages.get(messageId)) as
      | DemoModelMessage
      | undefined
  }

  /** A wire message with the demo content of the stored one. */
  decorateMessage(message: Message): Message {
    const stored = this.storedMessage(message.chatId, message.id)
    const extras = extrasOf(stored) ?? this.pending.get(`${message.chatId}:${message.id}`)
    if (!extras) return message
    return { ...message, ...encodeExtras(extras, message.chatId, message.id, message.date) }
  }

  encodeDemoMessage(message: ModelMessage): Message {
    return this.decorateMessage(encodeMessage(message, this.selfUserId))
  }

  private decorateUpdates(updates: Update[]): Update[] {
    const decorated = updates.map((update) => {
      const value = update.update
      if (value.oneofKind === "newMessage" && value.newMessage.message) {
        return { ...update, update: { ...value, newMessage: { message: this.decorateMessage(value.newMessage.message) } } }
      }
      if (value.oneofKind === "editMessage" && value.editMessage.message) {
        return { ...update, update: { ...value, editMessage: { message: this.decorateMessage(value.editMessage.message) } } }
      }
      return update
    })
    return this.userForChat.size > 0 ? chatPeersToUsers(decorated, this.userForChat) : decorated
  }

  private decorateResult(result: RpcResult["result"]): RpcResult["result"] {
    if (result.oneofKind === "getUpdates") {
      const page = result.getUpdates
      const sidecars = page.sidecars
      const chatIds = new Set<bigint>()
      for (const chat of sidecars?.chats ?? []) chatIds.add(chat.id)
      // The server sends the dialogs a user-bucket page names, as they are now.
      for (const update of page.updates) {
        const value = update.update
        const peer =
          value.oneofKind === "dialogArchived"
            ? value.dialogArchived.peerId
            : value.oneofKind === "markAsUnread"
              ? value.markAsUnread.peerId
              : value.oneofKind === "dialogNotificationSettings"
                ? value.dialogNotificationSettings.peerId
                : value.oneofKind === "dialogFollowMode"
                  ? value.dialogFollowMode.peerId
                  : value.oneofKind === "updateReadMaxId"
                    ? value.updateReadMaxId.peerId
                    : undefined
        if (peer?.type.oneofKind === "chat") chatIds.add(peer.type.chat.chatId)
      }
      const chats = Array.from(chatIds).flatMap((id) => {
        const chat = this.chats.get(id)
        return chat ? [chat] : []
      })
      const userIds = new Set((sidecars?.users ?? []).map((user) => user.id))
      for (const id of chatIds) {
        const peer = this.userForChat.get(id)
        if (peer != null) userIds.add(peer)
      }
      const decorated = {
        ...page,
        updates: this.decorateUpdates(page.updates),
        ...(sidecars || chats.length > 0
          ? {
              sidecars: {
                users: Array.from(userIds).flatMap((id) => this.encodeDemoUserOrEmpty(id)),
                chats: chats.map((chat) => this.encodeDemoChat(chat)),
                dialogs: chats.map((chat) => this.encodeDemoDialog(chat)),
                spaces: [],
                userGroups: [],
              },
            }
          : {}),
      }
      return chatPeersToUsers({ oneofKind: "getUpdates", getUpdates: decorated }, this.userForChat)
    }
    const payload = (result as { [key: string]: unknown })[result.oneofKind ?? ""] as { updates?: unknown } | undefined
    if (payload && Array.isArray(payload.updates)) {
      const next = { ...payload, updates: this.decorateUpdates(payload.updates as Update[]) }
      return chatPeersToUsers({ ...result, [result.oneofKind!]: next } as RpcResult["result"], this.userForChat)
    }
    return this.userForChat.size > 0 ? chatPeersToUsers(result, this.userForChat) : result
  }

  // ---- Encoders ------------------------------------------------------------------

  private demoUser(id: bigint): DemoUser | undefined {
    return id === this.selfUserId ? { id, ...SELF_USER } : this.account.user(id)
  }

  encodeDemoUser(id: bigint): User | undefined {
    const user = this.demoUser(id)
    if (!user) return undefined
    let avatar: string | undefined
    if (user.avatar) {
      avatar = this.avatars.get(id)
      if (!avatar) {
        avatar = demoAvatarDataUrl(mixSeed(this.account.seed, 0x0a7a7a2, Number(id)))
        this.avatars.set(id, avatar)
      }
    }
    return {
      id,
      firstName: user.firstName,
      ...(user.lastName ? { lastName: user.lastName } : {}),
      ...(user.username ? { username: user.username } : {}),
      min: id !== this.selfUserId,
      ...(user.bot ? { bot: true } : {}),
      ...(avatar
        ? { profilePhoto: { photoId: 5_000_000n + id, fileUniqueId: `avatar_${id}`, cdnUrl: avatar } }
        : {}),
    }
  }

  private encodeDemoUserOrEmpty(id: bigint): User[] {
    const user = this.encodeDemoUser(id)
    return user ? [user] : []
  }

  private latest(chat: ModelChat): ModelMessage | undefined {
    const messages = chat.messages
    if (messages instanceof DemoLazyMessages) return messages.latest()
    let latest: ModelMessage | undefined
    for (const message of messages.values()) {
      if (!latest || message.id > latest.id) latest = message
    }
    return latest
  }

  encodeDemoChat(chat: ModelChat): Chat {
    const latest = this.latest(chat)
    const plan = this.plans.get(chat.id)
    const peerUserId = this.userForChat.get(chat.id)
    return {
      id: chat.id,
      title: chat.title,
      peerId: peerUserId != null ? userPeer(peerUserId) : chatPeer(chat.id),
      ...(chat.spaceId != null ? { spaceId: chat.spaceId } : {}),
      ...(plan?.isPublic != null ? { isPublic: plan.isPublic } : {}),
      ...(latest ? { lastMsgId: latest.id, date: latest.date } : {}),
      // The server encodes a chat with its bucket's current sequence (`encodeChat.ts`).
      seq: this.bucketSeq(`chat:${chat.id}`),
    }
  }

  /** The dialog with the sidebar fields the server always sends. */
  encodeDemoDialog(chat: ModelChat): Dialog {
    const dialog = this.dialogs.get(chat.id) ?? { chatId: chat.id, readMaxId: 0n }
    const plan = this.plans.get(chat.id)
    const state = this.dialogState.get(chat.id) ?? {}
    const peerUserId = this.userForChat.get(chat.id)
    const pinnedOrder = state.pinnedOrder === undefined ? plan?.pinnedOrder : (state.pinnedOrder ?? undefined)
    const order = state.order === undefined ? plan?.order : (state.order ?? undefined)
    return {
      ...encodeDialog(chat, dialog, this.unreadCount(chat.id)),
      ...(peerUserId != null ? { peer: userPeer(peerUserId) } : {}),
      pinned: state.pinned ?? plan?.pinned ?? false,
      archived: state.archived ?? plan?.archived ?? false,
      open: state.open ?? plan?.open ?? true,
      unreadMark: state.unreadMark ?? false,
      ...(order ? { order } : {}),
      ...(pinnedOrder ? { pinnedOrder } : {}),
      ...(state.followMode != null ? { followMode: state.followMode as DialogFollowMode } : {}),
    }
  }

  private encodeSpace(space: { id: bigint; name: string }, index: number): Space {
    return {
      id: space.id,
      name: space.name,
      creator: index === 0,
      date: BigInt(this.account.anchor - 400 * 24 * 60 * 60),
      seq: this.bucketSeq(`space:${space.id}`),
    }
  }

  private encodeMember(spaceId: bigint, member: DemoMember): Member {
    return {
      id: spaceId * 100_000n + member.userId,
      spaceId,
      userId: member.userId,
      role: member.role,
      date: BigInt(member.date),
      canAccessPublicChats: true,
    }
  }

  // ---- Membership --------------------------------------------------------------------

  private isParticipant(chatId: bigint, userId: bigint) {
    return this.participantsOf(chatId).some((participant) => participant.userId === userId)
  }

  private participantDate(chatId: bigint, userId: bigint) {
    return this.participantsOf(chatId).find((participant) => participant.userId === userId)?.date ?? 0
  }

  /** Who is in a chat now: both people of a direct message, a public thread's space, or a thread's list. */
  participantsOf(chatId: bigint): Array<{ userId: bigint; date: number }> {
    const plan = this.requirePlan(chatId)
    const base = this.account.anchor - 200 * 24 * 60 * 60
    if (plan.isPublic && plan.spaceId != null) {
      return Array.from(this.rosters.get(plan.spaceId)?.values() ?? []).map((member) => ({
        userId: member.userId,
        date: member.date,
      }))
    }
    const removed = this.removed.get(chatId)
    const list = plan.participants
      .filter((userId) => !removed?.has(userId))
      .map((userId) => ({ userId, date: base }))
    for (const [userId, date] of this.added.get(chatId) ?? []) {
      if (!list.some((entry) => entry.userId === userId)) list.push({ userId, date })
    }
    return list
  }

  // ---- RPC -------------------------------------------------------------------------

  override handleRpc(sessionId: number, method: Method, input: RpcCall["input"]): RpcOutcome {
    const normalized = this.chatForUser.size > 0 ? inputPeersToChats(input, this.chatForUser) : input
    let outcome: RpcOutcome | undefined
    try {
      outcome = this.dispatchDemo(sessionId, normalized)
    } catch (error) {
      outcome =
        error instanceof DemoTransferError
          ? fail(error.code, error.message)
          : fail(RpcError_Code.BAD_REQUEST, error instanceof Error ? error.message : String(error))
    }
    if (outcome) {
      this.rpcLog.push({ session: sessionId, method, ok: "result" in outcome })
    } else {
      outcome = super.handleRpc(sessionId, method, normalized)
    }
    return "result" in outcome ? { result: this.decorateResult(outcome.result) } : outcome
  }

  /** The RPCs the demo answers itself; undefined hands the call to `ServerModel`. */
  private dispatchDemo(sessionId: number, input: RpcCall["input"]): RpcOutcome | undefined {
    if (input.oneofKind && TRANSFER_KINDS.has(input.oneofKind)) return this.transfer(input)
    switch (input.oneofKind) {
      case "getMe":
        return { result: { oneofKind: "getMe", getMe: { user: this.encodeDemoUser(this.selfUserId)! } } }
      case "logOut":
        // The session ends on the client; the demo server has nothing to revoke.
        return { result: { oneofKind: "logOut", logOut: { loggedOut: true } } }
      case "getChats":
        return this.demoChats()
      case "getChat": {
        const chat = this.chatFor(inputPeerChatId(input.getChat.peerId))
        if (!chat) return fail(RpcError_Code.PEER_ID_INVALID, "peer")
        const peerUserId = this.userForChat.get(chat.id)
        return {
          result: {
            oneofKind: "getChat",
            getChat: {
              chat: this.encodeDemoChat(chat),
              dialog: this.encodeDemoDialog(chat),
              pinnedMessageIds: (this.pins.get(chat.id) ?? []).slice(),
              messages: [],
              ...(peerUserId != null ? { user: this.encodeDemoUser(peerUserId) } : {}),
            },
          },
        }
      }
      case "getChatHistory":
        return this.demoHistory(input.getChatHistory)
      case "getMessages": {
        const chat = this.chatFor(inputPeerChatId(input.getMessages.peerId))
        if (!chat) return fail(RpcError_Code.PEER_ID_INVALID, "peer")
        const messages = input.getMessages.messageIds.flatMap((id) => {
          const message = this.storedMessage(chat.id, id)
          return message ? [this.encodeDemoMessage(message)] : []
        })
        return {
          result: {
            oneofKind: "getMessages",
            getMessages: { messages, seq: BigInt(this.bucketSeq(`chat:${chat.id}`)) },
          },
        }
      }
      case "sendMessage":
        return this.sendWithContent(sessionId, input)
      case "readMessages":
        return this.demoRead(sessionId, input)
      case "editMessage": {
        const { messageId, text } = input.editMessage
        const chat = this.chatFor(inputPeerChatId(input.editMessage.peerId))
        if (!chat) return fail(RpcError_Code.PEER_ID_INVALID, "peer")
        const message = this.storedMessage(chat.id, messageId)
        if (!message) return fail(RpcError_Code.MESSAGE_ID_INVALID, "message")
        if (message.fromId !== this.selfUserId) return badRequest("not your message")
        const own = this.lazy(chat.id)?.get(messageId) ?? message
        const entities = input.editMessage.entities?.entities
        ;(own as DemoModelMessage).extras = { ...extrasOf(own), entities: entities ?? [] }
        if (!entities || entities.length === 0) delete (own as DemoModelMessage).extras!.entities
        const update = this.journalMessage("editMessage", chat.id, messageId, () => {
          own.text = text
          own.editDate = BigInt(this.now())
        }, sessionId)
        this.markModified(chat.id, messageId)
        this.changed(chat.id)
        return { result: { oneofKind: "editMessage", editMessage: { updates: [update] } } }
      }
      case "deleteMessages": {
        const chat = this.chatFor(inputPeerChatId(input.deleteMessages.peerId))
        if (!chat) return fail(RpcError_Code.PEER_ID_INVALID, "peer")
        const ids = input.deleteMessages.messageIds.filter((id) => chat.messages.has(id))
        if (ids.length === 0) {
          return { result: { oneofKind: "deleteMessages", deleteMessages: { updates: [] } } }
        }
        for (const id of ids) chat.messages.delete(id)
        for (const id of ids) this.modified.get(chat.id)?.delete(id)
        const live = this.internals.journal(`chat:${chat.id}`, (seq, date) =>
          Update.create({
            seq,
            date: BigInt(date),
            update: { oneofKind: "deleteMessages", deleteMessages: { messageIds: ids, peerId: chatPeer(chat.id) } },
          }),
        )
        this.push([live], "durable", sessionId)
        if (ids.some((id) => (this.pins.get(chat.id) ?? []).includes(id))) {
          this.pins.set(chat.id, (this.pins.get(chat.id) ?? []).filter((id) => !ids.includes(id)))
        }
        this.changed(chat.id)
        return { result: { oneofKind: "deleteMessages", deleteMessages: { updates: [live] } } }
      }
      case "addReaction":
      case "deleteReaction": {
        const value = input.oneofKind === "addReaction" ? input.addReaction : input.deleteReaction
        const chat = this.chatFor(inputPeerChatId(value.peerId))
        if (!chat) return fail(RpcError_Code.PEER_ID_INVALID, "peer")
        if (!chat.messages.has(value.messageId)) return fail(RpcError_Code.MESSAGE_ID_INVALID, "message")
        const date = BigInt(this.now())
        if (input.oneofKind === "addReaction") {
          this.addReaction(chat.id, value.messageId, this.selfUserId, value.emoji)
          const update = Update.create({
            update: {
              oneofKind: "updateReaction",
              updateReaction: {
                reaction: { emoji: value.emoji, userId: this.selfUserId, messageId: value.messageId, chatId: chat.id, date },
              },
            },
          })
          return { result: { oneofKind: "addReaction", addReaction: { updates: [update] } } }
        }
        this.removeReaction(chat.id, value.messageId, this.selfUserId, value.emoji)
        const update = Update.create({
          update: {
            oneofKind: "deleteReaction",
            deleteReaction: { emoji: value.emoji, chatId: chat.id, messageId: value.messageId, userId: this.selfUserId },
          },
        })
        return { result: { oneofKind: "deleteReaction", deleteReaction: { updates: [update] } } }
      }
      case "forwardMessages": {
        const from = this.chatFor(inputPeerChatId(input.forwardMessages.fromPeerId))
        const to = this.chatFor(inputPeerChatId(input.forwardMessages.toPeerId))
        if (!from || !to) return fail(RpcError_Code.PEER_ID_INVALID, "peer")
        const header = input.forwardMessages.shareForwardHeader !== false
        const updates: Update[] = []
        for (const id of input.forwardMessages.messageIds.slice().sort(ascending)) {
          const source = this.storedMessage(from.id, id)
          if (!source) continue
          const sourceExtras = extrasOf(source)
          const extras: DemoExtras = {
            ...(sourceExtras?.media ? { media: sourceExtras.media } : {}),
            ...(sourceExtras?.entities ? { entities: sourceExtras.entities } : {}),
            ...(header
              ? { fwdFrom: { fromPeerId: chatPeer(from.id), fromId: source.fromId, fromMessageId: source.id } }
              : {}),
          }
          const message = this.postWithContent({ chatId: to.id, fromId: this.selfUserId, text: source.text, extras })
          updates.push(
            Update.create({
              update: { oneofKind: "newMessage", newMessage: { message: this.encodeDemoMessage(message) } },
            }),
          )
        }
        return { result: { oneofKind: "forwardMessages", forwardMessages: { updates } } }
      }
      case "pinMessage": {
        const chat = this.chatFor(inputPeerChatId(input.pinMessage.peerId))
        if (!chat) return fail(RpcError_Code.PEER_ID_INVALID, "peer")
        if (!chat.messages.has(input.pinMessage.messageId)) return fail(RpcError_Code.MESSAGE_ID_INVALID, "message")
        const update = this.setPinned(chat.id, input.pinMessage.messageId, !input.pinMessage.unpin, sessionId)
        return { result: { oneofKind: "pinMessage", pinMessage: { updates: update ? [update] : [] } } }
      }
      case "updateDialogArchived": {
        const chat = this.chatFor(inputPeerChatId(input.updateDialogArchived.peerId))
        if (!chat) return fail(RpcError_Code.PEER_ID_INVALID, "peer")
        const updates = this.updateDialog(chat.id, { archived: input.updateDialogArchived.archived }, sessionId)
        return { result: { oneofKind: "updateDialogArchived", updateDialogArchived: { updates: unsequenced(updates) } } }
      }
      case "markAsUnread": {
        const chat = this.chatFor(inputPeerChatId(input.markAsUnread.peerId))
        if (!chat) return fail(RpcError_Code.PEER_ID_INVALID, "peer")
        const already = this.dialogState.get(chat.id)?.unreadMark === true
        const updates = already ? [] : this.updateDialog(chat.id, { unreadMark: true }, sessionId)
        return { result: { oneofKind: "markAsUnread", markAsUnread: { updates: unsequenced(updates) } } }
      }
      case "updateDialogNotificationSettings": {
        const chat = this.chatFor(inputPeerChatId(input.updateDialogNotificationSettings.peerId))
        if (!chat) return fail(RpcError_Code.PEER_ID_INVALID, "peer")
        const mode = input.updateDialogNotificationSettings.notificationSettings?.mode
        const updates = this.updateDialog(chat.id, { notificationMode: mode ?? null }, sessionId)
        return {
          result: {
            oneofKind: "updateDialogNotificationSettings",
            updateDialogNotificationSettings: { updates: unsequenced(updates) },
          },
        }
      }
      case "updateDialogFollowMode": {
        const chat = this.chatFor(inputPeerChatId(input.updateDialogFollowMode.peerId))
        if (!chat) return fail(RpcError_Code.PEER_ID_INVALID, "peer")
        const mode = input.updateDialogFollowMode.followMode
        const updates = this.updateDialog(chat.id, { followMode: mode ?? null }, sessionId)
        return {
          result: { oneofKind: "updateDialogFollowMode", updateDialogFollowMode: { updates: unsequenced(updates) } },
        }
      }
      case "updateDialogOrder":
      case "updateDialogOpen":
      case "showInChatList": {
        const peerId =
          input.oneofKind === "updateDialogOrder"
            ? input.updateDialogOrder.peerId
            : input.oneofKind === "updateDialogOpen"
              ? input.updateDialogOpen.peerId
              : input.showInChatList.peerId
        const chat = this.chatFor(inputPeerChatId(peerId))
        if (!chat) return fail(RpcError_Code.PEER_ID_INVALID, "peer")
        const change: DemoDialogOverrides = {}
        if (input.oneofKind === "updateDialogOrder") {
          const value = input.updateDialogOrder
          if (value.pinned != null) {
            change.pinned = value.pinned
            if (value.pinned) change.pinnedOrder = value.pinnedOrder ?? this.nextPinnedOrder()
            else change.pinnedOrder = null
          } else if (value.pinnedOrder != null) {
            change.pinnedOrder = value.pinnedOrder
          }
          if (value.order != null) change.order = value.order
        } else if (input.oneofKind === "updateDialogOpen") {
          change.open = input.updateDialogOpen.open
          if (input.updateDialogOpen.open) {
            change.order = input.updateDialogOpen.order ?? this.nextOrder()
            change.archived = false
          }
        } else {
          change.open = true
          change.order = this.encodeDemoDialog(chat).order ?? this.nextOrder()
        }
        this.updateDialog(chat.id, change, sessionId)
        const peerUserId = this.userForChat.get(chat.id)
        const response = {
          chat: this.encodeDemoChat(chat),
          dialog: this.encodeDemoDialog(chat),
          ...(peerUserId != null && input.oneofKind !== "showInChatList" ? { user: this.encodeDemoUser(peerUserId) } : {}),
        }
        return input.oneofKind === "updateDialogOrder"
          ? { result: { oneofKind: "updateDialogOrder", updateDialogOrder: response } }
          : input.oneofKind === "updateDialogOpen"
            ? { result: { oneofKind: "updateDialogOpen", updateDialogOpen: response } }
            : { result: { oneofKind: "showInChatList", showInChatList: response } }
      }
      case "getUserSettings":
        return { result: { oneofKind: "getUserSettings", getUserSettings: { userSettings: this.userSettings } } }
      case "updateUserSettings": {
        const patch = input.updateUserSettings.userSettings
        if (!patch) return badRequest("settings")
        this.userSettings = mergeSettings(this.userSettings, patch)
        this.settingsChanged = true
        const settings = this.userSettings
        const live = this.internals.journal("user", (seq, date) =>
          Update.create({ seq, date: BigInt(date), update: { oneofKind: "updateUserSettings", updateUserSettings: { settings } } }),
        )
        this.push([live], "durable", sessionId)
        this.onChange?.({ kind: "user" })
        return {
          result: { oneofKind: "updateUserSettings", updateUserSettings: { updates: unsequenced([live]) } },
        }
      }
      case "getChatParticipants": {
        const chatId = input.getChatParticipants.chatId
        if (!this.plans.has(chatId)) return fail(RpcError_Code.CHAT_ID_INVALID, "chat")
        const participants = this.participantsOf(chatId)
        return {
          result: {
            oneofKind: "getChatParticipants",
            getChatParticipants: {
              participants: participants.map((entry) => ({ userId: entry.userId, date: BigInt(entry.date) })),
              users: participants.flatMap((entry) => this.encodeDemoUserOrEmpty(entry.userId)),
              groupParticipants: [],
              groups: [],
            },
          },
        }
      }
      case "addChatParticipant": {
        const { chatId, userId } = input.addChatParticipant
        if (userId == null) return badRequest("user groups are not modeled")
        if (!this.plans.has(chatId)) return fail(RpcError_Code.CHAT_ID_INVALID, "chat")
        if (!this.users.has(userId)) return fail(RpcError_Code.USER_ID_INVALID, "user")
        const plan = this.plans.get(chatId)!
        if (plan.peerUserId != null || plan.isPublic) return badRequest("not a private thread")
        const { participant } = this.addParticipant(chatId, userId, sessionId)
        return {
          result: {
            oneofKind: "addChatParticipant",
            addChatParticipant: { participant, users: this.encodeDemoUserOrEmpty(userId) },
          },
        }
      }
      case "removeChatParticipant": {
        const { chatId, userId } = input.removeChatParticipant
        if (userId == null) return badRequest("user groups are not modeled")
        const plan = this.plans.get(chatId)
        if (!plan) return fail(RpcError_Code.CHAT_ID_INVALID, "chat")
        if (plan.peerUserId != null || plan.isPublic) return badRequest("not a private thread")
        this.removeParticipant(chatId, userId, sessionId)
        return { result: { oneofKind: "removeChatParticipant", removeChatParticipant: {} } }
      }
      case "getSpaces":
        return {
          result: {
            oneofKind: "getSpaces",
            getSpaces: { spaces: this.account.spaces.map((space, index) => this.encodeSpace(space, index)) },
          },
        }
      case "getSpace": {
        const index = this.account.spaces.findIndex((space) => space.id === input.getSpace.spaceId)
        const space = this.account.spaces[index]
        const self = space ? this.rosters.get(space.id)?.get(this.selfUserId) : undefined
        if (!space || !self) return fail(RpcError_Code.SPACE_ID_INVALID, "space")
        return {
          result: {
            oneofKind: "getSpace",
            getSpace: { space: this.encodeSpace(space, index), membership: this.encodeMember(space.id, self) },
          },
        }
      }
      case "getSpaceMembers": {
        const spaceId = input.getSpaceMembers.spaceId
        const roster = this.rosters.get(spaceId)
        if (!roster) return fail(RpcError_Code.SPACE_ID_INVALID, "space")
        const members = Array.from(roster.values())
        return {
          result: {
            oneofKind: "getSpaceMembers",
            getSpaceMembers: {
              members: members.map((member) => this.encodeMember(spaceId, member)),
              users: members.flatMap((member) => this.encodeDemoUserOrEmpty(member.userId)),
              seq: this.bucketSeq(`space:${spaceId}`),
            },
          },
        }
      }
      case "sendComposeAction": {
        const chatId = inputPeerChatId(input.sendComposeAction.peerId)
        if (chatId == null || !this.plans.has(chatId)) return fail(RpcError_Code.PEER_ID_INVALID, "peer")
        this.ownCompose = {
          chatId: chatId.toString(),
          action: input.sendComposeAction.action ?? UpdateComposeAction_ComposeAction.NONE,
          at: this.now(),
        }
        return { result: { oneofKind: "sendComposeAction", sendComposeAction: {} } }
      }
      case "invokeMessageAction":
        return this.demoInvoke(input.invokeMessageAction)
      case "searchMessages":
        return this.demoSearch(input.searchMessages)
      case "searchUsers": {
        const query = input.searchUsers.query.trim().toLowerCase()
        const limit = Math.min(50, Math.max(1, input.searchUsers.limit ?? 20))
        const users = query
          ? this.account.users
              .filter((user) =>
                [user.firstName, user.lastName ?? "", user.username ?? ""].some((field) =>
                  field.toLowerCase().includes(query),
                ),
              )
              .slice(0, limit)
              .flatMap((user) => this.encodeDemoUserOrEmpty(user.id))
          : []
        return { result: { oneofKind: "searchUsers", searchUsers: { users } } }
      }
      default:
        return undefined
    }
  }

  private chatFor(chatId: bigint | undefined): ModelChat | undefined {
    return chatId == null ? undefined : this.chats.get(chatId)
  }

  private requireDemoChat(chatId: bigint): ModelChat {
    const chat = this.chats.get(chatId)
    if (!chat) throw new Error(`No chat ${chatId} in the demo account`)
    return chat
  }

  private requirePlan(chatId: bigint): DemoChatPlan {
    const plan = this.plans.get(chatId)
    if (!plan) throw new Error(`No chat ${chatId} in the demo account`)
    return plan
  }

  private nextPinnedOrder() {
    let low = "p0"
    for (const chat of this.chats.values()) {
      const order = this.encodeDemoDialog(chat).pinnedOrder
      if (order && order < low) low = order
    }
    // Before every other pinned row.
    return `${low.slice(0, -1)}${String.fromCharCode(Math.max(33, low.charCodeAt(low.length - 1) - 1))}0`
  }

  private nextOrder() {
    let low: string | undefined
    for (const chat of this.chats.values()) {
      const order = this.encodeDemoDialog(chat).order
      if (order && (!low || order < low)) low = order
    }
    return low ? `${low.slice(0, -1)}${String.fromCharCode(Math.max(33, low.charCodeAt(low.length - 1) - 1))}0` : "o0000"
  }

  /** A chat-bucket message record (re-read when served, as the base model's are). */
  private journalMessage(
    kind: "newMessage" | "editMessage",
    chatId: bigint,
    messageId: bigint,
    apply: () => void,
    exceptSession?: number,
  ): Update {
    apply()
    const live = this.internals.journal(`chat:${chatId}`, (seq, date) => {
      const message = this.storedMessage(chatId, messageId)
      if (!message) {
        return Update.create({ seq, date: BigInt(date), update: { oneofKind: "chatSkipPts", chatSkipPts: { chatId } } })
      }
      const encoded = this.encodeDemoMessage(message)
      return Update.create({
        seq,
        date: BigInt(date),
        update:
          kind === "newMessage"
            ? { oneofKind: "newMessage", newMessage: { message: encoded } }
            : { oneofKind: "editMessage", editMessage: { message: encoded } },
      })
    })
    this.push([live], "durable", exceptSession)
    return live
  }

  /** A message changed by the server itself (a bot closing its form): an edit for everyone. */
  replaceExtras(chatId: bigint, messageId: bigint, extras: DemoExtras) {
    const message = this.lazy(chatId)?.get(messageId) ?? this.storedMessage(chatId, messageId)
    if (!message) return
    this.journalMessage("editMessage", chatId, messageId, () => {
      ;(message as DemoModelMessage).extras = extras
      message.editDate = BigInt(this.now())
    })
    this.markModified(chatId, messageId)
    this.changed(chatId)
  }

  private sendWithContent(
    sessionId: number,
    input: Extract<RpcCall["input"], { oneofKind: "sendMessage" }>,
  ): RpcOutcome | undefined {
    const value = input.sendMessage
    const chatId = inputPeerChatId(value.peerId)
    const chat = this.chatFor(chatId)
    if (!chat) return fail(RpcError_Code.PEER_ID_INVALID, "peer")
    const extras: DemoExtras = {}
    const media = value.media?.media
    if (media?.oneofKind) {
      const id =
        media.oneofKind === "photo"
          ? media.photo.photoId
          : media.oneofKind === "video"
            ? media.video.videoId
            : media.oneofKind === "document"
              ? media.document.documentId
              : media.oneofKind === "voice"
                ? media.voice.voiceId
                : undefined
      const kind = media.oneofKind
      const found = id != null && kind !== "nudge" ? this.transfers.media(kind, id) : undefined
      const known = value.randomId != null && this.messagesWithRandomId(value.randomId).length > 0
      if (!found && !known) return fail(RpcError_Code.MEDIA_NOT_OWNED, "media")
      if (found) extras.media = { kind: "wire", media: found }
    }
    const entities = value.entities?.entities ?? []
    if (entities.length > 0) extras.entities = entities
    const key = `${chat.id}:${chat.nextMessageId}`
    const content = Object.keys(extras).length > 0
    if (content) this.pending.set(key, extras)
    try {
      const outcome = super.handleRpc(sessionId, 0 as Method, input)
      if ("result" in outcome && content && value.randomId != null) {
        const sent = this.messagesWithRandomId(value.randomId)[0] as DemoModelMessage | undefined
        if (sent && !sent.extras) sent.extras = extras
      }
      // `super.handleRpc` logged the call; the caller logs it again.
      this.rpcLog.pop()
      if ("result" in outcome) this.changed(chat.id)
      return outcome
    } finally {
      this.pending.delete(key)
    }
  }

  private demoRead(
    sessionId: number,
    input: Extract<RpcCall["input"], { oneofKind: "readMessages" }>,
  ): RpcOutcome | undefined {
    const chat = this.chatFor(inputPeerChatId(input.readMessages.peerId))
    if (!chat) return fail(RpcError_Code.PEER_ID_INVALID, "peer")
    const extra: Update[] = []
    if (this.dialogState.get(chat.id)?.unreadMark) {
      extra.push(...unsequenced(this.updateDialog(chat.id, { unreadMark: false }, sessionId)))
    }
    // No `maxId`: the server reads to the latest message ("Mark as Read").
    const maxId = input.readMessages.maxId ?? this.latest(chat)?.id
    const outcome = super.handleRpc(sessionId, 0 as Method, {
      oneofKind: "readMessages",
      readMessages: { ...input.readMessages, ...(maxId != null ? { maxId } : {}) },
    })
    this.rpcLog.pop()
    if ("result" in outcome) this.changed(chat.id, true)
    if ("result" in outcome && outcome.result.oneofKind === "readMessages" && extra.length > 0) {
      return {
        result: {
          oneofKind: "readMessages",
          readMessages: { updates: [...outcome.result.readMessages.updates, ...extra] },
        },
      }
    }
    return outcome
  }

  private demoInvoke(
    input: Extract<RpcCall["input"], { oneofKind: "invokeMessageAction" }>["invokeMessageAction"],
  ): RpcOutcome {
    const chat = this.chatFor(inputPeerChatId(input.peerId))
    if (!chat) return fail(RpcError_Code.PEER_ID_INVALID, "peer")
    const message = this.storedMessage(chat.id, input.messageId)
    if (!message) return fail(RpcError_Code.MESSAGE_ID_INVALID, "message")
    const extras = extrasOf(message)
    const isForm = input.form != null
    const action = extras?.actions?.rows.flatMap((row) => row.actions).find((entry) => entry.actionId === input.actionId)
    const form = isForm ? closeForm(extras, input.actionId) : undefined
    if (isForm ? !form : action?.action.oneofKind !== "callback") return badRequest("no such action")
    const settings = this.actionSettings
    if (settings.failNext > 0 || (settings.failureRate > 0 && this.random.next() < settings.failureRate)) {
      if (settings.failNext > 0) settings.failNext -= 1
      return fail(RpcError_Code.INTERNAL_ERROR, "The bot did not answer")
    }
    const interactionId = this.nextInteraction++
    const text = isForm ? "Thanks, the release checklist is saved." : `${action?.text ?? "Done"}: recorded.`
    this.schedule(settings.answerDelayMs, () => {
      if (form) this.replaceExtras(chat.id, input.messageId, form)
      this.push(
        [
          Update.create({
            update: {
              oneofKind: "messageActionAnswered",
              messageActionAnswered: { interactionId, ui: { kind: { oneofKind: "toast", toast: { text } } } },
            },
          }),
        ],
        "hint",
      )
    })
    return { result: { oneofKind: "invokeMessageAction", invokeMessageAction: { interactionId } } }
  }

  private demoSearch(
    input: Extract<RpcCall["input"], { oneofKind: "searchMessages" }>["searchMessages"],
  ): RpcOutcome {
    const chat = this.chatFor(inputPeerChatId(input.peerId))
    if (!chat) return fail(RpcError_Code.PEER_ID_INVALID, "peer")
    const groups = input.queries
      .map((query) => query.toLowerCase().split(/\s+/).filter(Boolean))
      .filter((terms) => terms.length > 0)
    const filter = input.filter ?? SearchMessagesFilter.FILTER_UNSPECIFIED
    if (groups.length === 0 && filter === SearchMessagesFilter.FILTER_UNSPECIFIED) return badRequest("query")
    if (input.countOnly && groups.length === 0) return badRequest("query")
    const matches = (message: DemoModelMessage) => {
      if (groups.length > 0) {
        const text = message.text.toLowerCase()
        if (!groups.some((terms) => terms.every((term) => text.includes(term)))) return false
      }
      const kind = mediaKindOf(message.extras)
      switch (filter) {
        case SearchMessagesFilter.FILTER_PHOTOS:
          return kind === "photo"
        case SearchMessagesFilter.FILTER_VIDEOS:
          return kind === "video"
        case SearchMessagesFilter.FILTER_PHOTO_VIDEO:
          return kind === "photo" || kind === "video"
        case SearchMessagesFilter.FILTER_DOCUMENTS:
          return kind === "document"
        case SearchMessagesFilter.FILTER_VOICE_MEMOS:
          return kind === "voice"
        case SearchMessagesFilter.FILTER_LINKS:
          return hasLink(message)
        default:
          return true
      }
    }
    const limit = Math.min(100, Math.max(1, input.limit ?? 50))
    const found: DemoModelMessage[] = []
    let count = 0
    let before = input.countOnly ? undefined : input.offsetId
    const lazy = this.lazy(chat.id)
    const page = (cursor: bigint | undefined) =>
      lazy
        ? lazy.idsBefore(cursor, 500)
        : Array.from(chat.messages.keys())
            .filter((id) => cursor == null || id < cursor)
            .sort(ascending)
            .reverse()
            .slice(0, 500)
    while (true) {
      const ids = page(before)
      for (const id of ids) {
        const message = this.storedMessage(chat.id, id)
        if (!message || !matches(message)) continue
        count += 1
        if (!input.countOnly) {
          found.push(message)
          if (found.length >= limit) break
        }
      }
      if (ids.length < 500 || (!input.countOnly && found.length >= limit)) break
      before = ids[ids.length - 1]
    }
    const seq = BigInt(this.bucketSeq(`chat:${chat.id}`))
    return {
      result: {
        oneofKind: "searchMessages",
        searchMessages: input.countOnly
          ? { messages: [], seq, totalCount: count }
          : { messages: found.map((message) => this.encodeDemoMessage(message)), seq },
      },
    }
  }

  private transfer(input: RpcCall["input"]): RpcOutcome {
    const transfers = this.transfers
    switch (input.oneofKind) {
      case "createUpload":
        return { result: { oneofKind: "createUpload", createUpload: transfers.create(input.createUpload) } }
      case "saveUploadPart": {
        const { uploadId, partIndex, data } = input.saveUploadPart
        return { result: { oneofKind: "saveUploadPart", saveUploadPart: transfers.savePart(uploadId, partIndex, data) } }
      }
      case "getUploadState":
        return { result: { oneofKind: "getUploadState", getUploadState: transfers.state(input.getUploadState.uploadId) } }
      case "finishUpload":
        return { result: { oneofKind: "finishUpload", finishUpload: transfers.finish(input.finishUpload.uploadId) } }
      case "cancelUpload":
        return { result: { oneofKind: "cancelUpload", cancelUpload: transfers.cancel(input.cancelUpload.uploadId) } }
      case "getFilePart":
        return { result: { oneofKind: "getFilePart", getFilePart: transfers.getPart(input.getFilePart) } }
      default:
        return badRequest("transfer")
    }
  }

  private demoChats(): RpcOutcome {
    const chats = Array.from(this.chats.values())
    const messages = chats.flatMap((chat) => {
      const latest = this.latest(chat)
      return latest ? [this.encodeDemoMessage(latest)] : []
    })
    const userIds = [this.selfUserId, ...this.account.users.map((user) => user.id)]
    return {
      result: {
        oneofKind: "getChats",
        getChats: {
          dialogs: chats.map((chat) => this.encodeDemoDialog(chat)),
          chats: chats.map((chat) => this.encodeDemoChat(chat)),
          spaces: this.account.spaces.map((space, index) => this.encodeSpace(space, index)),
          users: userIds.flatMap((id) => this.encodeDemoUserOrEmpty(id)),
          messages,
          folders: [],
        },
      },
    }
  }

  private demoHistory(
    input: Extract<RpcCall["input"], { oneofKind: "getChatHistory" }>["getChatHistory"],
  ): RpcOutcome {
    const chat = this.chatFor(inputPeerChatId(input.peerId))
    if (!chat) return fail(RpcError_Code.PEER_ID_INVALID, "peer")
    const limit = Math.min(200, Math.max(1, input.limit ?? 60))
    const messages = chat.messages
    const lazy = messages instanceof DemoLazyMessages ? messages : undefined
    const before = (id: bigint | undefined, count: number) =>
      lazy
        ? lazy.idsBefore(id, count)
        : Array.from(messages.keys())
            .filter((candidate) => id == null || candidate < id)
            .sort(ascending)
            .reverse()
            .slice(0, count)
    const after = (id: bigint, count: number) =>
      lazy
        ? lazy.idsAfter(id, count)
        : Array.from(messages.keys())
            .filter((candidate) => candidate > id)
            .sort(ascending)
            .slice(0, count)

    let ids: bigint[]
    switch (input.mode ?? GetChatHistoryMode.HISTORY_MODE_LATEST) {
      case GetChatHistoryMode.HISTORY_MODE_UNSPECIFIED:
      case GetChatHistoryMode.HISTORY_MODE_LATEST:
        ids = input.offsetId != null ? before(input.offsetId, limit) : before(undefined, limit)
        break
      case GetChatHistoryMode.HISTORY_MODE_OLDER: {
        const beforeId = input.beforeId ?? input.offsetId
        ids = before(beforeId, limit)
        break
      }
      case GetChatHistoryMode.HISTORY_MODE_NEWER:
        if (input.afterId == null) return badRequest("afterId")
        ids = after(input.afterId, limit)
        break
      case GetChatHistoryMode.HISTORY_MODE_AROUND: {
        const anchor = input.anchorId
        if (anchor == null) return badRequest("anchorId")
        const withAnchor = input.includeAnchor !== false && messages.has(anchor)
        const beforeLimit = Math.max(0, input.beforeLimit ?? Math.floor(limit / 2))
        const afterLimit = Math.max(
          0,
          input.afterLimit ?? limit - Math.floor(limit / 2) - (withAnchor ? 1 : 0),
        )
        ids = [...before(anchor, beforeLimit), ...(withAnchor ? [anchor] : []), ...after(anchor, afterLimit)]
        break
      }
      default:
        return badRequest("mode")
    }
    const encoded = ids
      .sort(ascending)
      .reverse()
      .flatMap((id) => {
        const message = lazy ? lazy.peek(id) : messages.get(id)
        return message ? [this.encodeDemoMessage(message)] : []
      })
    return {
      result: {
        oneofKind: "getChatHistory",
        getChatHistory: { messages: encoded },
      },
    }
  }

  // ---- Persistence -----------------------------------------------------------

  /** Everything a reload must keep: chats that changed, the user bucket, settings. */
  persistedState(): DemoPersistedState {
    const chats: DemoPersistedChat[] = []
    for (const chatId of this.touched) {
      const chat = this.chats.get(chatId)
      const plan = this.plans.get(chatId)
      const messages = this.lazy(chatId)
      if (!chat || !plan || !messages) continue
      const modified = this.modified.get(chatId)
      const count = BigInt(plan.count)
      const dialog = this.dialogState.get(chatId)
      const pins = this.pins.get(chatId)
      const added = this.added.get(chatId)
      const removed = this.removed.get(chatId)
      chats.push({
        id: chatId.toString(),
        seq: this.bucketSeq(`chat:${chatId}`),
        nextId: chat.nextMessageId.toString(),
        readMaxId: (this.dialogs.get(chatId)?.readMaxId ?? 0n).toString(),
        messages: messages
          .stored()
          .filter((message) => message.id > count || modified?.has(message.id) === true)
          .map((message) => {
            const extras = extrasOf(message)
            return {
              id: message.id.toString(),
              fromId: message.fromId.toString(),
              text: message.text,
              date: Number(message.date),
              ...(message.editDate != null ? { editDate: Number(message.editDate) } : {}),
              ...(message.replyToMsgId != null ? { replyToMsgId: message.replyToMsgId.toString() } : {}),
              ...(message.randomId != null ? { randomId: message.randomId.toString() } : {}),
              ...(message.reactions.length > 0
                ? {
                    reactions: message.reactions.map((reaction) => ({
                      userId: reaction.userId.toString(),
                      emoji: reaction.emoji,
                      date: Number(reaction.date),
                    })),
                  }
                : {}),
              ...(extras ? { extras: extrasToJson(extras) } : {}),
            }
          }),
        deleted: messages.deletedSeeded().map((id) => id.toString()),
        ...(dialog ? { dialog } : {}),
        ...(pins && pins.length > 0 ? { pins: pins.map(String) } : {}),
        ...(added && added.size > 0
          ? { added: Array.from(added, ([userId, date]) => [userId.toString(), date] as [string, number]) }
          : {}),
        ...(removed && removed.size > 0 ? { removed: Array.from(removed, String) } : {}),
      })
    }
    return {
      version: 2,
      seed: this.account.seed,
      scale: this.account.scale,
      anchor: this.account.anchor,
      userSeq: this.bucketSeq("user"),
      chats,
      ...(this.settingsChanged ? { userSettings: UserSettings.toJson(this.userSettings) } : {}),
    }
  }

  /**
   * Start as a server whose past is unknown: a replica from an earlier
   * session may exist, but what that session did was not saved (first run,
   * or a lost or unreadable save). Every sequence and message ID moves past
   * anything such a session could have reached, so a replica that is ahead
   * repairs (the user bucket by `getChats`, a chat on its next event) instead
   * of dropping new events as duplicates. A fresh replica repairs anyway.
   */
  assumeUnknownPast(margin = unknownPastMargin(this.now())) {
    this.setBucketHead("user", 1 + margin, this.account.anchor)
    for (const plan of this.plans.values()) {
      const chat = this.chats.get(plan.id)
      if (!chat) continue
      chat.nextMessageId = BigInt(plan.count) + 1n + BigInt(margin)
      this.setBucketHead(`chat:${plan.id}`, plan.count + margin, plan.lastDate)
    }
  }

  /**
   * Restore a persisted state onto a freshly installed account. Chat
   * sequences and message IDs move past what was saved by
   * `DEMO_RESTORE_MARGIN`, so a replica that saw events after the last save
   * never sees a sequence or an ID again (it repairs the chat instead). The
   * user bucket resumes exactly, so a reload does not refetch the chat list.
   */
  restore(state: DemoPersistedState) {
    const now = this.now()
    if (state.userSeq > 0) this.setBucketHead("user", state.userSeq, now)
    if (state.userSettings != null) {
      try {
        this.userSettings = UserSettings.fromJson(state.userSettings as never)
        this.settingsChanged = true
      } catch {
        // Unreadable settings: keep the defaults.
      }
    }
    for (const saved of state.chats) {
      const chatId = BigInt(saved.id)
      const chat = this.chats.get(chatId)
      const plan = this.plans.get(chatId)
      if (!chat || !plan) continue
      for (const id of saved.deleted) chat.messages.delete(BigInt(id))
      const modified = new Set<bigint>()
      for (const message of saved.messages) {
        const id = BigInt(message.id)
        const seeded = id <= BigInt(plan.count) ? this.account.messageAt(plan, id) : undefined
        if (seeded) modified.add(id)
        const extras = message.extras != null ? extrasFromJson(message.extras) : seeded?.extras
        const restored: DemoModelMessage = {
          id,
          chatId,
          fromId: BigInt(message.fromId),
          text: message.text,
          date: BigInt(message.date),
          ...(message.editDate != null ? { editDate: BigInt(message.editDate) } : {}),
          ...(message.replyToMsgId != null ? { replyToMsgId: BigInt(message.replyToMsgId) } : {}),
          ...(message.randomId != null ? { randomId: BigInt(message.randomId) } : {}),
          reactions: message.reactions
            ? message.reactions.map((reaction) => ({
                userId: BigInt(reaction.userId),
                emoji: reaction.emoji,
                date: BigInt(reaction.date),
              }))
            : (seeded?.reactions ?? []),
          ...(extras ? { extras } : {}),
        }
        this.importMessage(restored)
      }
      if (modified.size > 0) this.modified.set(chatId, modified)
      this.setReadMaxId(chatId, BigInt(saved.readMaxId))
      if (saved.dialog) {
        this.dialogState.set(chatId, { ...saved.dialog })
        const dialog = this.dialogs.get(chatId)
        const mode = saved.dialog.notificationMode
        if (dialog && mode !== undefined) {
          if (mode == null) delete dialog.notificationMode
          else dialog.notificationMode = mode as DialogNotificationSettings_Mode
        }
      }
      if (saved.pins) this.pins.set(chatId, saved.pins.map((id) => BigInt(id)))
      if (saved.added) this.added.set(chatId, new Map(saved.added.map(([userId, date]) => [BigInt(userId), date])))
      if (saved.removed) this.removed.set(chatId, new Set(saved.removed.map((id) => BigInt(id))))
      const nextId = BigInt(saved.nextId) + BigInt(DEMO_RESTORE_MARGIN)
      if (nextId > chat.nextMessageId) chat.nextMessageId = nextId
      this.setBucketHead(`chat:${chatId}`, saved.seq + DEMO_RESTORE_MARGIN, now)
      this.touched.add(chatId)
      this.versions.set(chatId, (this.versions.get(chatId) ?? 0) + 1)
    }
  }
}

const unsequenced = (updates: Update[]): Update[] =>
  updates.map((update) => {
    const copy = { ...update }
    delete copy.seq
    delete copy.date
    return copy
  })

const hasLink = (message: DemoModelMessage) =>
  /https?:\/\//.test(message.text) ||
  (message.extras?.entities ?? []).some(
    (entity: MessageEntity) => entity.type === MessageEntity_Type.URL || entity.type === MessageEntity_Type.TEXT_URL,
  )

/** Merge a settings patch: each present section replaces its fields that are set. */
const mergeSettings = (current: UserSettings, patch: UserSettings): UserSettings => {
  const merge = <T extends object>(base: T | undefined, next: T | undefined): T | undefined =>
    next == null
      ? base
      : ({
          ...base,
          ...Object.fromEntries(Object.entries(next).filter(([, value]) => value !== undefined)),
        } as T)
  const notificationSettings = merge(current.notificationSettings, patch.notificationSettings)
  const privacySettings = patch.privacySettings ?? current.privacySettings
  const composeSettings = merge(current.composeSettings, patch.composeSettings)
  const messageGestureSettings = merge(current.messageGestureSettings, patch.messageGestureSettings)
  return {
    ...(notificationSettings ? { notificationSettings } : {}),
    ...(privacySettings ? { privacySettings } : {}),
    ...(composeSettings ? { composeSettings } : {}),
    ...(messageGestureSettings ? { messageGestureSettings } : {}),
  }
}

const isId = (value: unknown) => typeof value === "string" && /^\d+$/.test(value)

/** Validate a parsed persisted state; anything else (an older version, too) is ignored. */
export const isDemoPersistedState = (value: unknown): value is DemoPersistedState => {
  if (value == null || typeof value !== "object") return false
  const state = value as Partial<DemoPersistedState>
  return (
    state.version === 2 &&
    typeof state.seed === "number" &&
    typeof state.scale === "string" &&
    typeof state.anchor === "number" &&
    typeof state.userSeq === "number" &&
    Array.isArray(state.chats) &&
    state.chats.every(
      (chat) =>
        chat != null &&
        isId(chat.id) &&
        typeof chat.seq === "number" &&
        isId(chat.nextId) &&
        isId(chat.readMaxId) &&
        Array.isArray(chat.deleted) &&
        chat.deleted.every(isId) &&
        (chat.dialog == null || typeof chat.dialog === "object") &&
        (chat.pins == null || (Array.isArray(chat.pins) && chat.pins.every(isId))) &&
        (chat.added == null ||
          (Array.isArray(chat.added) &&
            chat.added.every((entry) => Array.isArray(entry) && isId(entry[0]) && typeof entry[1] === "number"))) &&
        (chat.removed == null || (Array.isArray(chat.removed) && chat.removed.every(isId))) &&
        Array.isArray(chat.messages) &&
        chat.messages.every(
          (message) =>
            message != null &&
            isId(message.id) &&
            isId(message.fromId) &&
            typeof message.text === "string" &&
            typeof message.date === "number" &&
            (message.replyToMsgId == null || isId(message.replyToMsgId)) &&
            (message.randomId == null || isId(message.randomId)) &&
            (message.reactions == null ||
              (Array.isArray(message.reactions) &&
                message.reactions.every(
                  (reaction) => isId(reaction.userId) && typeof reaction.emoji === "string" && typeof reaction.date === "number",
                ))),
        ),
    )
  )
}

/** Roles as the control channel names them. */
export const demoRoleName = (role: Member_Role) =>
  role === Member_Role.OWNER ? "owner" : role === Member_Role.ADMIN ? "admin" : "member"
