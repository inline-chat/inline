import {
  DbObjectKind,
  getMessages,
  messageKey,
  type Chat,
  type Db,
  type Message,
  type RealtimeService,
} from "@inline/client/core"
import {
  protocolId,
  type ChatID,
  type MessageID,
} from "@inline/ids"

const maximumAnchorExcerptLength = 72

const normalizedExcerpt = (text?: string) => text?.replaceAll(/\s+/g, " ").trim()

export const replyThreadAnchorKey = (chat?: Chat) =>
  chat?.parentChatId == null || chat.parentMessageId == null
    ? undefined
    : messageKey(chat.parentChatId, chat.parentMessageId)

export const inlineChatTitle = (chat?: Chat, anchor?: Message) => {
  const title = chat?.title?.trim()
  if (title) return title

  if (chat?.parentMessageId != null) {
    const excerpt = normalizedExcerpt(anchor?.message)
    if (!excerpt) return "Re: Message"
    return `Re: ${Array.from(excerpt).slice(0, maximumAnchorExcerptLength).join("")}`
  }

  return chat ? "New thread" : "Chat"
}

type AnchorGroup = {
  parentChatId: ChatID
  messageIds: MessageID[]
}

const anchorGroups = (chats: Chat[]): AnchorGroup[] => {
  const idsByParentChat = new Map<ChatID, Set<MessageID>>()
  for (const chat of chats) {
    if (chat.parentChatId == null || chat.parentMessageId == null) continue
    const ids =
      idsByParentChat.get(chat.parentChatId) ?? new Set<MessageID>()
    ids.add(chat.parentMessageId)
    idsByParentChat.set(chat.parentChatId, ids)
  }
  return Array.from(idsByParentChat, ([parentChatId, ids]) => ({
    parentChatId,
    messageIds: Array.from(ids),
  }))
}

export const hydrateReplyThreadAnchors = async (db: Db, chats: Chat[]) =>
  await db.hydrateObjects(
    DbObjectKind.Message,
    anchorGroups(chats).flatMap(({ parentChatId, messageIds }) =>
      messageIds.map((messageId) => messageKey(parentChatId, messageId)),
    ),
  )

export const refreshMissingReplyThreadAnchors = async (
  db: Db,
  realtime: RealtimeService,
  chats: Chat[],
) => {
  const requests = anchorGroups(chats)
    .map(({ parentChatId, messageIds }) => ({
      parentChatId,
      messageIds: messageIds.filter(
        (messageId) =>
          !db.get(db.ref(DbObjectKind.Message, messageKey(parentChatId, messageId))),
      ),
    }))
    .filter(({ messageIds }) => messageIds.length > 0)

  await Promise.all(
    requests.map(({ parentChatId, messageIds }) =>
      realtime.query(
        getMessages({
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: protocolId(parentChatId) },
            },
          },
          messageIds,
        }),
      ),
    ),
  )
}
