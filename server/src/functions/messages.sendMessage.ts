import { InputPeer, Update } from "@in/protocol/core"
import type { TPeerInfo } from "@in/server/api-types"
import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { FileModel, type DbFullPhoto, type DbFullVideo } from "@in/server/db/models/files"
import type { DbFullDocument } from "@in/server/db/models/files"
import { MessageModel } from "@in/server/db/models/messages"
import { users, type DbMessage } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { getCachedUserName } from "@in/server/modules/cache/userNames"
import { decryptMessage, encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { Notifications } from "@in/server/modules/notifications/notifications"
import { getUpdateGroupFromInputPeer, type UpdateGroup } from "@in/server/modules/updates"
import { Updates } from "@in/server/modules/updates/updates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import { connectionManager } from "@in/server/ws/connections"
import { and, eq } from "drizzle-orm"

type Input = {
  peerId: InputPeer
  message?: string
  replyToMessageId?: bigint
  randomId?: bigint
  photoId?: bigint
  videoId?: bigint
  documentId?: bigint
}

type Output = {
  updates: Update[]
}

const log = new Log("functions.sendMessage")

export const sendMessage = async (input: Input, context: FunctionContext): Promise<Output> => {
  // input data
  const date = new Date()
  const fromId = context.currentUserId
  const inputPeer = input.peerId
  const currentUserId = context.currentUserId
  const chatId = await ChatModel.getChatIdFromInputPeer(input.peerId, context)
  const replyToMsgIdNumber = input.replyToMessageId ? Number(input.replyToMessageId) : null

  // encrypt
  const encryptedMessage = input.message ? encryptMessage(input.message) : undefined

  // photo, video, document ids
  let dbFullPhoto: DbFullPhoto | undefined
  let dbFullVideo: DbFullVideo | undefined
  let dbFullDocument: DbFullDocument | undefined
  let mediaType: "photo" | "video" | "document" | null = null

  if (input.photoId) {
    dbFullPhoto = await FileModel.getPhotoById(input.photoId)
    mediaType = "photo"
  } else if (input.videoId) {
    dbFullVideo = await FileModel.getVideoById(input.videoId)
    mediaType = "video"
  } else if (input.documentId) {
    dbFullDocument = await FileModel.getDocumentById(input.documentId)
    mediaType = "document"
  }

  // insert new msg with new ID
  const newMessage = await MessageModel.insertMessage({
    chatId: chatId,
    fromId: fromId,
    textEncrypted: encryptedMessage?.encrypted ?? null,
    textIv: encryptedMessage?.iv ?? null,
    textTag: encryptedMessage?.authTag ?? null,
    replyToMsgId: replyToMsgIdNumber,
    randomId: input.randomId,
    date: date,
    mediaType: mediaType,
    photoId: dbFullPhoto?.id ?? null,
    videoId: dbFullVideo?.id ?? null,
    documentId: dbFullDocument?.id ?? null,
  })

  // encode message info
  const messageInfo: MessageInfo = {
    message: newMessage,
    photo: dbFullPhoto,
    video: dbFullVideo,
    document: dbFullDocument,
  }

  // send new updates
  let { selfUpdates, updateGroup } = await pushUpdates({ inputPeer, messageInfo, currentUserId })

  // send notification
  sendNotifications({
    updateGroup,
    messageInfo,
    currentUserId,
  })

  // return new updates
  return { updates: selfUpdates }
}

type EncodeMessageInput = Parameters<typeof Encoders.message>[0]
type MessageInfo = Omit<EncodeMessageInput, "encodingForUserId" | "encodingForPeer">

// ------------------------------------------------------------
// Updates
// ------------------------------------------------------------

/** Push updates for send messages */
const pushUpdates = async ({
  inputPeer,
  messageInfo,
  currentUserId,
}: {
  inputPeer: InputPeer
  messageInfo: MessageInfo
  currentUserId: number
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> => {
  const updateGroup = await getUpdateGroupFromInputPeer(inputPeer, { currentUserId })

  let messageIdUpdate: Update = {
    update: {
      oneofKind: "updateMessageId",
      updateMessageId: {
        messageId: BigInt(messageInfo.message.messageId),
        randomId: messageInfo.message.randomId ?? 0n,
      },
    },
  }

  let selfUpdates: Update[] = []

  if (updateGroup.type === "users") {
    updateGroup.userIds.forEach((userId) => {
      const encodingForUserId = userId
      const encodingForInputPeer: InputPeer =
        userId === currentUserId ? inputPeer : { type: { oneofKind: "user", user: { userId: BigInt(currentUserId) } } }

      let newMessageUpdate: Update = {
        update: {
          oneofKind: "newMessage",
          newMessage: {
            message: Encoders.message({
              ...messageInfo,
              encodingForPeer: { inputPeer: encodingForInputPeer },
              encodingForUserId,
            }),
          },
        },
      }

      Log.shared.info(
        `encodingForInputPeer: ${JSON.stringify(
          InputPeer.toJson(encodingForInputPeer),
        )}, encodingForUserId: ${encodingForUserId}, and update is ${JSON.stringify(Update.toJson(newMessageUpdate))}`,
      )

      if (userId === currentUserId) {
        // current user gets the message id update and new message update
        RealtimeUpdates.pushToUser(userId, [
          // order matters here
          messageIdUpdate,
          newMessageUpdate,
        ])
        selfUpdates = [
          // order matters here
          messageIdUpdate,
          newMessageUpdate,
        ]
      } else {
        // other users get the message only
        RealtimeUpdates.pushToUser(userId, [newMessageUpdate])
      }
    })
  } else if (updateGroup.type === "space") {
    const userIds = connectionManager.getSpaceUserIds(updateGroup.spaceId)
    log.debug(`Sending message to space ${updateGroup.spaceId}`, { userIds })
    userIds.forEach((userId) => {
      // New updates
      let newMessageUpdate: Update = {
        update: {
          oneofKind: "newMessage",
          newMessage: {
            message: Encoders.message({
              ...messageInfo,
              encodingForPeer: { inputPeer },
              encodingForUserId: userId,
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
        selfUpdates = [
          // order matters here
          messageIdUpdate,
          newMessageUpdate,
        ]
      } else {
        // other users get the message only
        RealtimeUpdates.pushToUser(userId, [newMessageUpdate])
      }
    })
  }

  return { selfUpdates, updateGroup }
}

// ------------------------------------------------------------
// Push notifications
// ------------------------------------------------------------

type SendPushForMsgInput = {
  updateGroup: UpdateGroup
  messageInfo: MessageInfo
  currentUserId: number
}

/** Send push notifications for this message */
async function sendNotifications(input: SendPushForMsgInput) {
  const { updateGroup, messageInfo, currentUserId } = input

  // decrypt message text
  let messageText = ""
  if (messageInfo.message.textEncrypted && messageInfo.message.textIv && messageInfo.message.textTag) {
    messageText = decryptMessage({
      encrypted: messageInfo.message.textEncrypted,
      iv: messageInfo.message.textIv,
      authTag: messageInfo.message.textTag,
    })
  }

  if (updateGroup.type === "users") {
    for (let userId of updateGroup.userIds) {
      if (userId === currentUserId) {
        // Don't send push notifications to yourself
        continue
      }

      sendNotificationToUser({ userId, messageInfo, messageText })
    }
  }

  // TODO: handle update for space
}

/** Send push notifications for this message */
async function sendNotificationToUser({
  userId,
  messageInfo,
  messageText,
}: {
  userId: number
  messageInfo: MessageInfo
  messageText: string
}) {
  const userName = await getCachedUserName(messageInfo.message.fromId)

  if (!userName) {
    Log.shared.debug("No user name found for user", { userId })
    return
  }

  const title = userName.firstName ? `${userName.firstName}` : userName.username ?? "Message"
  let body = "New message" // default

  if (messageText) {
    // if has text, use text
    body = messageText.substring(0, 240)
  } else if (messageInfo.message.mediaType === "photo") {
    body = "🖼️ Photo"
  } else if (messageInfo.message.mediaType === "video") {
    body = "🎥 Video"
  } else if (messageInfo.message.mediaType === "document") {
    body = "📄 File"
  }

  Notifications.sendToUser({ userId, threadId: `chat_${messageInfo.message.chatId}`, title, body })
}
