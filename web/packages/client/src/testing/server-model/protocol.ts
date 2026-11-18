import type {
  Chat,
  Dialog,
  DialogNotificationSettings_Mode,
  InputPeer,
  Message,
  MessageMedia,
  Peer,
  User,
} from "@inline-chat/protocol/core"

/** Wire shapes the server model produces, kept in one place. */

export const chatPeer = (chatId: bigint): Peer => ({
  type: { oneofKind: "chat", chat: { chatId } },
})

export const chatInputPeer = (chatId: bigint): InputPeer => ({
  type: { oneofKind: "chat", chat: { chatId } },
})

/** The chat ID an input peer names, if it names a thread. */
export const inputPeerChatId = (peer: InputPeer | undefined): bigint | undefined =>
  peer?.type.oneofKind === "chat" ? peer.type.chat.chatId : undefined

export type ModelUser = {
  id: bigint
  firstName: string
}

export type ModelReaction = {
  userId: bigint
  emoji: string
  date: bigint
}

export type ModelMessage = {
  id: bigint
  chatId: bigint
  fromId: bigint
  text: string
  date: bigint
  editDate?: bigint
  /** Set for messages the model's own user sent through `sendMessage`. */
  randomId?: bigint
  replyToMsgId?: bigint
  reactions: ModelReaction[]
  /** Photo, video, document or voice, as the wire carries it (`SEARCH_MESSAGES` filters on it). */
  media?: MessageMedia
  /** The text holds a link (`FILTER_LINKS`). */
  hasLink?: boolean
}

export type ModelChat = {
  id: bigint
  title: string
  spaceId?: bigint
  participants: bigint[]
  nextMessageId: bigint
  messages: Map<bigint, ModelMessage>
}

export type ModelDialog = {
  chatId: bigint
  readMaxId: bigint
  /** Per-chat notification mode; absent follows the global settings. */
  notificationMode?: DialogNotificationSettings_Mode
}

export const encodeUser = (user: ModelUser): User => ({
  id: user.id,
  firstName: user.firstName,
  min: true,
})

/** A message as the model's own user sees it right now. */
export const encodeMessage = (message: ModelMessage, selfUserId: bigint): Message => ({
  id: message.id,
  fromId: message.fromId,
  chatId: message.chatId,
  peerId: chatPeer(message.chatId),
  message: message.text,
  out: message.fromId === selfUserId,
  date: message.date,
  ...(message.editDate != null ? { editDate: message.editDate } : {}),
  ...(message.replyToMsgId != null ? { replyToMsgId: message.replyToMsgId } : {}),
  ...(message.media ? { media: message.media } : {}),
  ...(message.hasLink ? { hasLink: true } : {}),
  ...(message.reactions.length > 0
    ? {
        reactions: {
          reactions: message.reactions.map((reaction) => ({
            emoji: reaction.emoji,
            userId: reaction.userId,
            messageId: message.id,
            chatId: message.chatId,
            date: reaction.date,
          })),
        },
      }
    : {}),
})

export const latestMessage = (chat: ModelChat): ModelMessage | undefined => {
  let latest: ModelMessage | undefined
  for (const message of chat.messages.values()) {
    if (!latest || message.id > latest.id) latest = message
  }
  return latest
}

export const encodeChat = (chat: ModelChat): Chat => {
  const latest = latestMessage(chat)
  return {
    id: chat.id,
    title: chat.title,
    peerId: chatPeer(chat.id),
    ...(chat.spaceId != null ? { spaceId: chat.spaceId } : {}),
    ...(latest ? { lastMsgId: latest.id, date: latest.date } : {}),
  }
}

export const encodeDialog = (
  chat: ModelChat,
  dialog: ModelDialog,
  unreadCount: number,
): Dialog => ({
  peer: chatPeer(chat.id),
  chatId: chat.id,
  ...(chat.spaceId != null ? { spaceId: chat.spaceId } : {}),
  readMaxId: dialog.readMaxId,
  unreadCount,
  unreadMark: false,
  ...(dialog.notificationMode != null
    ? { notificationSettings: { mode: dialog.notificationMode } }
    : {}),
})
