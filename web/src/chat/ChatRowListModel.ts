import type {
  Message,
  MessageKey,
  MessageSendingStatus,
} from "@inline/client"
import type {
  ChatID,
  MessageID,
  UserID,
} from "@inline/ids"
import {
  chatId as exactChatId,
  messageId,
  userId as exactUserId,
} from "@inline/ids"
import {
  makeMessagePresentation,
  type ChatMessagePresentation,
} from "./MessageContent"

export type ChatMessageRow = {
  id: MessageKey
  messageId: MessageID
  chatId: ChatID
  fromId: UserID
  out: boolean
  date?: number
  presentation: ChatMessagePresentation
  status?: MessageSendingStatus
  embeddedReply?: ChatMessageEmbeddedReply
  replyThreadSummary?: ChatMessageReplyThreadSummary
  forwardHeader?: ChatMessageForwardHeader
  reactions?: ChatMessageReactions
}

export type ChatMessageReaction = {
  emoji: string
  userId: UserID
  date?: number
}

export type ChatMessageReactionIntent = {
  id: string
  emoji: string
  userId: UserID
  action: "add" | "delete"
}

export type ChatMessageReactions = {
  reactions: ChatMessageReaction[]
  intents: ChatMessageReactionIntent[]
}

export type ChatMessageEmbeddedReply = {
  messageId: MessageID
  fromId?: UserID
  presentation?: ChatMessagePresentation
}

export type ChatMessageReplyThreadSummary = {
  chatId: ChatID
  replyCount: number
  hasUnread: boolean
  recentReplierUserIds: UserID[]
}

export type ChatMessageForwardHeader = {
  fromPeer?:
    | { peerKind: "user"; peerId: UserID }
    | { peerKind: "chat"; peerId: ChatID }
  fromId?: UserID
  fromMessageId?: MessageID
}

const makeForwardHeader = (
  message: Message,
): ChatMessageForwardHeader | undefined => {
  const forward = message.fwdFrom
  if (!forward) return undefined
  const peer = forward.fromPeerId?.type
  return {
    fromPeer:
      peer?.oneofKind === "user" && peer.user.userId > 0n
        ? {
            peerKind: "user",
            peerId: exactUserId(peer.user.userId),
          }
        : peer?.oneofKind === "chat" && peer.chat.chatId > 0n
          ? {
              peerKind: "chat",
              peerId: exactChatId(peer.chat.chatId),
            }
          : undefined,
    fromId:
      forward.fromId > 0n
        ? exactUserId(forward.fromId)
        : undefined,
    fromMessageId:
      forward.fromMessageId > 0n
        ? messageId(forward.fromMessageId)
        : undefined,
  }
}

const reactionDate = (value: bigint): number | undefined => {
  const number = Number(value)
  if (!Number.isSafeInteger(number)) return undefined
  return number > 1_000_000_000_000 ? number / 1_000 : number
}

const makeReactions = (
  message: Message,
): ChatMessageReactions | undefined => {
  const reactions = message.reactions?.reactions.map((reaction) => ({
    emoji: reaction.emoji,
    userId: exactUserId(reaction.userId),
    date: reactionDate(reaction.date),
  })) ?? []
  const intents = message.reactionIntents?.map((intent) => ({
    ...intent,
  })) ?? []
  return reactions.length > 0 || intents.length > 0
    ? { reactions, intents }
    : undefined
}

export const makeChatMessageRow = (
  message: Message,
  repliedToMessage?: Message,
): ChatMessageRow => {
  const replies = message.replies
  return {
    id: message.id,
    messageId: message.messageId,
    chatId: message.chatId,
    fromId: message.fromId,
    out: Boolean(message.out),
    date: message.date,
    presentation: makeMessagePresentation(message),
    status: message.status,
    forwardHeader: makeForwardHeader(message),
    reactions: makeReactions(message),
    embeddedReply: message.replyToMsgId
      ? repliedToMessage
        ? {
            messageId: repliedToMessage.messageId,
            fromId: repliedToMessage.fromId,
            presentation: makeMessagePresentation(repliedToMessage),
          }
        : { messageId: message.replyToMsgId }
      : undefined,
    replyThreadSummary:
      replies && replies.replyCount > 0
        ? {
            chatId: exactChatId(replies.chatId),
            replyCount: replies.replyCount,
            hasUnread: Boolean(replies.hasUnread),
            recentReplierUserIds:
              replies.recentReplierUserIds.map(exactUserId),
          }
        : undefined,
  }
}

export const makeChatMessageRows = (
  messages: Message[],
  references: ReadonlyMap<MessageID, Message> = new Map(),
) =>
  messages.map((message) =>
    makeChatMessageRow(
      message,
      message.replyToMsgId
        ? references.get(message.replyToMsgId)
        : undefined,
    ),
  )
