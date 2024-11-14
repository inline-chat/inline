import { db } from "@in/server/db"
import { desc, eq, sql, and } from "drizzle-orm"
import { chats, dialogs, messages, type DbChat } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { Optional, type Static, Type } from "@sinclair/typebox"
import { encodeMessageInfo, TInputPeerInfo, TMessageInfo, TPeerInfo, type TUpdateInfo } from "@in/server/models"
import { createMessage, ServerMessageKind } from "@in/server/ws/protocol"
import { connectionManager } from "@in/server/ws/connections"
import { getUpdateGroup } from "@in/server/utils/updates"

export const Input = Type.Object({
  peerId: Optional(TInputPeerInfo),
  text: Type.String(),

  peerUserId: Optional(Type.String()),
  peerThreadId: Optional(Type.String()),
})

type Input = Static<typeof Input>

type Context = {
  currentUserId: number
}

export const Response = Type.Object({
  message: TMessageInfo,
})

type Response = Static<typeof Response>

export const handler = async (input: Input, context: Context): Promise<Response> => {
  const peerId = input.peerUserId
    ? { userId: Number(input.peerUserId) }
    : input.peerThreadId
    ? { threadId: Number(input.peerThreadId) }
    : input.peerId

  if (!peerId) {
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }

  // Get or validate chat ID from peer info
  const chatId = await getChatIdFromPeer(peerId, context)

  // Get the last message ID for this chat to maintain sequence
  const prevMessageId = await db
    .select({ messageId: sql<number>`MAX(${messages.messageId})` })
    .from(messages)
    .where(eq(messages.chatId, chatId))
    .then(([result]) => result?.messageId ?? 0)

  // Insert the new message
  const [newMessage] = await db
    .insert(messages)
    .values({
      chatId: chatId,
      text: input.text,
      fromId: context.currentUserId,
      messageId: prevMessageId + 1,
      date: new Date(),
    })
    .returning()

  if (!newMessage) {
    Log.shared.error("Failed to send message")
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }

  // Update the chat's last message ID
  await db
    .update(chats)
    .set({ lastMsgId: prevMessageId + 1 })
    .where(eq(chats.id, chatId))

  try {
    const encodedMessage = encodeMessageInfo(newMessage, {
      currentUserId: context.currentUserId,
      peerId: peerId,
    })

    sendMessageUpdate({
      message: encodedMessage,
      currentUserId: context.currentUserId,
    })

    return { message: encodedMessage }
  } catch (encodeError) {
    Log.shared.error("Failed to encode message", {
      error: encodeError,
      message: newMessage,
    })
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}

export const getChatIdFromPeer = async (
  peer: Static<typeof TInputPeerInfo>,
  context: { currentUserId: number },
): Promise<number> => {
  // Handle thread chat
  if ("threadId" in peer) {
    const threadId = peer.threadId
    if (!threadId || isNaN(threadId)) {
      throw new InlineError(InlineError.ApiError.PEER_INVALID)
    }
    return threadId
  }

  // Handle user chat
  if ("userId" in peer) {
    const userId = peer.userId
    if (!userId || isNaN(userId)) {
      throw new InlineError(InlineError.ApiError.PEER_INVALID)
    }

    // For self-chat, both minUserId and maxUserId will be currentUserId
    const minUserId = Math.min(context.currentUserId, userId)
    const maxUserId = Math.max(context.currentUserId, userId)

    // Find chat where minUserId and maxUserId match
    const existingChat = await db
      .select()
      .from(chats)
      .where(and(eq(chats.type, "private"), eq(chats.minUserId, minUserId), eq(chats.maxUserId, maxUserId)))
      .then((result) => result[0])

    if (existingChat) {
      return existingChat.id
    }

    // create new chat???
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }

  throw new InlineError(InlineError.ApiError.PEER_INVALID)
}

// HERE YOU ARE DENA
const sendMessageUpdate = async ({ message, currentUserId }: { message: TMessageInfo; currentUserId: number }) => {
  const update: TUpdateInfo = {
    newMessage: { message },
  }
  const peerId = message.peerId
  const updateGroup = await getUpdateGroup(peerId, { currentUserId })

  if (updateGroup.type === "users") {
    updateGroup.userIds.forEach((userId) => {
      connectionManager.sendToUser(userId, createMessage({ kind: ServerMessageKind.Message, payload: update }))
    })
  } else if (updateGroup.type === "space") {
    connectionManager.sendToSpace(
      updateGroup.spaceId,
      createMessage({ kind: ServerMessageKind.Message, payload: update }),
    )
  }
}
