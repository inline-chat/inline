import { db } from "@in/server/db"
import { desc, eq, sql, and } from "drizzle-orm"
import {
  chats,
  dialogs,
  messages,
  sessions,
  users,
  type DbChat,
  type DbFile,
  type DbMessage,
  type DbUser,
} from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import {
  encodeMessageInfo,
  TInputPeerInfo,
  TUpdate,
  TMessageInfo,
  TPeerInfo,
  type TUpdateInfo,
  Optional,
} from "@in/server/api-types"
import { createMessage, ServerMessageKind } from "@in/server/ws/protocol"
import { connectionManager } from "@in/server/ws/connections"
import { getUpdateGroup } from "@in/server/modules/updates"
import * as APN from "apn"
import type { HandlerContext } from "../controllers/helpers"
import { getApnProvider } from "../libs/apn"
import { SessionsModel } from "@in/server/db/models/sessions"
import { encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { TInputId } from "@in/server/types/methods"
import { isProd } from "@in/server/env"
import { getFileByUniqueId } from "@in/server/db/models/files"
import { debugDelay, delay } from "@in/server/utils/helpers/time"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Update } from "@in/protocol/core"
import { Encoders } from "@in/server/realtime/encoders/encoders"

export const Input = Type.Object({
  peerId: Optional(TInputPeerInfo),
  peerUserId: Optional(TInputId),
  peerThreadId: Optional(TInputId),

  text: Optional(Type.String()),
  replyToMessageId: Optional(TInputId),

  randomId: Optional(
    Type.String({
      examples: ["17654533432775"],
      title: "Random id",
      description: "Random 64bit integer assgined by client to prevent duplicate messages",
    }),
  ),

  fileUniqueId: Optional(
    Type.String({
      examples: ["INP123456789012345678901"],
      title: "File unique id",
      description: "File unique id you received from uploadFile method as a result of uploading media",
    }),
  ),
})

type Input = Static<typeof Input>

export const Response = Type.Object({
  message: TMessageInfo,
  updates: Type.Array(TUpdate),
})

type Response = Static<typeof Response>

export const handler = async (input: Input, context: HandlerContext): Promise<Response> => {
  const messageDate = new Date()

  const peerId = input.peerUserId
    ? { userId: Number(input.peerUserId) }
    : input.peerThreadId
    ? { threadId: Number(input.peerThreadId) }
    : input.peerId

  const randomId = input.randomId ? BigInt(input.randomId) : undefined
  const replyToMsgId = input.replyToMessageId ? Number(input.replyToMessageId) : undefined
  if (!peerId) {
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }

  // Delay for simulating network latency
  await debugDelay(100)

  // Get or validate chat ID from peer info
  const chatId = await getChatIdFromPeer(peerId, context)

  // Encrypt
  const encryptedText = input.text ? encryptMessage(input.text) : undefined

  // File
  let file: DbFile | undefined
  if (input.fileUniqueId) {
    file = await getFileByUniqueId(input.fileUniqueId)
    if (!file) {
      throw new InlineError(InlineError.ApiError.FILE_NOT_FOUND)
    }
    if (file.userId !== context.currentUserId) {
      throw new InlineError(InlineError.ApiError.FILE_NOT_FOUND)
    }
  }

  if (!input.text && !file) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  // Insert new message with nested select for messageId sequence
  const newMessage = await db.transaction(async (tx) => {
    // First lock the specific chat row
    const [chat] = await tx
      .select()
      .from(chats)
      .where(eq(chats.id, chatId))
      .for("update") // This locks the row
      .limit(1)

    if (!chat) {
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    const nextId = (chat.lastMsgId ?? 0) + 1

    // Insert the new message
    const [message] = await tx
      .insert(messages)
      .values({
        chatId: chatId,
        fromId: context.currentUserId,
        text: null,
        textEncrypted: encryptedText?.encrypted ?? null,
        textIv: encryptedText?.iv ?? null,
        textTag: encryptedText?.authTag ?? null,
        messageId: nextId,
        replyToMsgId: replyToMsgId ?? null,
        randomId: randomId ?? null,
        fileId: file?.id ?? null,
        date: messageDate,
      })
      .returning()

    // Update the lastMsgId
    await tx.update(chats).set({ lastMsgId: nextId }).where(eq(chats.id, chatId))

    return message
  })

  if (!newMessage) {
    Log.shared.error("Failed to send message")
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }

  const encodedMessage = encodeMessageInfo(newMessage, {
    currentUserId: context.currentUserId,
    peerId: peerId,
    files: file ? [file] : null,
  })

  sendMessageUpdate({
    message: { message: newMessage, file },
    peerId,
    currentUserId: context.currentUserId,
  })

  const currentUser = await db
    .select()
    .from(users)
    .where(eq(users.id, context.currentUserId))
    .then(([user]) => user)

  if (!currentUser) {
    // Should not happen
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }

  if (
    input.peerUserId &&
    // Don't send push notifications to self
    input.peerUserId !== context.currentUserId
  ) {
    const title: string = currentUser.firstName ?? currentUser.username ?? "New Message"
    sendPushNotificationToUser({
      userId: Number(input.peerUserId),
      title,
      chatId,
      message: input.text ?? "🖼️ Photo", // if no text, it's image for now!!!
      currentUserId: context.currentUserId,
      currentUser,
    })
  }

  const updateMessageId: TUpdateInfo = {
    updateMessageId: {
      randomId: newMessage.randomId?.toString() ?? "",
      messageId: newMessage.messageId,
    },
  }

  return { message: encodedMessage, updates: [updateMessageId] }
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
  message: { message: DbMessage; file: DbFile | undefined }
  currentUserId: number
}) => {
  const updateGroup = await getUpdateGroup(peerId, { currentUserId })

  const updateMessageId: TUpdateInfo = {
    updateMessageId: {
      randomId: message.message.randomId?.toString() ?? "",
      messageId: message.message.messageId,
    },
  }

  if (updateGroup.type === "users") {
    updateGroup.userIds.forEach((userId) => {
      let encodingForPeer: TPeerInfo = userId === currentUserId ? peerId : { userId: currentUserId }
      const update: TUpdateInfo = {
        newMessage: {
          message: encodeMessageInfo(message.message, {
            // must encode for the user we're sending to
            currentUserId: userId,
            //  customize this per user (e.g. threadId)
            peerId: encodingForPeer,
            files: message.file ? [message.file] : null,
          }),
        },
      }

      // legacy updates
      const updates = userId === currentUserId ? [updateMessageId, update] : [update]
      connectionManager.sendToUser(userId, createMessage({ kind: ServerMessageKind.Message, payload: { updates } }))

      // New updates
      let messageIdUpdate: Update = {
        update: {
          oneofKind: "updateMessageId",
          updateMessageId: {
            messageId: BigInt(message.message.messageId),
            randomId: message.message.randomId ?? 0n,
          },
        },
      }

      let newMessageUpdate: Update = {
        update: {
          oneofKind: "newMessage",
          newMessage: {
            message: Encoders.message({
              message: message.message,
              file: message.file,
              encodingForUserId: userId,
              encodingForPeer: { legacyPeer: encodingForPeer },
            }),
          },
        },
      }

      if (userId === currentUserId) {
        // current user gets the message id update and new message update
        RealtimeUpdates.pushToUser(userId, [
          // order matters here
          messageIdUpdate,
          newMessageUpdate,
        ])
      } else {
        // other users get the message only
        RealtimeUpdates.pushToUser(userId, [newMessageUpdate])
      }
    })
  } else if (updateGroup.type === "space") {
    const userIds = connectionManager.getSpaceUserIds(updateGroup.spaceId)
    Log.shared.debug(`Sending message to space ${updateGroup.spaceId}`, { userIds })
    userIds.forEach((userId) => {
      const update: TUpdateInfo = {
        newMessage: {
          message: encodeMessageInfo(message.message, {
            // must encode for the user we're sending to
            currentUserId: userId,
            peerId,
            files: message.file ? [message.file] : null,
          }),
        },
      }

      const updates = userId === currentUserId ? [updateMessageId, update] : [update]

      connectionManager.sendToUser(
        userId,
        createMessage({ kind: ServerMessageKind.Message, payload: { updates: updates } }),
      )

      // New updates
      let messageIdUpdate: Update = {
        update: {
          oneofKind: "updateMessageId",
          updateMessageId: {
            messageId: BigInt(message.message.messageId),
            randomId: message.message.randomId ?? 0n,
          },
        },
      }

      let newMessageUpdate: Update = {
        update: {
          oneofKind: "newMessage",
          newMessage: {
            message: Encoders.message({
              message: message.message,
              file: message.file,
              encodingForUserId: userId,
              encodingForPeer: { legacyPeer: peerId },
            }),
          },
        },
      }

      if (userId === currentUserId) {
        // current user gets the message id update and new message update
        RealtimeUpdates.pushToUser(userId, [
          // order matters here
          messageIdUpdate,
          newMessageUpdate,
        ])
      } else {
        // other users get the message only
        RealtimeUpdates.pushToUser(userId, [newMessageUpdate])
      }
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
    const userSessions = await SessionsModel.getValidSessionsByUserId(userId)

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
          : isProd
          ? "chat.inline.InlineIOS"
          : "chat.inline.InlineIOS.debug"

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
      notification.contentAvailable = true
      notification.mutableContent = true
      notification.topic = topic
      notification.threadId = `chat_${chatId}`
      notification.sound = "default"
      notification.alert = {
        title,
        body: message,
      }

      let apnProvider = getApnProvider()
      if (!apnProvider) {
        Log.shared.error("APN provider not found", { userId })
        continue
      }

      const sendPush = async () => {
        if (!session.applePushToken) return
        try {
          const result = await apnProvider.send(notification, session.applePushToken)
          if (result.failed.length > 0) {
            Log.shared.debug("Failed to send push notification", {
              errors: result.failed.map((f) => f.response),
              userId,
            })
          } else {
            Log.shared.debug("Push notification sent successfully", {
              userId,
            })
          }
        } catch (error) {
          Log.shared.debug("Error sending push notification", {
            error,
            userId,
          })
        }
      }

      sendPush()
    }
  } catch (error) {
    Log.shared.debug("Error sending push notification", {
      error,
      userId,
    })
  }
}

// Update the chat's last message ID
async function updateLastMessageId(chatId: number, messageId: number) {
  await db.update(chats).set({ lastMsgId: messageId }).where(eq(chats.id, chatId))
}
