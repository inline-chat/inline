import { db } from "@in/server/db"
import { desc, eq, sql, and } from "drizzle-orm"
import { chats, messages } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { Optional, type Static, Type } from "@sinclair/typebox"
import { encodeMessageInfo, TInputPeerInfo, TMessageInfo } from "@in/server/models"

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
  try {
    let chatId = await getChatIdFromPeer(input.peerId, input.peerUserId, input.peerThreadId, context)
    console.log("chatId is", chatId)

    var prevMessageId: number = await db
      .select({ messageId: sql<number>`MAX(${messages.messageId})` })
      .from(messages)
      .where(eq(messages.chatId, chatId))
      .then(([result]) => result?.messageId ?? 0)
    console.log("prevMessageId", prevMessageId)
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
    console.log("newMessage", newMessage)

    await db
      .update(chats)
      .set({ lastMsgId: prevMessageId + 1 })
      .where(eq(chats.id, chatId))

    if (!newMessage) {
      Log.shared.error("Failed to send message")
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    try {
      const encodedMessage = encodeMessageInfo(
        {
          ...newMessage,
        },
        { currentUserId: context.currentUserId },
      )

      return { message: encodedMessage }
    } catch (encodeError) {
      Log.shared.error("Failed to encode message", {
        error: encodeError,
        message: newMessage,
        schema: TMessageInfo,
      })
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }
  } catch (error) {
    Log.shared.error("Failed to send message", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}

export const getChatIdFromPeer = async (
  peer: Static<typeof TInputPeerInfo> | undefined,
  peerUId: string | undefined,
  peerTId: string | undefined,
  context: { currentUserId: number },
): Promise<number> => {
  // For threads, chatId is the same as threadId
  let peerUserId = peerUId ? Number(peerUId) : undefined
  let peerThreadId = peerTId ? Number(peerTId) : undefined

  // Handle thread chat
  if ((peer && "threadId" in peer) || peerThreadId) {
    const threadId = peerThreadId ?? (peer && "threadId" in peer ? peer.threadId : undefined)
    if (!threadId || isNaN(threadId)) {
      throw new InlineError(InlineError.ApiError.PEER_INVALID)
    }
    return threadId
  }

  // Handle user chat
  if ((peer && "userId" in peer) || peerUserId) {
    const userId = peerUserId ?? (peer && "userId" in peer ? peer.userId : undefined)
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

    throw new InlineError(InlineError.ApiError.INVALID_RECIPIENT_TYPE)
  }

  throw new InlineError(InlineError.ApiError.PEER_INVALID)
}
