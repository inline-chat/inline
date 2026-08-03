import type { InputPeer } from "@inline-chat/protocol/core"
import { ModelError } from "@in/server/db/models/_errors"
import { ChatModel } from "@in/server/db/models/chats"
import { MessageModel } from "@in/server/db/models/messages"
import type { DbChat } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import {
  CHAT_TRANSCRIPT_DEFAULT_LIMIT,
  CHAT_TRANSCRIPT_MAX_LIMIT,
  normalizeChatTranscriptMessage,
  renderHumanReadableChatTranscript,
  type ChatTranscriptPage,
} from "@in/server/modules/chatTranscript"
import { buildDefaultReplyThreadTitle, getAnchorMessageForChat, getChatById } from "@in/server/modules/subthreads"
import { RealtimeRpcError } from "@in/server/realtime/errors"

type Input = {
  peerId: InputPeer
  mode?: "humanReadable"
  length?: "concise"
  media?: "included" | "excluded"
  beforeMessageId?: bigint
  limit?: number
}

export const getChatTranscript = async (input: Input, context: FunctionContext): Promise<ChatTranscriptPage> => {
  validateInput(input)

  const chat = await getThreadWithAccess(input.peerId, context.currentUserId)
  const limit = input.limit ?? CHAT_TRANSCRIPT_DEFAULT_LIMIT
  const beforeMessageId = input.beforeMessageId
  const fetchedMessages = await MessageModel.getMessages(input.peerId, {
    currentUserId: context.currentUserId,
    mode: beforeMessageId === undefined ? "latest" : "older",
    beforeId: beforeMessageId,
    limit: limit + 1,
  })
  const pageMessages = fetchedMessages.slice(0, limit)
  const includeMedia = input.media !== "excluded"
  const nowSeconds = Math.floor(Date.now() / 1000)
  const parentContext = await getParentContext(chat, context.currentUserId)

  return renderHumanReadableChatTranscript({
    title: chat.title?.trim()
      || (parentContext?.message ? buildDefaultReplyThreadTitle(parentContext.message) : "Untitled chat"),
    link: chatLink(chat.id),
    parent: parentContext?.message
      ? normalizeChatTranscriptMessage(parentContext.message, { includeMedia, nowSeconds })
      : undefined,
    parentChat: parentContext?.chat
      ? { title: parentContext.chat.title?.trim() || "Untitled chat", link: chatLink(parentContext.chat.id) }
      : undefined,
    messagesNewestFirst: pageMessages.map((message) =>
      normalizeChatTranscriptMessage(message, { includeMedia, nowSeconds })
    ),
    hasOlderMessages: fetchedMessages.length > limit,
  })
}

function validateInput(input: Input): void {
  if (input.peerId.type.oneofKind !== "chat") {
    throw RealtimeRpcError.BadRequest()
  }
  if (input.mode !== undefined && input.mode !== "humanReadable") {
    throw RealtimeRpcError.BadRequest()
  }
  if (input.length !== undefined && input.length !== "concise") {
    throw RealtimeRpcError.BadRequest()
  }
  if (input.media !== undefined && input.media !== "included" && input.media !== "excluded") {
    throw RealtimeRpcError.BadRequest()
  }
  if (input.beforeMessageId !== undefined && input.beforeMessageId <= 0n) {
    throw RealtimeRpcError.BadRequest()
  }
  if (
    input.limit !== undefined
    && (!Number.isInteger(input.limit) || input.limit < 1 || input.limit > CHAT_TRANSCRIPT_MAX_LIMIT)
  ) {
    throw RealtimeRpcError.BadRequest()
  }
}

async function getThreadWithAccess(inputPeer: InputPeer, currentUserId: number): Promise<DbChat> {
  try {
    const chat = await ChatModel.getChatFromInputPeer(inputPeer, { currentUserId })
    if (chat.type !== "thread") {
      throw RealtimeRpcError.BadRequest()
    }
    await AccessGuards.ensureChatAccess(chat, currentUserId)
    return chat
  } catch (error) {
    if (error instanceof ModelError && error.code === ModelError.Codes.CHAT_INVALID) {
      throw RealtimeRpcError.ChatIdInvalid()
    }
    throw error
  }
}

async function getParentContext(
  chat: DbChat,
  currentUserId: number,
) {
  if (chat.parentChatId == null || chat.parentMessageId == null) {
    return undefined
  }

  const parentChat = await getChatById(chat.parentChatId)
  if (!parentChat) return undefined
  await AccessGuards.ensureChatAccess(parentChat, currentUserId)

  return {
    chat: parentChat,
    message: await getAnchorMessageForChat(chat),
  }
}

function chatLink(chatId: number): string {
  return `https://inline.chat/c/${chatId}`
}
