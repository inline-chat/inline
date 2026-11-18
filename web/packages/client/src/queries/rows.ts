/**
 * Pure mappers from the replica's models to the view rows in
 * `@inline/core-protocol`. A row is a function of the stored object (plus the
 * session's message identity), so equal inputs give structurally equal rows.
 * Optional fields are omitted rather than set to `undefined`, so rows compare
 * and clone cleanly.
 */
import {
  DialogFollowMode,
  MessageEntity_Type,
  MessageSendMode,
  type MessageEntities,
  type MessageEntity,
} from "@inline-chat/protocol/core"
import {
  sentMessageRowId,
  receivedMessageRowId,
  type ChatRow,
  type DialogRow,
  type DraftRow,
  type Entity,
  type MessageRowId,
  type EntityType,
  type MessageRow,
  type MessageState,
  type ReactionSummary,
  type SpaceRow,
  type UserRow,
} from "@inline/core-protocol"
import {
  chatId as makeChatId,
  parseInlineId,
  spaceId as makeSpaceId,
  userId as makeUserId,
  type ChatID,
  type DialogID,
  type MessageID,
  type UserID,
} from "@inline/ids"
import {
  MessageSendingStatus,
  type Chat,
  type Dialog,
  type Message,
  type MessageDraft,
  type Space,
  type User,
} from "../database/models"
import { getDialogId } from "../realtime/transactions/mappers"
import { messageContent, type StoredMessageExtras } from "./content"

/** True for an ID the server assigned. Local sends use negative temporary IDs. */
export const isServerMessageId = (id: MessageID | undefined): id is MessageID =>
  id != null && parseInlineId<"message">(id, { positive: true }) != null

export const userRow = (user: User): UserRow => ({
  kind: "user",
  id: user.id,
  ...(user.firstName ? { firstName: user.firstName } : {}),
  ...(user.lastName ? { lastName: user.lastName } : {}),
  ...(user.username ? { username: user.username } : {}),
  ...(user.email ? { email: user.email } : {}),
  ...(user.bot ? { bot: true } : {}),
  ...(user.profilePhoto?.cdnUrl ? { photoUrl: user.profilePhoto.cdnUrl } : {}),
})

export const spaceRow = (space: Space): SpaceRow => ({
  kind: "space",
  id: space.id,
  name: space.name,
  ...(space.isPublic ? { isPublic: true } : {}),
})

/**
 * A chat row. `lastMessageRowId` is the row ID of the chat's last message
 * when the caller knows it (the message is on the device); every query
 * computes it the same way, so the row is the same in each.
 */
export const chatRow = (chat: Chat, lastMessageRowId?: MessageRowId): ChatRow => ({
  kind: "chat",
  id: chat.id,
  ...(chat.title ? { title: chat.title } : {}),
  ...(chat.emoji ? { emoji: chat.emoji } : {}),
  ...(chat.spaceId ? { spaceId: chat.spaceId } : {}),
  ...(chat.isPublic ? { isPublic: true } : {}),
  ...(chat.peerUserId ? { peerUserId: chat.peerUserId } : {}),
  ...(chat.parentChatId ? { parentChatId: chat.parentChatId } : {}),
  ...(chat.parentMessageId ? { parentMessageId: chat.parentMessageId } : {}),
  ...(isServerMessageId(chat.lastMsgId) ? { lastMessageId: chat.lastMsgId } : {}),
  ...(lastMessageRowId ? { lastMessageRowId } : {}),
  ...(chat.date != null ? { lastActivityDate: chat.date } : {}),
  ...(chat.createdBy ? { createdBy: chat.createdBy } : {}),
  dialogId: dialogIdForChat(chat),
})

/**
 * The ID of a chat's dialog, as the replica keys it (`getDialogId`): a
 * direct chat's by its peer user, any other chat's by the chat.
 */
export const dialogIdForChat = (chat: Pick<Chat, "id" | "peerUserId">): DialogID =>
  chat.peerUserId ? getDialogId({ peerUserId: chat.peerUserId }) : getDialogId({ peerThreadId: chat.id })

const followModeOf = (mode: number | undefined): DialogRow["followMode"] => {
  if (mode === DialogFollowMode.FOLLOWING) return "following"
  if (mode === DialogFollowMode.UNFOLLOWED) return "unfollowed"
  return undefined
}

const count = (value: number | undefined) =>
  value != null && Number.isSafeInteger(value) && value >= 0 ? value : undefined

const optional = <K extends string, V>(key: K, value: V | undefined) =>
  (value === undefined ? {} : { [key]: value }) as { [P in K]?: V }

export const dialogRow = (dialog: Dialog): DialogRow => ({
  kind: "dialog",
  id: dialog.id,
  chatId: dialog.chatId,
  ...(dialog.peerUserId ? { peerUserId: dialog.peerUserId } : {}),
  ...(dialog.spaceId ? { spaceId: dialog.spaceId } : {}),
  pinned: dialog.pinned === true,
  archived: dialog.archived === true,
  open: dialog.open === true,
  ...(dialog.order ? { order: dialog.order } : {}),
  ...(dialog.pinnedOrder ? { pinnedOrder: dialog.pinnedOrder } : {}),
  unreadCount: dialog.unreadCount ?? 0,
  unreadMark: dialog.unreadMark === true,
  ...(dialog.readMaxId ? { readMaxId: dialog.readMaxId } : {}),
  ...optional("followMode", followModeOf(dialog.followMode)),
  ...optional("notificationMode", dialog.notificationMode),
  ...optional("unreadMentionsCount", count(dialog.unreadMentionsCount)),
  ...optional("unreadReactionsCount", count(dialog.unreadReactionsCount)),
  ...(dialog.folderId != null ? { folderId: String(dialog.folderId) } : {}),
})

export const draftRow = (chatId: ChatID, draft: MessageDraft): DraftRow => {
  const entities = entitiesFromProtocol(draft.entities)
  return {
    kind: "draft",
    id: chatId,
    text: draft.text,
    ...(entities.length > 0 ? { entities } : {}),
    revision: draft.revision,
  }
}

const messageState = (message: Message): MessageState => {
  switch (message.status) {
    case MessageSendingStatus.Sending:
      return "sending"
    case MessageSendingStatus.Failed:
      return "failed"
    default:
      return "sent"
  }
}

const reactionSummaries = (
  message: Message,
  me: UserID | undefined,
): ReactionSummary[] => {
  const byEmoji = new Map<string, { users: Set<string>; order: number }>()
  let order = 0
  for (const reaction of message.reactions?.reactions ?? []) {
    const entry = byEmoji.get(reaction.emoji) ?? { users: new Set(), order: order++ }
    entry.users.add(reaction.userId.toString())
    byEmoji.set(reaction.emoji, entry)
  }
  // Owner-local reaction intents overlay the confirmed reactions.
  for (const intent of message.reactionIntents ?? []) {
    const entry = byEmoji.get(intent.emoji) ?? { users: new Set(), order: order++ }
    if (intent.action === "add") entry.users.add(String(intent.userId))
    else entry.users.delete(String(intent.userId))
    byEmoji.set(intent.emoji, entry)
  }
  return Array.from(byEmoji, ([emoji, entry]) => ({ emoji, entry }))
    .filter(({ entry }) => entry.users.size > 0)
    .sort((left, right) => left.entry.order - right.entry.order)
    .map(({ emoji, entry }) => ({
      emoji,
      count: entry.users.size,
      mine: me != null && entry.users.has(String(me)),
    }))
}

/**
 * A message row. `clientKey` is the session's identity for a message sent
 * from this device; it decides the row ID (see `core-protocol`).
 */
export const messageRow = (
  message: Message & StoredMessageExtras,
  clientKey: string | undefined,
  me: UserID | undefined,
): MessageRow => {
  const entities = entitiesFromProtocol(message.entities)
  const reactions = reactionSummaries(message, me)
  const content = messageContent(message)
  return {
    kind: "message",
    id:
      clientKey != null
        ? sentMessageRowId(message.chatId, clientKey)
        : receivedMessageRowId(message.chatId, message.messageId),
    chatId: message.chatId,
    ...(isServerMessageId(message.messageId) ? { messageId: message.messageId } : {}),
    ...(clientKey != null ? { clientKey } : {}),
    fromId: message.fromId,
    out: message.out === true,
    date: message.date ?? 0,
    text: message.message ?? "",
    ...(entities.length > 0 ? { entities } : {}),
    ...(message.replyToMsgId ? { replyToMessageId: message.replyToMsgId } : {}),
    ...(message.editDate ? { editDate: message.editDate } : {}),
    state: messageState(message),
    ...(reactions.length > 0 ? { reactions } : {}),
    ...(content.unsupported ? { hasUnsupportedContent: true } : {}),
    ...(message.mentioned ? { mentioned: true } : {}),
    ...(message.sendMode === MessageSendMode.MODE_SILENT ? { silent: true } : {}),
    ...content.fields,
  }
}

// ---------------------------------------------------------------------------
// Entities

const entityTypeByProtocol: Partial<Record<MessageEntity_Type, EntityType>> = {
  [MessageEntity_Type.MENTION]: "mention",
  [MessageEntity_Type.URL]: "url",
  [MessageEntity_Type.TEXT_URL]: "textUrl",
  [MessageEntity_Type.EMAIL]: "email",
  [MessageEntity_Type.BOLD]: "bold",
  [MessageEntity_Type.ITALIC]: "italic",
  [MessageEntity_Type.USERNAME_MENTION]: "usernameMention",
  [MessageEntity_Type.CODE]: "code",
  [MessageEntity_Type.PRE]: "pre",
  [MessageEntity_Type.PHONE_NUMBER]: "phoneNumber",
  [MessageEntity_Type.THREAD]: "thread",
  [MessageEntity_Type.THREAD_TITLE]: "threadTitle",
  [MessageEntity_Type.BOT_COMMAND]: "botCommand",
  [MessageEntity_Type.GROUP_MENTION]: "groupMention",
  [MessageEntity_Type.UNDERLINE]: "underline",
  [MessageEntity_Type.STRIKETHROUGH]: "strikethrough",
  [MessageEntity_Type.HIGHLIGHT]: "highlight",
  [MessageEntity_Type.MATH]: "math",
  [MessageEntity_Type.BLOCKQUOTE]: "blockquote",
}

const protocolTypeByEntity = Object.fromEntries(
  Object.entries(entityTypeByProtocol).map(([protocol, type]) => [type, Number(protocol)]),
) as Record<EntityType, MessageEntity_Type>

const safeNumber = (value: bigint): number | undefined => {
  const number = Number(value)
  return Number.isSafeInteger(number) && number >= 0 ? number : undefined
}

export const entitiesFromProtocol = (entities: MessageEntities | undefined): Entity[] => {
  const result: Entity[] = []
  for (const entity of entities?.entities ?? []) {
    const type = entityTypeByProtocol[entity.type]
    const offset = safeNumber(entity.offset)
    const length = safeNumber(entity.length)
    if (!type || offset == null || length == null) continue
    const detail = entity.entity
    result.push({
      type,
      offset,
      length,
      ...(detail.oneofKind === "mention" ? { userId: makeUserId(detail.mention.userId) } : {}),
      ...(detail.oneofKind === "mention" && detail.mention.agentId != null
        ? { agentId: detail.mention.agentId.toString() }
        : {}),
      ...(detail.oneofKind === "textUrl" ? { url: detail.textUrl.url } : {}),
      ...(detail.oneofKind === "pre" && detail.pre.language
        ? { language: detail.pre.language }
        : {}),
      ...(detail.oneofKind === "thread" ? { chatId: makeChatId(detail.thread.chatId) } : {}),
      ...(detail.oneofKind === "threadTitle"
        ? { spaceId: makeSpaceId(detail.threadTitle.spaceId), title: detail.threadTitle.title }
        : {}),
      ...(detail.oneofKind === "groupMention"
        ? { groupId: detail.groupMention.groupId.toString() }
        : {}),
      ...(detail.oneofKind === "botCommand"
        ? { botUserId: makeUserId(detail.botCommand.botUserId) }
        : {}),
      ...(detail.oneofKind === "math" ? { display: detail.math.display } : {}),
    })
  }
  return result
}

export const entitiesToProtocol = (
  entities: readonly Entity[] | undefined,
): MessageEntities | undefined => {
  if (!entities || entities.length === 0) return undefined
  return {
    entities: entities.map((entity): MessageEntity => {
      let detail: MessageEntity["entity"] = { oneofKind: undefined }
      if (entity.type === "mention" && entity.userId) {
        detail = {
          oneofKind: "mention",
          mention: {
            userId: BigInt(entity.userId),
            ...(entity.agentId ? { agentId: BigInt(entity.agentId) } : {}),
          },
        }
      } else if (entity.type === "groupMention" && entity.groupId) {
        detail = { oneofKind: "groupMention", groupMention: { groupId: BigInt(entity.groupId) } }
      } else if (entity.type === "threadTitle" && entity.spaceId) {
        detail = {
          oneofKind: "threadTitle",
          threadTitle: { spaceId: BigInt(entity.spaceId), title: entity.title ?? "" },
        }
      } else if (entity.type === "botCommand" && entity.botUserId) {
        detail = { oneofKind: "botCommand", botCommand: { botUserId: BigInt(entity.botUserId) } }
      } else if (entity.type === "math") {
        detail = { oneofKind: "math", math: { display: entity.display === true } }
      } else if (entity.type === "textUrl" && entity.url != null) {
        detail = { oneofKind: "textUrl", textUrl: { url: entity.url } }
      } else if (entity.type === "pre") {
        detail = { oneofKind: "pre", pre: { language: entity.language ?? "" } }
      } else if (entity.type === "thread" && entity.chatId) {
        detail = { oneofKind: "thread", thread: { chatId: BigInt(entity.chatId) } }
      }
      return {
        type: protocolTypeByEntity[entity.type] ?? MessageEntity_Type.UNSPECIFIED,
        offset: BigInt(entity.offset),
        length: BigInt(entity.length),
        entity: detail,
      }
    }),
  }
}

/** Validate entities that arrived over the protocol. */
export const isValidEntityList = (value: unknown): value is Entity[] =>
  Array.isArray(value) &&
  value.every(
    (entity) =>
      entity != null &&
      typeof entity === "object" &&
      typeof (entity as Entity).type === "string" &&
      (entity as Entity).type in protocolTypeByEntity &&
      Number.isSafeInteger((entity as Entity).offset) &&
      (entity as Entity).offset >= 0 &&
      Number.isSafeInteger((entity as Entity).length) &&
      (entity as Entity).length >= 0,
  )
