import { db } from "@in/server/db"
import { desc, eq, sql, and } from "drizzle-orm"
import {
  chats,
  dialogs,
  messages,
  sessions,
  users,
  type DbChat,
  type DbMessage,
  type DbUser,
} from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { Optional, type Static, Type } from "@sinclair/typebox"
import { encodeMessageInfo, TInputPeerInfo, TMessageInfo, TPeerInfo, type TUpdateInfo } from "@in/server/models"
import { createMessage, ServerMessageKind } from "@in/server/ws/protocol"
import { connectionManager } from "@in/server/ws/connections"
import { getUpdateGroup } from "@in/server/utils/updates"
import * as APN from "apn"
import type { HandlerContext } from "../controllers/v1/helpers"
import { apnProvider } from "../libs/apn"
import { SessionsModel } from "@in/server/db/models/sessions"
import { encryptMessage } from "@in/server/utils/encryption/encryptMessage"
import { TInputId } from "@in/server/types/methods"
import { isProd } from "@in/server/env"

export const Input = Type.Object({
  peerId: Optional(TInputPeerInfo),
  text: Type.String(),

  peerUserId: Optional(TInputId),
  peerThreadId: Optional(TInputId),

  randomId: Optional(Type.String()), // string but it's int64
})

type Input = Static<typeof Input>

export const Response = Type.Object({
  message: TMessageInfo,
})

type Response = Static<typeof Response>

export const handler = async (input: Input, context: HandlerContext): Promise<Response> => {
  const peerId = input.peerUserId
    ? { userId: Number(input.peerUserId) }
    : input.peerThreadId
    ? { threadId: Number(input.peerThreadId) }
    : input.peerId

  const randomId = input.randomId ? BigInt(input.randomId) : undefined

  if (!peerId) {
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }

  // Get or validate chat ID from peer info
  const chatId = await getChatIdFromPeer(peerId, context)

  const currentUser = await db
    .select()
    .from(users)
    .where(eq(users.id, context.currentUserId))
    .then(([user]) => user)

  if (!currentUser) {
    Log.shared.error("Current user not found", {
      currentUserId: context.currentUserId,
    })
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }

  // Encrypt
  const encryptedText = encryptMessage(input.text)

  // Insert new message with nested select for messageId sequence
  const [newMessage] = await db
    .insert(messages)
    .values({
      chatId: chatId,
      fromId: context.currentUserId,

      // Encrypted text
      text: null,
      textEncrypted: encryptedText.encrypted,
      textIv: encryptedText.iv,
      textTag: encryptedText.authTag,

      // Calculate messageId
      messageId: sql<number>`COALESCE((
        SELECT MAX(${messages.messageId}) 
        FROM ${messages}
        WHERE ${messages.chatId} = ${chatId}
      ), 0) + 1`,

      randomId: randomId ?? null,
      date: new Date(),
    })
    .returning()

  if (!newMessage) {
    Log.shared.error("Failed to send message")
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }

  let newMessageId = newMessage.messageId

  await updateLastMessageId(chatId, newMessageId)

  try {
    const encodedMessage = encodeMessageInfo(newMessage, {
      currentUserId: context.currentUserId,
      peerId: peerId,
    })

    sendMessageUpdate({
      message: newMessage,
      peerId,
      currentUserId: context.currentUserId,
    })

    const title: string = await db
      .select({ firstName: users.firstName, username: users.username })
      .from(users)
      .where(eq(users.id, context.currentUserId))
      .then(([user]) => user?.firstName ?? user?.username ?? "New Message")

    if (input.peerUserId) {
      sendPushNotificationToUser({
        userId: Number(input.peerUserId),
        title,
        chatId,
        message: input.text,
        currentUserId: context.currentUserId,
        currentUser,
      })
    }

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
const sendMessageUpdate = async ({
  peerId,
  message,
  currentUserId,
}: {
  peerId: TPeerInfo
  message: DbMessage
  currentUserId: number
}) => {
  const updateGroup = await getUpdateGroup(peerId, { currentUserId })

  const updateMessageId: TUpdateInfo = {
    updateMessageId: {
      randomId: message.randomId?.toString() ?? "",
      messageId: message.messageId,
    },
  }

  if (updateGroup.type === "users") {
    updateGroup.userIds.forEach((userId) => {
      const update: TUpdateInfo = {
        newMessage: {
          message: encodeMessageInfo(message, {
            // must encode for the user we're sending to
            currentUserId: userId,
            //  customize this per user (e.g. threadId)
            peerId: userId === currentUserId ? peerId : { userId: currentUserId },
          }),
        },
      }

      const updates = userId === currentUserId ? [updateMessageId, update] : [update]

      connectionManager.sendToUser(userId, createMessage({ kind: ServerMessageKind.Message, payload: { updates } }))
    })
  } else if (updateGroup.type === "space") {
    const userIds = connectionManager.getSpaceUserIds(updateGroup.spaceId)
    Log.shared.debug(`Sending message to space ${updateGroup.spaceId}`, { userIds })
    userIds.forEach((userId) => {
      const update: TUpdateInfo = {
        newMessage: {
          message: encodeMessageInfo(message, {
            // must encode for the user we're sending to
            currentUserId: userId,
            peerId,
          }),
        },
      }

      const updates = userId === currentUserId ? [updateMessageId, update] : [update]

      connectionManager.sendToUser(
        userId,
        createMessage({ kind: ServerMessageKind.Message, payload: { updates: updates } }),
      )
    })
  }
}

const sendPushNotificationToUser = async ({
  userId,
  title,
  message,
  currentUserId,
  chatId,
  currentUser,
}: {
  userId: number
  title: string
  message: string
  chatId: number
  currentUserId: number
  currentUser: DbUser
}) => {
  try {
    // Get all sessions for the user
    const userSessions = await SessionsModel.getActiveSessionsByUserId(userId)

    if (!userSessions.length) {
      Log.shared.debug("No active sessions found for user", { userId })
      return
    }

    for (const session of userSessions) {
      if (!session.applePushToken) continue

      let topic =
        session.clientType === "macos"
          ? isProd
            ? "chat.inline.InlineMac"
            : "chat.inline.InlineMac.debug"
          : "chat.inline.InlineIOS"

      // Configure notification
      const notification = new APN.Notification()
      notification.payload = {
        userId: currentUserId,

        from: {
          firstName: currentUser.firstName,
          lastName: currentUser.lastName,
          email: currentUser.email,
        },
      }
      notification.mutableContent = true
      notification.threadId = `chat_${chatId}`
      notification.topic = topic
      notification.alert = {
        title,
        body: message,
      }
      notification.sound = "default"

      try {
        const result = await apnProvider.send(notification, session.applePushToken)
        if (result.failed.length > 0) {
          Log.shared.error("Failed to send push notification", {
            errors: result.failed.map((f) => f.response),
            userId,
          })
        } else {
          Log.shared.debug("Push notification sent successfully", {
            userId,
          })
        }
      } catch (error) {
        Log.shared.error("Error sending push notification", {
          error,
          userId,
        })
      }
    }
  } catch (error) {
    Log.shared.error("Error sending push notification", {
      error,
      userId,
    })
  }
}

// Update the chat's last message ID
async function updateLastMessageId(chatId: number, messageId: number) {
  await db.update(chats).set({ lastMsgId: messageId }).where(eq(chats.id, chatId))
}
