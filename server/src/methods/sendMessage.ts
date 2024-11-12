import { db } from "@in/server/db"
import { desc, eq, sql, and } from "drizzle-orm"
import { chats, messages } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import { encodeMessageInfo, TInputPeerInfo, TMessageInfo } from "@in/server/models"

export const Input = Type.Object({
  peerId: TInputPeerInfo,
  text: Type.String(),
})

type Input = Static<typeof Input>

type Context = {
  currentUserId: number
}

export const Response = Type.Object({
  // message: TMessageInfo,
})

type Response = Static<typeof Response>

export const handler = async (input: Input, context: Context): Promise<Response> => {
  try {
    let chatId = await getChatIdFromPeer(input.peerId, context)
    console.log("chatId is", chatId)
    // var prevMessageId: number = await db
    //   .select({ messageId: sql<number>`MAX(${messages.messageId})` })
    //   .from(messages)
    //   .where(eq(messages.chatId, chatId))
    //   .then(([result]) => result?.messageId ?? 0)
    // const [newMessage] = await db
    //   .insert(messages)
    //   .values({
    //     chatId: chatId,
    //     text: input.text,
    //     fromId: context.currentUserId,
    //     messageId: prevMessageId + 1,
    //     date: new Date(),
    //   })
    //   .returning()
    // await db
    //   .update(chats)
    //   .set({ lastMsgId: prevMessageId + 1 })
    //   .where(eq(chats.id, chatId))
    // if (!newMessage) {
    //   Log.shared.error("Failed to send message")
    //   throw new InlineError(InlineError.ApiError.INTERNAL)
    // }
    // return { message: encodeMessageInfo(newMessage, { currentUserId: context.currentUserId }) }
    return {}
  } catch (error) {
    Log.shared.error("Failed to send message", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}

export const getChatIdFromPeer = async (
  peer: Static<typeof TInputPeerInfo>,
  context: { currentUserId: number },
): Promise<number> => {
  // For threads, chatId is the same as threadId
  if ("threadId" in peer) {
    return peer.threadId
  }

  // For users, we need to find the private chat
  if ("userId" in peer) {
    const peerId = Number(peer.userId)
    if (isNaN(peerId)) {
      throw new InlineError(InlineError.ApiError.PEER_INVALID)
    }

    // For self-chat, both minUserId and maxUserId will be currentUserId
    const minUserId = Math.min(context.currentUserId, peerId)
    const maxUserId = Math.max(context.currentUserId, peerId)

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
