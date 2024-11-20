import { db } from "@in/server/db"
import { desc, eq, sql, and } from "drizzle-orm"
import { chats, dialogs, messages, sessions, type DbChat, type DbMessage } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { Optional, type Static, Type } from "@sinclair/typebox"
import { encodeMessageInfo, TInputPeerInfo, TMessageInfo, TPeerInfo, type TUpdateInfo } from "@in/server/models"
import { createMessage, ServerMessageKind } from "@in/server/ws/protocol"
import { connectionManager } from "@in/server/ws/connections"
import { getUpdateGroup } from "@in/server/utils/updates"
import * as APN from "apn"
import type { HandlerContext } from "../controllers/v1/helpers"

export const Input = Type.Object({
  peerId: Optional(TInputPeerInfo),
  text: Type.String(),

  peerUserId: Optional(Type.String()),
  peerThreadId: Optional(Type.String()),
})

type Input = Static<typeof Input>

// type Context = {
//   currentUserId: number
//   currentSessionId: number
// }

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
      message: newMessage,
      peerId,
      currentUserId: context.currentUserId,
    })

    sendPushNotification({
      userId: Number(input.peerUserId) ?? 0,
      title: "New Message",
      message: input.text,
      sessionId: context.currentSessionId,
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

      connectionManager.sendToUser(
        userId,
        createMessage({ kind: ServerMessageKind.Message, payload: { updates: [update] } }),
      )
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

      connectionManager.sendToUser(
        userId,
        createMessage({ kind: ServerMessageKind.Message, payload: { updates: [update] } }),
      )
    })
  }
}

const sendPushNotification = async ({
  userId,
  title,
  message,
  sessionId,
}: {
  userId: number
  title: string
  message: string
  sessionId: number
}) => {
  try {
    const [userSession] = await db.select().from(sessions).where(eq(sessions.id, sessionId))

    if (!userSession?.applePushToken) {
      return
    }

    // Configure APN provider
    const apnProvider = new APN.Provider({
      token: {
        key: process.env["APN_KEY_PATH"] ?? "",
        keyId: process.env["APN_KEY_ID"] ?? "",
        teamId: process.env["APN_TEAM_ID"] ?? "",
      },
      production: process.env["NODE_ENV"] === "production",
    })

    // Configure notification
    const notification = new APN.Notification({
      alert: {
        title,
        body: message,
      },
      topic: "chat.inline.InlineIOS",
      pushType: "alert",
      sound: "default",
    })

    // Send notification
    const result = await apnProvider.send(notification, userSession.applePushToken)

    if (result.failed.length > 0) {
      Log.shared.error("Failed to send push notification", {
        error: result.failed[0]?.response,
        userId,
        applePushToken: userSession.applePushToken,
      })
    }

    // Shutdown provider
    apnProvider.shutdown()
  } catch (error) {
    Log.shared.error("Error sending push notification", {
      error,
      userId,
    })
  }
}
