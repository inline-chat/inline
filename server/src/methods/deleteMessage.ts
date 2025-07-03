import { db } from "@in/server/db"
import { eq, and, desc } from "drizzle-orm"
import { chats, messages } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import { TPeerInfo } from "@in/server/api-types"
import { TInputId } from "@in/server/types/methods"
import { getUpdateGroup } from "../modules/updates"
import type { Update } from "@in/protocol/core"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeUpdates } from "@in/server/realtime/message"

export const Input = Type.Object({
  messageId: TInputId,
  chatId: TInputId,
  peerUserId: Type.Optional(TInputId),
  peerThreadId: Type.Optional(TInputId),
})

type Input = Static<typeof Input>

type Context = {
  currentUserId: number
}

export const Response = Type.Undefined()

type Response = Static<typeof Response>

export const handler = async (input: Input, context: Context): Promise<Response> => {
  const messageId = Number(input.messageId)
  if (isNaN(messageId)) {
    throw new InlineError(InlineError.ApiError.MSG_ID_INVALID)
  }

  const chatId = Number(input.chatId)
  if (isNaN(chatId)) {
    throw new InlineError(InlineError.ApiError.CHAT_ID_INVALID)
  }

  if ((input.peerUserId && input.peerThreadId) || (!input.peerUserId && !input.peerThreadId)) {
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }

  const peerId: TPeerInfo = input.peerUserId
    ? { userId: Number(input.peerUserId) }
    : { threadId: Number(input.peerThreadId) }

  await deleteMessage(messageId, chatId)
  await deleteMessageUpdate({
    messageId,
    peerId,
    currentUserId: context.currentUserId,
  })
}

const deleteMessage = async (messageId: number, chatId: number) => {
  try {
    let [chat] = await db.select().from(chats).where(eq(chats.id, chatId))
    if (!chat) {
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    let [message] = await db
      .select()
      .from(messages)
      .where(and(eq(messages.chatId, chatId), eq(messages.messageId, messageId)))

    if (chat.lastMsgId === messageId) {
      const previousMessages = await db
        .select()
        .from(messages)
        .where(eq(messages.chatId, chatId))
        .orderBy(desc(messages.date))
        .limit(1)
        .offset(1)

      const newLastMsgId = previousMessages[0]?.messageId || null
      await db.update(chats).set({ lastMsgId: newLastMsgId }).where(eq(chats.id, chatId))

      await db.delete(messages).where(and(eq(messages.chatId, chatId), eq(messages.messageId, messageId)))
    } else {
      await db.delete(messages).where(and(eq(messages.chatId, chatId), eq(messages.messageId, messageId)))
    }
  } catch (error) {
    Log.shared.error("Error deleting message:", error)
    throw error
  }
}

const deleteMessageUpdate = async ({
  messageId,
  peerId,
  currentUserId,
}: {
  messageId: number
  peerId: TPeerInfo
  currentUserId: number
}) => {
  const updateGroup = await getUpdateGroup(peerId, { currentUserId })

  if (updateGroup.type === "dmUsers") {
    updateGroup.userIds.forEach((userId) => {
      let encodingForPeer: TPeerInfo = userId === currentUserId ? peerId : { userId: currentUserId }

      // New updates
      let messageDeletedUpdate: Update = {
        update: {
          oneofKind: "deleteMessages",
          deleteMessages: {
            messageIds: [BigInt(messageId)],
            peerId: Encoders.peer(encodingForPeer),
          },
        },
      }

      RealtimeUpdates.pushToUser(userId, [messageDeletedUpdate])
    })
  } else if (updateGroup.type === "threadUsers") {
    updateGroup.userIds.forEach((userId) => {
      // New updates
      let messageDeletedUpdate: Update = {
        update: {
          oneofKind: "deleteMessages",
          deleteMessages: {
            messageIds: [BigInt(messageId)],
            peerId: Encoders.peer(peerId),
          },
        },
      }

      RealtimeUpdates.pushToUser(userId, [messageDeletedUpdate])
    })
  }
}
