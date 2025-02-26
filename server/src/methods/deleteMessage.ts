import { db } from "@in/server/db"
import { eq, inArray, and, or, desc } from "drizzle-orm"
import { chats, members, spaces, dialogs, messages, type DbMessage, type DbFile } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import {
  encodeChatInfo,
  encodeMemberInfo,
  encodeSpaceInfo,
  encodeDialogInfo,
  TChatInfo,
  TMemberInfo,
  TSpaceInfo,
  TDialogInfo,
  TPeerInfo,
  type TUpdateInfo,
} from "@in/server/api-types"
import { TInputId } from "@in/server/types/methods"
import { Authorize } from "../utils/authorize"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { getUpdateGroup } from "../modules/updates"
import { createMessage, ServerMessageKind } from "../ws/protocol"
import { connectionManager } from "../ws/connections"
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

  if (updateGroup.type === "users") {
    updateGroup.userIds.forEach((userId) => {
      let encodingForPeer: TPeerInfo = userId === currentUserId ? peerId : { userId: currentUserId }
      const update: TUpdateInfo = {
        deleteMessage: {
          messageId,
          peerId: encodingForPeer,
        },
      }

      const updates = [update]

      connectionManager.sendToUser(userId, createMessage({ kind: ServerMessageKind.Message, payload: { updates } }))

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
  } else if (updateGroup.type === "space") {
    const userIds = connectionManager.getSpaceUserIds(updateGroup.spaceId)

    userIds.forEach((userId) => {
      const update: TUpdateInfo = {
        deleteMessage: {
          messageId,
          peerId,
        },
      }

      const updates = [update]

      connectionManager.sendToUser(
        userId,
        createMessage({ kind: ServerMessageKind.Message, payload: { updates: updates } }),
      )

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
