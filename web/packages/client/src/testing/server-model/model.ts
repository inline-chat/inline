import {
  type DialogNotificationSettings_Mode,
  GetChatHistoryMode,
  GetUpdatesResult_ResultType,
  Method,
  RpcError_Code,
  SyncSkippedSequence_Reason,
  Update,
  type GetUpdatesInput,
  type GetUpdatesResult,
  type RpcCall,
  type RpcResult,
  type SyncSkippedSequence,
  type UpdateSidecars,
} from "@inline-chat/protocol/core"
import {
  chatPeer,
  encodeChat,
  encodeDialog,
  encodeMessage,
  encodeUser,
  inputPeerChatId,
  latestMessage,
  type ModelChat,
  type ModelDialog,
  type ModelMessage,
  type ModelUser,
} from "./protocol"

/**
 * A small in-memory model of the Inline server for one account: users,
 * thread chats, the account's dialogs, messages, and the three kinds of sync
 * bucket (user, space, chat), each with its own sequence and journal.
 *
 * It answers the way `server/src/functions/updates.getUpdates.ts` and
 * `updates.getUpdatesState.ts` do:
 *
 * - pages hold at most `pageLimit` (100) records and account for every
 *   sequence they advance, as an update or a skipped sequence;
 * - a range wider than `replayLimit` (10,000), or a journal with a retention
 *   gap, answers `TOO_LONG` with the bucket's authoritative sequence;
 * - chat pages re-read the current message, so a deleted message replays as
 *   `chatSkipPts`, and non-empty pages carry sidecars with the chat and the
 *   dialog's current unread count;
 * - discovery pushes `chatHasNewUpdates` / `spaceHasNewUpdates` hints for
 *   buckets changed at or after the given date, before returning;
 * - `sendMessage` assigns IDs idempotently by random ID; a retry answers
 *   with `updateMessageId` only, as the server does;
 * - `readMessages` journals a user-bucket `updateReadMaxId` with the unread
 *   count at that moment and answers without a sequence;
 * - reactions are realtime only (the server does not journal them).
 *
 * The model is the oracle: `chatState()` is the authoritative chat.
 */

export type BucketId = "user" | `chat:${bigint}` | `space:${bigint}`

type JournalEntry = {
  seq: number
  date: number
  build: () => Update | SyncSkippedSequence_Reason
}

type Bucket = {
  id: BucketId
  seq: number
  date: number
  entries: JournalEntry[]
  /** The first sequence still retained; older entries were pruned. */
  retainedFrom: number
}

export type ModelPush = {
  updates: Update[]
  /** What the push carries, for fault bookkeeping. */
  kind: "durable" | "reaction" | "read" | "hint"
  /** Messages whose reaction state the push changes. */
  reactionTargets?: Array<{ chatId: bigint; messageId: bigint }>
}

export type ModelSession = {
  readonly id: number
  close(): void
}

type SessionSink = (push: ModelPush) => void

export type RpcOutcome =
  | { result: RpcResult["result"] }
  | { error: { code: RpcError_Code; message: string } }

export type ServerModelOptions = {
  selfUserId?: bigint
  /** Server time in whole seconds. */
  now: () => number
  pageLimit?: number
  replayLimit?: number
}

export type AuthoritativeChat = {
  chatId: bigint
  messages: Array<{
    id: bigint
    fromId: bigint
    text: string
    reactions: Array<{ userId: bigint; emoji: string }>
    randomId?: bigint
  }>
  lastMsgId?: bigint
  readMaxId: bigint
  unreadCount: number
  seq: number
}

const PAGE_LIMIT = 100
const REPLAY_LIMIT = 10_000

const rpcError = (code: RpcError_Code, message: string): RpcOutcome => ({
  error: { code, message },
})

export class ServerModel {
  readonly selfUserId: bigint
  readonly users = new Map<bigint, ModelUser>()
  readonly chats = new Map<bigint, ModelChat>()
  readonly dialogs = new Map<bigint, ModelDialog>()
  readonly spaces = new Map<bigint, { id: bigint; name: string; members: bigint[] }>()
  readonly now: () => number
  pageLimit: number
  replayLimit: number

  /** Every RPC the model answered, for assertions. */
  readonly rpcLog: Array<{ session: number; method: Method; ok: boolean }> = []

  private readonly buckets = new Map<BucketId, Bucket>()
  private readonly sessions = new Map<number, SessionSink>()
  private readonly sentByRandomId = new Map<bigint, ModelMessage>()
  private readonly unreadStaleChats = new Set<bigint>()
  /** Chats served a page whose dialog sidecar counted records past the page. */
  readonly sidecarsAheadOfPage = new Set<bigint>()
  /** Chats for which a user-bucket page replayed an outdated read state. */
  readonly staleReadsServed = new Set<bigint>()
  /** Every read state the user bucket journaled, per chat, oldest first. */
  readonly readHistory = new Map<bigint, Array<{ readMaxId: bigint; unreadCount: number }>>()
  /**
   * Every membership event each space bucket journaled, in sequence order:
   * the member ID of an add, or `undefined` for a removal.
   */
  private readonly memberEvents = new Map<
    bigint,
    Array<{ seq: number; userId: bigint; memberId?: bigint }>
  >()
  private readonly memberIds = new Map<string, bigint>()
  private nextSessionId = 1
  private nextSpaceMemberId = 1n
  private nextReservedChatId = 900_000n

  constructor(options: ServerModelOptions) {
    this.selfUserId = options.selfUserId ?? 1n
    this.now = options.now
    this.pageLimit = options.pageLimit ?? PAGE_LIMIT
    this.replayLimit = options.replayLimit ?? REPLAY_LIMIT
    this.users.set(this.selfUserId, { id: this.selfUserId, firstName: "Self" })
    this.bucket("user")
  }

  // ---- Setup --------------------------------------------------------------

  addUser(id: bigint, firstName = `User ${id}`) {
    const user = { id, firstName }
    this.users.set(id, user)
    return user
  }

  addSpace(id: bigint, name = `Space ${id}`) {
    const space = { id, name, members: [this.selfUserId] }
    this.spaces.set(id, space)
    this.bucket(`space:${id}`)
    return space
  }

  /** A thread chat the model's user belongs to, with its dialog. */
  addChat(options: {
    id: bigint
    title?: string
    spaceId?: bigint
    participants?: bigint[]
  }) {
    const participants = Array.from(
      new Set([this.selfUserId, ...(options.participants ?? [])]),
    )
    const chat: ModelChat = {
      id: options.id,
      title: options.title ?? `Chat ${options.id}`,
      ...(options.spaceId != null ? { spaceId: options.spaceId } : {}),
      participants,
      nextMessageId: 1n,
      messages: new Map(),
    }
    this.chats.set(chat.id, chat)
    this.dialogs.set(chat.id, { chatId: chat.id, readMaxId: 0n })
    this.bucket(`chat:${chat.id}`)
    return chat
  }

  /**
   * Bulk-load an existing message (seeded history). Nothing is journaled;
   * pair it with `setBucketHead` so the bucket's sequence covers the import.
   */
  importMessage(message: ModelMessage) {
    const chat = this.requireChat(message.chatId)
    chat.messages.set(message.id, message)
    if (message.id >= chat.nextMessageId) chat.nextMessageId = message.id + 1n
    if (message.randomId != null) this.sentByRandomId.set(message.randomId, message)
  }

  setReadMaxId(chatId: bigint, readMaxId: bigint) {
    this.requireDialog(chatId).readMaxId = readMaxId
  }

  /**
   * Set a bucket's sequence as if `seq` records had been journaled and then
   * pruned by retention: replaying from below it answers `TOO_LONG`.
   */
  setBucketHead(bucketId: BucketId, seq: number, date: number) {
    const bucket = this.bucket(bucketId)
    bucket.seq = seq
    bucket.date = date
    bucket.entries = []
    bucket.retainedFrom = seq + 1
  }

  // ---- Sessions -----------------------------------------------------------

  /** Register a connected session that receives live pushes. */
  connect(sink: SessionSink): ModelSession {
    const id = this.nextSessionId++
    this.sessions.set(id, sink)
    return {
      id,
      close: () => {
        this.sessions.delete(id)
      },
    }
  }

  // ---- Server-side events ---------------------------------------------------

  /** Another user (or, with `fromId: selfUserId`, another device) posts. */
  postMessage(options: {
    chatId: bigint
    fromId: bigint
    text: string
    replyToMsgId?: bigint
    media?: ModelMessage["media"]
    hasLink?: boolean
  }): ModelMessage {
    const chat = this.requireChat(options.chatId)
    const date = BigInt(this.now())
    const message: ModelMessage = {
      id: chat.nextMessageId++,
      chatId: chat.id,
      fromId: options.fromId,
      text: options.text,
      date,
      ...(options.replyToMsgId != null ? { replyToMsgId: options.replyToMsgId } : {}),
      reactions: [],
      ...(options.media ? { media: options.media } : {}),
      ...(options.hasLink ? { hasLink: true } : {}),
    }
    chat.messages.set(message.id, message)
    const live = this.journalChat(chat.id, (seq, journalDate) =>
      this.newMessageUpdate(chat.id, message.id, seq, journalDate),
    )
    this.broadcast({ updates: [live], kind: "durable" })
    return message
  }

  editMessage(chatId: bigint, messageId: bigint, text: string) {
    const message = this.requireMessage(chatId, messageId)
    message.text = text
    message.editDate = BigInt(this.now())
    const live = this.journalChat(chatId, (seq, date) =>
      this.messageUpdate("editMessage", chatId, messageId, seq, date),
    )
    this.broadcast({ updates: [live], kind: "durable" })
  }

  deleteMessages(chatId: bigint, messageIds: bigint[]) {
    const chat = this.requireChat(chatId)
    const dialog = this.requireDialog(chatId)
    for (const id of messageIds) {
      const message = chat.messages.get(id)
      // The server does not tell the client its unread count dropped.
      if (message && message.fromId !== this.selfUserId && id > dialog.readMaxId) {
        this.unreadStaleChats.add(chatId)
      }
      chat.messages.delete(id)
    }
    const ids = messageIds.slice()
    const live = this.journalChat(chatId, (seq, date) =>
      Update.create({
        seq,
        date: BigInt(date),
        update: {
          oneofKind: "deleteMessages",
          deleteMessages: { messageIds: ids, peerId: chatPeer(chatId) },
        },
      }),
    )
    this.broadcast({ updates: [live], kind: "durable" })
  }

  addReaction(chatId: bigint, messageId: bigint, userId: bigint, emoji: string) {
    const message = this.requireMessage(chatId, messageId)
    const date = BigInt(this.now())
    message.reactions = [
      ...message.reactions.filter(
        (reaction) => reaction.userId !== userId || reaction.emoji !== emoji,
      ),
      { userId, emoji, date },
    ]
    this.broadcast({
      kind: "reaction",
      reactionTargets: [{ chatId, messageId }],
      updates: [
        Update.create({
          update: {
            oneofKind: "updateReaction",
            updateReaction: {
              reaction: { emoji, userId, messageId, chatId, date },
            },
          },
        }),
      ],
    })
  }

  removeReaction(chatId: bigint, messageId: bigint, userId: bigint, emoji: string) {
    const message = this.requireMessage(chatId, messageId)
    message.reactions = message.reactions.filter(
      (reaction) => reaction.userId !== userId || reaction.emoji !== emoji,
    )
    this.broadcast({
      kind: "reaction",
      reactionTargets: [{ chatId, messageId }],
      updates: [
        Update.create({
          update: {
            oneofKind: "deleteReaction",
            deleteReaction: { emoji, chatId, messageId, userId },
          },
        }),
      ],
    })
  }

  /** The account's other device reads a chat up to `maxId`. */
  readOnOtherDevice(chatId: bigint, maxId: bigint) {
    const live = this.applyRead(chatId, maxId)
    if (live) this.broadcast({ updates: [live], kind: "read" })
  }

  /**
   * Another user joins a space: a space-bucket `spaceMemberAdd` with a new
   * membership generation (the server's immutable member ID).
   */
  addSpaceMember(spaceId: bigint, userId: bigint) {
    const space = this.spaces.get(spaceId)
    if (!space) throw new Error(`No space ${spaceId}`)
    if (!space.members.includes(userId)) space.members.push(userId)
    const user = this.users.get(userId) ?? this.addUser(userId)
    const memberId = this.nextSpaceMemberId++
    this.memberIds.set(`${spaceId}:${userId}`, memberId)
    const live = this.journal(`space:${spaceId}`, (seq, date) => {
      this.noteMemberEvent(spaceId, { seq, userId, memberId })
      return Update.create({
        seq,
        date: BigInt(date),
        update: {
          oneofKind: "spaceMemberAdd",
          spaceMemberAdd: {
            member: {
              id: memberId,
              spaceId,
              userId,
              date: BigInt(date),
              canAccessPublicChats: true,
            },
            user: encodeUser(user),
          },
        },
      })
    })
    this.broadcast({ updates: [live], kind: "durable" })
  }

  /**
   * Another user leaves a space: a space-bucket `spaceMemberDelete` naming
   * the membership generation it ends. Returns false when the user is not a
   * member (or is the model's own user, whose removal is not modeled).
   */
  removeSpaceMember(spaceId: bigint, userId: bigint) {
    const space = this.spaces.get(spaceId)
    if (!space) throw new Error(`No space ${spaceId}`)
    const memberId = this.memberIds.get(`${spaceId}:${userId}`)
    if (userId === this.selfUserId || memberId == null) return false
    space.members = space.members.filter((member) => member !== userId)
    this.memberIds.delete(`${spaceId}:${userId}`)
    const live = this.journal(`space:${spaceId}`, (seq, date) => {
      this.noteMemberEvent(spaceId, { seq, userId })
      return Update.create({
        seq,
        date: BigInt(date),
        update: {
          oneofKind: "spaceMemberDelete",
          spaceMemberDelete: { spaceId, userId, memberId },
        },
      })
    })
    this.broadcast({ updates: [live], kind: "durable" })
    return true
  }

  /** Users with a membership generation in the space now (self excluded). */
  spaceMemberUserIds(spaceId: bigint): bigint[] {
    return Array.from(this.memberIds.keys())
      .filter((key) => key.startsWith(`${spaceId}:`))
      .map((key) => BigInt(key.slice(`${spaceId}:`.length)))
  }

  /**
   * The roster the space bucket's events build through `seq`: user ID to
   * member ID. This is what a replica whose space cursor is at `seq` holds.
   */
  spaceMembersThrough(spaceId: bigint, seq: number): Map<bigint, bigint> {
    const members = new Map<bigint, bigint>()
    for (const event of this.memberEvents.get(spaceId) ?? []) {
      if (event.seq > seq) break
      if (event.memberId == null) members.delete(event.userId)
      else members.set(event.userId, event.memberId)
    }
    return members
  }

  /**
   * The account changes a chat's notification mode on another device: a
   * user-bucket `dialogNotificationSettings`. `undefined` resets it to the
   * global settings.
   */
  setNotificationMode(
    chatId: bigint,
    mode: DialogNotificationSettings_Mode | undefined,
  ) {
    const dialog = this.requireDialog(chatId)
    if (mode == null) delete dialog.notificationMode
    else dialog.notificationMode = mode
    const live = this.journal("user", (seq, date) =>
      Update.create({
        seq,
        date: BigInt(date),
        update: {
          oneofKind: "dialogNotificationSettings",
          dialogNotificationSettings: {
            peerId: chatPeer(chatId),
            ...(mode != null ? { notificationSettings: { mode } } : {}),
          },
        },
      }),
    )
    this.broadcast({ updates: [live], kind: "durable" })
  }

  /**
   * A user-bucket record of a kind the web client has no model for
   * (`agentSettings`): the client must store it raw (invariant 7).
   */
  addRawRecord() {
    const live = this.journal("user", (seq, date) =>
      Update.create({
        seq,
        date: BigInt(date),
        update: { oneofKind: "agentSettings", agentSettings: {} },
      }),
    )
    this.broadcast({ updates: [live], kind: "durable" })
  }

  private noteMemberEvent(
    spaceId: bigint,
    event: { seq: number; userId: bigint; memberId?: bigint },
  ) {
    const events = this.memberEvents.get(spaceId) ?? []
    if (events.some((existing) => existing.seq === event.seq)) return
    events.push(event)
    events.sort((left, right) => left.seq - right.seq)
    this.memberEvents.set(spaceId, events)
  }

  /**
   * A durable record the account's sessions must account for but that has
   * no projection (the server answers it as `IRRELEVANT_TO_BUCKET`).
   */
  addIrrelevantRecord(bucket: "user" | `space:${bigint}`) {
    this.journal(bucket, () => SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET)
  }

  /** Prune journal entries up to `throughSeq`, as retention does. */
  pruneJournal(bucketId: BucketId, throughSeq: number) {
    const bucket = this.bucket(bucketId)
    bucket.retainedFrom = Math.max(bucket.retainedFrom, throughSeq + 1)
    bucket.entries = bucket.entries.filter((entry) => entry.seq > throughSeq)
  }

  // ---- Oracle ---------------------------------------------------------------

  bucketSeq(bucketId: BucketId): number {
    return this.bucket(bucketId).seq
  }

  bucketIds(): BucketId[] {
    return Array.from(this.buckets.keys())
  }

  /** Sequence and kind of each retained journal record, as served now. */
  journalKinds(bucketId: BucketId): Array<{ seq: number; kind: string }> {
    return this.bucket(bucketId).entries.map((entry) => {
      const built = entry.build()
      return {
        seq: entry.seq,
        kind: typeof built === "number" ? "skipped" : (built.update.oneofKind ?? "unknown"),
      }
    })
  }

  unreadCount(chatId: bigint): number {
    const chat = this.requireChat(chatId)
    const dialog = this.requireDialog(chatId)
    let count = 0
    for (const message of chat.messages.values()) {
      if (message.fromId !== this.selfUserId && message.id > dialog.readMaxId) count += 1
    }
    return count
  }

  /**
   * True when the unread count changed in a way the server never tells the
   * client (a deleted unread message), and nothing authoritative about it
   * has been served since.
   */
  isUnreadStale(chatId: bigint) {
    return this.unreadStaleChats.has(chatId)
  }

  chatState(chatId: bigint): AuthoritativeChat {
    const chat = this.requireChat(chatId)
    const messages = Array.from(chat.messages.values())
      .sort((left, right) => (left.id < right.id ? -1 : 1))
      .map((message) => ({
        id: message.id,
        fromId: message.fromId,
        text: message.text,
        reactions: message.reactions
          .map(({ userId, emoji }) => ({ userId, emoji }))
          .sort(compareReactions),
        ...(message.randomId != null ? { randomId: message.randomId } : {}),
      }))
    const latest = latestMessage(chat)
    return {
      chatId,
      messages,
      ...(latest ? { lastMsgId: latest.id } : {}),
      readMaxId: this.requireDialog(chatId).readMaxId,
      unreadCount: this.unreadCount(chatId),
      seq: this.bucketSeq(`chat:${chatId}`),
    }
  }

  /** Messages the model's user sent with this random ID (0 or 1). */
  messagesWithRandomId(randomId: bigint): ModelMessage[] {
    const message = this.sentByRandomId.get(randomId)
    return message && this.chats.get(message.chatId)?.messages.has(message.id)
      ? [message]
      : []
  }

  // ---- RPC ------------------------------------------------------------------

  /**
   * Answer one RPC for `sessionId`. Hints that a real server pushes before
   * the result (discovery) are pushed to the session before this returns.
   */
  handleRpc(sessionId: number, method: Method, input: RpcCall["input"]): RpcOutcome {
    const outcome = this.dispatch(sessionId, method, input)
    this.rpcLog.push({ session: sessionId, method, ok: "result" in outcome })
    return outcome
  }

  private dispatch(sessionId: number, method: Method, input: RpcCall["input"]): RpcOutcome {
    switch (input.oneofKind) {
      case "getMe":
        return {
          result: { oneofKind: "getMe", getMe: { user: encodeUser(this.self()) } },
        }
      case "getUpdatesState":
        return this.getUpdatesState(sessionId, input.getUpdatesState.date)
      case "getUpdates":
        return this.getUpdates(input.getUpdates)
      case "sendMessage": {
        const chatId = inputPeerChatId(input.sendMessage.peerId)
        if (chatId == null || !this.chats.has(chatId)) {
          return rpcError(RpcError_Code.PEER_ID_INVALID, "peer")
        }
        return this.sendMessage(sessionId, chatId, input.sendMessage)
      }
      case "readMessages": {
        const chatId = inputPeerChatId(input.readMessages.peerId)
        if (chatId == null || !this.chats.has(chatId)) {
          return rpcError(RpcError_Code.PEER_ID_INVALID, "peer")
        }
        const maxId = input.readMessages.maxId
        const live =
          maxId == null ? undefined : this.applyRead(chatId, maxId)
        if (live) {
          this.broadcast({ updates: [live], kind: "read" }, sessionId)
        }
        return {
          result: {
            oneofKind: "readMessages",
            readMessages: { updates: live ? [live] : [] },
          },
        }
      }
      case "getChat": {
        const chatId = inputPeerChatId(input.getChat.peerId)
        const chat = chatId == null ? undefined : this.chats.get(chatId)
        if (!chat) return rpcError(RpcError_Code.PEER_ID_INVALID, "peer")
        this.unreadStaleChats.delete(chat.id)
        return {
          result: {
            oneofKind: "getChat",
            getChat: {
              chat: this.encodeChat(chat),
              dialog: encodeDialog(chat, this.requireDialog(chat.id), this.unreadCount(chat.id)),
              pinnedMessageIds: [],
              messages: [],
            },
          },
        }
      }
      case "getChatHistory": {
        const chatId = inputPeerChatId(input.getChatHistory.peerId)
        const chat = chatId == null ? undefined : this.chats.get(chatId)
        if (!chat) return rpcError(RpcError_Code.PEER_ID_INVALID, "peer")
        // Newest first, as `messages.getChatHistory.ts` answers every mode.
        const history = input.getChatHistory
        const limit = Math.max(1, history.limit ?? 50)
        const newestFirst = Array.from(chat.messages.values()).sort((left, right) =>
          left.id > right.id ? -1 : 1,
        )
        let page: ModelMessage[]
        switch (history.mode) {
          case GetChatHistoryMode.HISTORY_MODE_LATEST:
            page = newestFirst.slice(0, limit)
            break
          case GetChatHistoryMode.HISTORY_MODE_OLDER: {
            const before = history.beforeId
            if (before == null) return rpcError(RpcError_Code.BAD_REQUEST, "older needs beforeId")
            page = newestFirst.filter((message) => message.id < before).slice(0, limit)
            break
          }
          case GetChatHistoryMode.HISTORY_MODE_NEWER: {
            const after = history.afterId
            if (after == null) return rpcError(RpcError_Code.BAD_REQUEST, "newer needs afterId")
            page = newestFirst
              .filter((message) => message.id > after)
              .slice(-limit)
            break
          }
          case GetChatHistoryMode.HISTORY_MODE_AROUND: {
            const anchor = history.anchorId
            if (anchor == null) return rpcError(RpcError_Code.BAD_REQUEST, "around needs anchorId")
            const newer = newestFirst
              .filter((message) => message.id > anchor)
              .slice(-(history.afterLimit ?? 25))
            const older = newestFirst
              .filter((message) => message.id < anchor)
              .slice(0, history.beforeLimit ?? 25)
            const self = (history.includeAnchor ?? true)
              ? newestFirst.filter((message) => message.id === anchor)
              : []
            page = [...newer, ...self, ...older]
            break
          }
          default:
            return rpcError(RpcError_Code.BAD_REQUEST, "unknown history mode")
        }
        const messages = page.map((message) => encodeMessage(message, this.selfUserId))
        return {
          result: {
            oneofKind: "getChatHistory",
            getChatHistory: { messages },
          },
        }
      }
      case "reserveChatIds": {
        const count = Math.max(0, Math.min(input.reserveChatIds.count, 20))
        const expiresAt = BigInt(this.now() + 24 * 60 * 60)
        return {
          result: {
            oneofKind: "reserveChatIds",
            reserveChatIds: {
              reservations: Array.from({ length: count }, () => ({
                chatId: this.nextReservedChatId++,
                expiresAt,
              })),
            },
          },
        }
      }
      case "getChats": {
        const chats = Array.from(this.chats.values())
        return {
          result: {
            oneofKind: "getChats",
            getChats: {
              dialogs: chats.map((chat) =>
                encodeDialog(chat, this.requireDialog(chat.id), this.unreadCount(chat.id)),
              ),
              chats: chats.map((chat) => this.encodeChat(chat)),
              spaces: [],
              users: Array.from(this.users.values()).map(encodeUser),
              messages: chats.flatMap((chat) => {
                const latest = latestMessage(chat)
                return latest ? [encodeMessage(latest, this.selfUserId)] : []
              }),
              folders: [],
            },
          },
        }
      }
      case "getChatParticipants": {
        const chat = this.chats.get(input.getChatParticipants.chatId)
        if (!chat) return rpcError(RpcError_Code.BAD_REQUEST, "chat not found")
        return {
          result: {
            oneofKind: "getChatParticipants",
            getChatParticipants: {
              participants: chat.participants.map((userId) => ({ userId, date: 1n })),
              users: chat.participants.flatMap((userId) => {
                const user = this.users.get(userId)
                return user ? [encodeUser(user)] : []
              }),
              groupParticipants: [],
              groups: [],
            },
          },
        }
      }
      case "addChatParticipant":
        return this.addChatParticipant(input.addChatParticipant)
      case "removeChatParticipant":
        return this.removeChatParticipant(input.removeChatParticipant)
      case "searchMessages":
        return this.searchMessages(input.searchMessages)
      case "searchUsers": {
        const query = input.searchUsers.query.trim().replace(/^@/, "").toLowerCase()
        if (query.length < 2) return { result: { oneofKind: "searchUsers", searchUsers: { users: [] } } }
        const users = Array.from(this.users.values())
          .filter((user) => user.id !== this.selfUserId && user.firstName.toLowerCase().includes(query))
          .slice(0, Math.min(Math.max(input.searchUsers.limit ?? 20, 1), 20))
          .map(encodeUser)
        return { result: { oneofKind: "searchUsers", searchUsers: { users } } }
      }
      default:
        return rpcError(
          RpcError_Code.BAD_REQUEST,
          `The server model does not answer ${Method[method] ?? method}`,
        )
    }
  }

  /**
   * `ADD_CHAT_PARTICIPANT` for a user, as the server answers it: idempotent
   * (an existing participant is answered as it is). Groups are not modelled.
   * Not journaled: the model's chat buckets carry messages only.
   */
  private addChatParticipant(input: { chatId: bigint; userId?: bigint; groupId?: bigint }): RpcOutcome {
    const chat = this.chats.get(input.chatId)
    if (!chat) return rpcError(RpcError_Code.BAD_REQUEST, "chat not found")
    if (input.userId == null) return rpcError(RpcError_Code.BAD_REQUEST, "the model adds users only")
    const user = this.users.get(input.userId)
    if (!user) return rpcError(RpcError_Code.BAD_REQUEST, "user not found")
    if (!chat.participants.includes(input.userId)) chat.participants.push(input.userId)
    return {
      result: {
        oneofKind: "addChatParticipant",
        addChatParticipant: {
          participant: { userId: input.userId, date: BigInt(this.now()) },
          users: [encodeUser(user)],
        },
      },
    }
  }

  /** `REMOVE_CHAT_PARTICIPANT`: refused for someone who is not a participant, as the server does. */
  private removeChatParticipant(input: { chatId: bigint; userId?: bigint; groupId?: bigint }): RpcOutcome {
    const chat = this.chats.get(input.chatId)
    if (!chat) return rpcError(RpcError_Code.BAD_REQUEST, "chat not found")
    if (input.userId == null || !chat.participants.includes(input.userId)) {
      return rpcError(RpcError_Code.BAD_REQUEST, "User is not a participant of this chat")
    }
    chat.participants = chat.participants.filter((id) => id !== input.userId)
    return { result: { oneofKind: "removeChatParticipant", removeChatParticipant: {} } }
  }

  /**
   * `SEARCH_MESSAGES` in one chat: newest first, older than `offsetId`, words
   * of a query ANDed (case-insensitive substrings), queries ORed, the media
   * filter on `ModelMessage.media` and `hasLink`; `countOnly` counts.
   */
  private searchMessages(input: {
    peerId?: Parameters<typeof inputPeerChatId>[0]
    queries: string[]
    limit?: number
    offsetId?: bigint
    filter?: number
    countOnly?: boolean
  }): RpcOutcome {
    const chatId = inputPeerChatId(input.peerId)
    const chat = chatId == null ? undefined : this.chats.get(chatId)
    if (!chat) return rpcError(RpcError_Code.PEER_ID_INVALID, "peer")
    const queries = input.queries.map((query) => query.toLowerCase().split(/\s+/).filter(Boolean)).filter((words) => words.length > 0)
    const kind = (message: ModelMessage) => message.media?.media.oneofKind
    const filtered = (message: ModelMessage) => {
      switch (input.filter ?? 0) {
        case 1:
          return kind(message) === "photo"
        case 2:
          return kind(message) === "video"
        case 3:
          return kind(message) === "photo" || kind(message) === "video"
        case 4:
          return kind(message) === "document"
        case 5:
          return message.hasLink === true
        case 6:
          return kind(message) === "voice"
        default:
          return true
      }
    }
    const matches = (message: ModelMessage) =>
      filtered(message) &&
      (queries.length === 0 ||
        queries.some((words) => words.every((word) => message.text.toLowerCase().includes(word))))
    const all = Array.from(chat.messages.values())
      .filter(matches)
      .sort((left, right) => (left.id > right.id ? -1 : 1))
    if (input.countOnly) {
      return { result: { oneofKind: "searchMessages", searchMessages: { messages: [], totalCount: all.length } } }
    }
    const limit = Math.min(Math.max(input.limit ?? 50, 1), 100)
    const messages = all
      .filter((message) => input.offsetId == null || message.id < input.offsetId)
      .slice(0, limit)
      .map((message) => encodeMessage(message, this.selfUserId))
    return { result: { oneofKind: "searchMessages", searchMessages: { messages } } }
  }

  private getUpdatesState(sessionId: number, date: bigint | undefined): RpcOutcome {
    const now = this.now()
    const userSeq = this.bucketSeq("user")
    const checkpoint = { date: BigInt(now), updatesFound: false, seq: userSeq }
    if (date == null || date === 0n || date > BigInt(now)) {
      return { result: { oneofKind: "getUpdatesState", getUpdatesState: checkpoint } }
    }
    const since = Number(date)
    const hints: Update[] = []
    for (const chat of this.chats.values()) {
      const bucket = this.bucket(`chat:${chat.id}`)
      if (bucket.seq === 0 || bucket.date < since) continue
      hints.push(
        Update.create({
          update: {
            oneofKind: "chatHasNewUpdates",
            chatHasNewUpdates: {
              chatId: chat.id,
              updateSeq: bucket.seq,
              peerId: chatPeer(chat.id),
            },
          },
        }),
      )
    }
    for (const space of this.spaces.values()) {
      const bucket = this.bucket(`space:${space.id}`)
      if (bucket.seq === 0 || bucket.date < since) continue
      hints.push(
        Update.create({
          update: {
            oneofKind: "spaceHasNewUpdates",
            spaceHasNewUpdates: { spaceId: space.id, updateSeq: bucket.seq },
          },
        }),
      )
    }
    if (hints.length > 0) {
      this.sessions.get(sessionId)?.({ updates: hints, kind: "hint" })
    }
    return {
      result: {
        oneofKind: "getUpdatesState",
        getUpdatesState: { ...checkpoint, updatesFound: hints.length > 0 },
      },
    }
  }

  private getUpdates(input: GetUpdatesInput): RpcOutcome {
    const bucketId = this.resolveBucket(input)
    if (!bucketId) return rpcError(RpcError_Code.PEER_ID_INVALID, "bucket")
    const bucket = this.bucket(bucketId)
    const start = Number(input.startSeq ?? 0n)
    const seqEnd = input.seqEnd && input.seqEnd > 0n ? Number(input.seqEnd) : undefined
    if (start < 0 || (seqEnd != null && seqEnd < start)) {
      return rpcError(RpcError_Code.BAD_REQUEST, "range")
    }
    const pageLimit = Math.min(
      input.limit && input.limit > 0 ? input.limit : this.pageLimit,
      this.pageLimit,
    )
    const bounded = seqEnd == null ? bucket.seq : Math.min(bucket.seq, seqEnd)
    const latestSeq = Math.max(bounded, start)
    const latestDate =
      bucket.entries.find((entry) => entry.seq === latestSeq)?.date ?? bucket.date

    if (latestSeq - start > this.replayLimit) {
      return this.tooLong(latestSeq, latestDate)
    }
    const entries = bucket.entries
      .filter((entry) => entry.seq > start && entry.seq <= bounded)
      .slice(0, pageLimit)
    const hasGap =
      entries.some((entry, index) => entry.seq !== start + index + 1) ||
      (entries.length < pageLimit && start + entries.length < latestSeq)
    if (hasGap) return this.tooLong(latestSeq, latestDate)

    const updates: Update[] = []
    const skippedSequences: SyncSkippedSequence[] = []
    for (const entry of entries) {
      const built = entry.build()
      if (typeof built === "number") {
        skippedSequences.push({ seq: BigInt(entry.seq), reason: built })
      } else {
        updates.push(built)
        this.noteStaleRead(built)
      }
    }
    const last = entries[entries.length - 1]
    const pageSeq = last?.seq ?? start
    const result: GetUpdatesResult = {
      updates,
      seq: BigInt(pageSeq),
      date: BigInt(last?.date ?? 0),
      final: latestSeq <= pageSeq,
      resultType:
        updates.length === 0
          ? GetUpdatesResult_ResultType.EMPTY
          : GetUpdatesResult_ResultType.SLICE,
      skippedSequences,
    }
    const sidecars = updates.length > 0 ? this.sidecars(bucketId, updates) : undefined
    if (sidecars) result.sidecars = sidecars
    if (sidecars && bucketId.startsWith("chat:") && pageSeq < bucket.seq) {
      // The dialog sidecar counts unread messages journaled after this
      // page's end. A client that also counts their live pushes counts
      // them twice (KB-2).
      this.sidecarsAheadOfPage.add(BigInt(bucketId.slice("chat:".length)))
    }
    return { result: { oneofKind: "getUpdates", getUpdates: result } }
  }

  /** The server encodes a chat with its bucket's current sequence (`encodeChat.ts`). */
  private encodeChat(chat: ModelChat) {
    return { ...encodeChat(chat), seq: this.bucket(`chat:${chat.id}`).seq }
  }

  private tooLong(seq: number, date: number): RpcOutcome {
    return {
      result: {
        oneofKind: "getUpdates",
        getUpdates: {
          updates: [],
          seq: BigInt(seq),
          date: BigInt(date),
          final: false,
          resultType: GetUpdatesResult_ResultType.TOO_LONG,
          skippedSequences: [],
        },
      },
    }
  }

  private sidecars(bucketId: BucketId, updates: Update[]): UpdateSidecars | undefined {
    const chatIds = new Set<bigint>()
    const userIds = new Set<bigint>()
    if (bucketId.startsWith("chat:")) {
      chatIds.add(BigInt(bucketId.slice("chat:".length)))
      for (const update of updates) {
        if (update.update.oneofKind === "newMessage" || update.update.oneofKind === "editMessage") {
          const message =
            update.update.oneofKind === "newMessage"
              ? update.update.newMessage.message
              : update.update.editMessage.message
          if (message) userIds.add(message.fromId)
        }
      }
    } else if (bucketId === "user") {
      for (const update of updates) {
        if (update.update.oneofKind === "updateReadMaxId") {
          const chatId = update.update.updateReadMaxId.peerId?.type
          if (chatId?.oneofKind === "chat") chatIds.add(chatId.chat.chatId)
        }
      }
    } else {
      return undefined
    }
    const chats = Array.from(chatIds)
      .map((id) => this.chats.get(id))
      .filter((chat): chat is ModelChat => chat != null)
    for (const chat of chats) this.unreadStaleChats.delete(chat.id)
    return {
      users: Array.from(userIds)
        .map((id) => this.users.get(id))
        .filter((user): user is ModelUser => user != null)
        .map(encodeUser),
      chats: chats.map((chat) => this.encodeChat(chat)),
      dialogs: chats.map((chat) =>
        encodeDialog(chat, this.requireDialog(chat.id), this.unreadCount(chat.id)),
      ),
      spaces: [],
      userGroups: [],
    }
  }

  private sendMessage(
    sessionId: number,
    chatId: bigint,
    input: Extract<RpcCall["input"], { oneofKind: "sendMessage" }>["sendMessage"],
  ): RpcOutcome {
    const randomId = input.randomId
    const existing = randomId != null ? this.sentByRandomId.get(randomId) : undefined
    if (existing && randomId != null) {
      // A retry of a committed send: the receipt only (server behavior).
      return {
        result: {
          oneofKind: "sendMessage",
          sendMessage: {
            updates: [
              Update.create({
                update: {
                  oneofKind: "updateMessageId",
                  updateMessageId: { messageId: existing.id, randomId },
                },
              }),
            ],
            addedUserIds: [],
            unaddedUserIds: [],
          },
        },
      }
    }
    const chat = this.requireChat(chatId)
    const message: ModelMessage = {
      id: chat.nextMessageId++,
      chatId,
      fromId: this.selfUserId,
      text: input.message ?? "",
      date: BigInt(this.now()),
      ...(randomId != null ? { randomId } : {}),
      ...(input.replyToMsgId != null ? { replyToMsgId: input.replyToMsgId } : {}),
      reactions: [],
    }
    chat.messages.set(message.id, message)
    if (randomId != null) this.sentByRandomId.set(randomId, message)
    const live = this.journalChat(chatId, (seq, date) =>
      this.newMessageUpdate(chatId, message.id, seq, date),
    )
    // The sending session gets the receipt; the account's other sessions
    // get the message (layer-2 sessions are not published to themselves).
    this.broadcast({ updates: [live], kind: "durable" }, sessionId)
    return {
      result: {
        oneofKind: "sendMessage",
        sendMessage: {
          updates: [
            Update.create({
              update: {
                oneofKind: "updateMessageId",
                updateMessageId: { messageId: message.id, randomId: randomId ?? 0n },
              },
            }),
            live,
          ],
          addedUserIds: [],
          unaddedUserIds: [],
        },
      },
    }
  }

  // ---- Internals ------------------------------------------------------------

  /**
   * The user bucket replays the read state journaled at read time, as the
   * server does. Note the chats where that replay no longer matches the
   * current state: a client that applies it unguarded diverges (KB-1).
   */
  private noteStaleRead(update: Update) {
    if (update.update.oneofKind !== "updateReadMaxId") return
    const peer = update.update.updateReadMaxId.peerId?.type
    if (peer?.oneofKind !== "chat") return
    const chatId = peer.chat.chatId
    const dialog = this.dialogs.get(chatId)
    if (!dialog) return
    if (
      update.update.updateReadMaxId.readMaxId !== dialog.readMaxId ||
      update.update.updateReadMaxId.unreadCount !== this.unreadCount(chatId)
    ) {
      this.staleReadsServed.add(chatId)
    }
  }

  /** Advance the read boundary; returns the unsequenced live update, if any. */
  private applyRead(chatId: bigint, maxId: bigint): Update | undefined {
    const dialog = this.requireDialog(chatId)
    if (maxId <= dialog.readMaxId) return undefined
    dialog.readMaxId = maxId
    const unreadCount = this.unreadCount(chatId)
    this.unreadStaleChats.delete(chatId)
    const history = this.readHistory.get(chatId) ?? []
    history.push({ readMaxId: maxId, unreadCount })
    this.readHistory.set(chatId, history)
    const update = (seq?: number, date?: number) =>
      Update.create({
        ...(seq != null ? { seq, date: BigInt(date ?? 0) } : {}),
        update: {
          oneofKind: "updateReadMaxId",
          updateReadMaxId: { peerId: chatPeer(chatId), readMaxId: maxId, unreadCount },
        },
      })
    this.journal("user", (seq, date) => update(seq, date))
    return update()
  }

  private newMessageUpdate(chatId: bigint, messageId: bigint, seq: number, date: number) {
    return this.messageUpdate("newMessage", chatId, messageId, seq, date)
  }

  /**
   * Chat-bucket message records re-read the current message when they are
   * served, as the server's replay does; a deleted one becomes chatSkipPts.
   */
  private messageUpdate(
    kind: "newMessage" | "editMessage",
    chatId: bigint,
    messageId: bigint,
    seq: number,
    date: number,
  ): Update {
    const message = this.chats.get(chatId)?.messages.get(messageId)
    if (!message) {
      return Update.create({
        seq,
        date: BigInt(date),
        update: { oneofKind: "chatSkipPts", chatSkipPts: { chatId } },
      })
    }
    const encoded = encodeMessage(message, this.selfUserId)
    return Update.create({
      seq,
      date: BigInt(date),
      update:
        kind === "newMessage"
          ? { oneofKind: "newMessage", newMessage: { message: encoded } }
          : { oneofKind: "editMessage", editMessage: { message: encoded } },
    })
  }

  /** Append a chat-bucket record; returns the live form built right now. */
  private journalChat(
    chatId: bigint,
    build: (seq: number, date: number) => Update,
  ): Update {
    return this.journal(`chat:${chatId}`, build)
  }

  protected journal<T extends Update | SyncSkippedSequence_Reason>(
    bucketId: BucketId,
    build: (seq: number, date: number) => T,
  ): T {
    const bucket = this.bucket(bucketId)
    const seq = bucket.seq + 1
    const date = this.now()
    bucket.seq = seq
    bucket.date = date
    bucket.entries.push({ seq, date, build: () => build(seq, date) })
    return build(seq, date)
  }

  protected broadcast(push: ModelPush, exceptSession?: number) {
    for (const [id, sink] of this.sessions) {
      if (id !== exceptSession) sink(push)
    }
  }

  private resolveBucket(input: GetUpdatesInput): BucketId | undefined {
    const type = input.bucket?.type
    if (!type) return undefined
    if (type.oneofKind === "user") return "user"
    if (type.oneofKind === "space") {
      return this.spaces.has(type.space.spaceId) ? `space:${type.space.spaceId}` : undefined
    }
    if (type.oneofKind === "chat") {
      const chatId = inputPeerChatId(type.chat.peerId)
      return chatId != null && this.chats.has(chatId) ? `chat:${chatId}` : undefined
    }
    return undefined
  }

  private bucket(id: BucketId): Bucket {
    let bucket = this.buckets.get(id)
    if (!bucket) {
      bucket = { id, seq: 0, date: 0, entries: [], retainedFrom: 1 }
      this.buckets.set(id, bucket)
    }
    return bucket
  }

  private self() {
    return this.users.get(this.selfUserId)!
  }

  private requireChat(chatId: bigint) {
    const chat = this.chats.get(chatId)
    if (!chat) throw new Error(`No chat ${chatId} in the server model`)
    return chat
  }

  private requireDialog(chatId: bigint) {
    const dialog = this.dialogs.get(chatId)
    if (!dialog) throw new Error(`No dialog for chat ${chatId} in the server model`)
    return dialog
  }

  private requireMessage(chatId: bigint, messageId: bigint) {
    const message = this.requireChat(chatId).messages.get(messageId)
    if (!message) throw new Error(`No message ${messageId} in chat ${chatId}`)
    return message
  }
}

const compareReactions = (
  left: { userId: bigint; emoji: string },
  right: { userId: bigint; emoji: string },
) =>
  left.userId === right.userId
    ? left.emoji < right.emoji
      ? -1
      : left.emoji > right.emoji
        ? 1
        : 0
    : left.userId < right.userId
      ? -1
      : 1
