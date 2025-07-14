import { InputPeer, MessageEntities, Update, UpdateNewMessageNotification_Reason } from "@in/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { FileModel, type DbFullPhoto, type DbFullVideo } from "@in/server/db/models/files"
import type { DbFullDocument } from "@in/server/db/models/files"
import { MessageModel } from "@in/server/db/models/messages"
import { type DbChat } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { getCachedUserName, UserNamesCache } from "@in/server/modules/cache/userNames"
import { decryptMessage, encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { Notifications } from "@in/server/modules/notifications/notifications"
import { getUpdateGroupFromInputPeer, type UpdateGroup } from "@in/server/modules/updates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import { processLoomLink } from "@in/server/modules/loom/processLoomLink"
import { batchEvaluate, type NotificationEvalResult } from "@in/server/modules/notifications/eval"
import { getCachedChatInfo } from "@in/server/modules/cache/chatInfo"
import { getCachedUserSettings } from "@in/server/modules/cache/userSettings"
import { UserSettingsNotificationsMode } from "@in/server/db/models/userSettings/types"
import { encryptBinary } from "@in/server/modules/encryption/encryption"
import { processMessageText } from "@in/server/modules/message/processText"
import { isUserMentioned } from "@in/server/modules/message/helpers"

type Input = {
  peerId: InputPeer
  message?: string
  replyToMessageId?: bigint
  randomId?: bigint
  photoId?: bigint
  videoId?: bigint
  documentId?: bigint
  sendDate?: number
  isSticker?: boolean
  entities?: MessageEntities

  /** whether to process markdown string */
  parseMarkdown?: boolean
}

type Output = {
  updates: Update[]
}

const log = new Log("functions.sendMessage")

export const sendMessage = async (input: Input, context: FunctionContext): Promise<Output> => {
  // input data
  const date = input.sendDate ? new Date(input.sendDate * 1000) : new Date()
  const fromId = context.currentUserId
  const inputPeer = input.peerId
  const currentUserId = context.currentUserId
  const chat = await ChatModel.getChatFromInputPeer(input.peerId, context)
  const chatId = chat.id
  const replyToMsgIdNumber = input.replyToMessageId ? Number(input.replyToMessageId) : null

  let text = input.message
  let entities = input.entities

  // Process message text
  if (input.parseMarkdown) {
    const textContent = input.message
      ? processMessageText({ text: input.message, entities: input.entities })
      : undefined
    text = textContent?.text
    entities = textContent?.entities
  }

  // Encrypt
  const encryptedMessage = text ? encryptMessage(text) : undefined

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

  // encrypt entities
  const binaryEntities = entities ? MessageEntities.toBinary(entities) : undefined
  const encryptedEntities = binaryEntities && binaryEntities.length > 0 ? encryptBinary(binaryEntities) : undefined

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
    isSticker: input.isSticker ?? false,
    entitiesEncrypted: encryptedEntities?.encrypted ?? null,
    entitiesIv: encryptedEntities?.iv ?? null,
    entitiesTag: encryptedEntities?.authTag ?? null,
  })

  // Process Loom links in the message if any
  if (text) {
    // Process Loom links in parallel with message sending
    processLoomLink(newMessage, text, BigInt(chatId), currentUserId, inputPeer)
  }

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
    chat,
    unencryptedEntities: entities,
    unencryptedText: text,
    inputPeer,
  })

  // return new updates
  return { updates: selfUpdates }
}

type EncodeMessageInput = Parameters<typeof Encoders.message>[0]
type MessageInfo = Omit<EncodeMessageInput, "encodingForUserId" | "encodingForPeer">

// ------------------------------------------------------------
// Message Encoding
// ------------------------------------------------------------

/** Encode a message for a specific user based on update group context */
const encodeMessageForUser = ({
  messageInfo,
  updateGroup,
  inputPeer,
  currentUserId,
  targetUserId,
}: {
  messageInfo: MessageInfo
  updateGroup: UpdateGroup
  inputPeer: InputPeer
  currentUserId: number
  targetUserId: number
}) => {
  let encodingForInputPeer: InputPeer

  if (updateGroup.type === "dmUsers") {
    // In DMs, encoding peer depends on whether we're encoding for current user or other user
    encodingForInputPeer =
      targetUserId === currentUserId
        ? inputPeer
        : { type: { oneofKind: "user", user: { userId: BigInt(currentUserId) } } }
  } else {
    // In threads, always use the same input peer
    encodingForInputPeer = inputPeer
  }

  return Encoders.message({
    ...messageInfo,
    encodingForPeer: { inputPeer: encodingForInputPeer },
    encodingForUserId: targetUserId,
  })
}

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

  if (updateGroup.type === "dmUsers") {
    updateGroup.userIds.forEach((userId) => {
      const encodingForUserId = userId
      const encodingForInputPeer: InputPeer =
        userId === currentUserId ? inputPeer : { type: { oneofKind: "user", user: { userId: BigInt(currentUserId) } } }

      let newMessageUpdate: Update = {
        update: {
          oneofKind: "newMessage",
          newMessage: {
            message: encodeMessageForUser({
              messageInfo,
              updateGroup,
              inputPeer,
              currentUserId,
              targetUserId: userId,
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
  } else if (updateGroup.type === "threadUsers") {
    updateGroup.userIds.forEach((userId) => {
      // New updates
      let newMessageUpdate: Update = {
        update: {
          oneofKind: "newMessage",
          newMessage: {
            message: encodeMessageForUser({
              messageInfo,
              updateGroup,
              inputPeer,
              currentUserId,
              targetUserId: userId,
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
  chat: DbChat
  unencryptedText: string | undefined
  unencryptedEntities: MessageEntities | undefined
  inputPeer: InputPeer
}

/** Send push notifications for this message */
async function sendNotifications(input: SendPushForMsgInput) {
  const { updateGroup, messageInfo, currentUserId, chat, unencryptedText, unencryptedEntities, inputPeer } = input

  // get sender of replied message ID if any
  const repliedToSenderId = messageInfo.message.replyToMsgId
    ? await MessageModel.getSenderIdForMessage({
        chatId: messageInfo.message.chatId,
        messageId: messageInfo.message.replyToMsgId,
      })
    : undefined

  // AI
  let evalResult: NotificationEvalResult | undefined

  try {
    const chatId = chat.id
    const chatInfo = await getCachedChatInfo(chatId)
    const chatInfoParticipants = chatInfo?.participantUserIds ?? []
    const participantSettings = await Promise.all(
      chatInfoParticipants.map(async (userId) => {
        const settings = await getCachedUserSettings(userId)
        return { userId, settings: settings ?? null }
      }),
    )

    log.debug("Participant settings", { participantSettings })

    const isDM = inputPeer.type.oneofKind === "user"

    // Only evaluate if any participant has set to ImportantOnly and is mentioned
    const needsAIEval = participantSettings.some((setting) => {
      let zenMode = setting.settings?.notifications.mode === UserSettingsNotificationsMode.ImportantOnly
      let isReplyToUser = setting.userId === repliedToSenderId
      let isExplicitlyMentioned = unencryptedEntities ? isUserMentioned(unencryptedEntities, setting.userId) : false
      let isMentioned = isDM || isExplicitlyMentioned || isReplyToUser

      log.debug("Evaluating notification", {
        userId: setting.userId,
        zenMode,
        isReplyToUser,
        isExplicitlyMentioned,
        isMentioned,
      })

      return zenMode && isMentioned
    })

    const hasText = !!unencryptedText

    if (needsAIEval && hasText) {
      let evalResults = await batchEvaluate({
        chatId: chatId,
        message: {
          id: messageInfo.message.messageId,
          text: unencryptedText,
          entities: unencryptedEntities ?? null,
          message: messageInfo.message,
        },
        participantSettings,
      })
      evalResult = evalResults
    }
  } catch (error) {
    log.error("Error getting chat info", { error })
  }

  // decrypt message text
  let messageText = input.unencryptedText
  let messageEntities = input.unencryptedEntities

  // TODO: send to users who have it set to All immediately
  // Handle DMs and threads
  for (let userId of updateGroup.userIds) {
    if (userId === currentUserId) {
      // Don't send push notifications to yourself
      continue
    }

    sendNotificationToUser({
      userId,
      messageInfo,
      messageText,
      messageEntities,
      repliedToSenderId,
      chat,
      evalResult,
      updateGroup,
      inputPeer,
      currentUserId,
    })
  }
}

/** Send push notifications for this message */
async function sendNotificationToUser({
  userId,
  messageInfo,
  messageText,
  messageEntities,
  repliedToSenderId,
  chat,
  evalResult,
  updateGroup,
  inputPeer,
  currentUserId,
}: {
  userId: number
  messageInfo: MessageInfo
  messageText: string | undefined
  messageEntities: MessageEntities | undefined
  repliedToSenderId: number | undefined
  chat?: DbChat
  evalResult?: NotificationEvalResult
  // For explicit mac notification
  updateGroup: UpdateGroup
  inputPeer: InputPeer
  currentUserId: number
}) {
  // FIRST, check if we should notify this user or not ---------------------------------
  let needsExplicitMacNotification = false
  let reason = UpdateNewMessageNotification_Reason.UNSPECIFIED
  let userSettings = await getCachedUserSettings(userId)
  if (userSettings?.notifications.mode === UserSettingsNotificationsMode.None) {
    // Do not notify
    return
  }

  // TODO: evaluate reply to a user as a mention
  const isDM = inputPeer.type.oneofKind === "user"
  const isReplyToUser = repliedToSenderId === userId
  const isExplicitlyMentioned = messageEntities ? isUserMentioned(messageEntities, userId) : false
  const isMentioned = isDM || isExplicitlyMentioned || isReplyToUser
  const requiresNotification = evalResult?.notifyUserIds?.includes(userId)

  // Mentions
  if (userSettings?.notifications.mode === UserSettingsNotificationsMode.Mentions) {
    if (
      // Not mentioned
      !isMentioned &&
      // Not notified
      !requiresNotification &&
      // Not DMs - always send for DMs if it's set to "Mentions"
      !isDM
    ) {
      // Do not notify
      return
    }
    needsExplicitMacNotification = true
    reason = UpdateNewMessageNotification_Reason.MENTION
  }

  // Important only
  if (userSettings?.notifications.mode === UserSettingsNotificationsMode.ImportantOnly) {
    if (!isMentioned || !requiresNotification) {
      // Do not notify
      return
    }
    needsExplicitMacNotification = true
    reason = UpdateNewMessageNotification_Reason.IMPORTANT
  }

  // THEN, send notification ------------------------------------------------------------

  const userName = await getCachedUserName(messageInfo.message.fromId)

  if (!userName) {
    Log.shared.warn("No user name found for user", { userId })
    return
  }

  let title = "Message"
  let body = "New message" // default

  let includeSenderNameInMessage = false
  const senderName = UserNamesCache.getDisplayName(userName)
  // Only provide chat title for threads not DMs
  const chatTitle = chat?.type === "thread" ? chat.title ?? undefined : undefined

  if (chatTitle) {
    // If thread
    title = chatTitle
  } else if (senderName) {
    // If DM
    includeSenderNameInMessage = true
    title = senderName
  } else {
    // If no sender name, use default
    title = "Message"
  }

  if (messageText) {
    // if has text, use text
    body = messageText.substring(0, 240)
  } else if (messageInfo.message.isSticker) {
    body = "🖼️ Sticker"
  } else if (messageInfo.message.mediaType === "photo") {
    body = "🖼️ Photo"
  } else if (messageInfo.message.mediaType === "video") {
    body = "🎥 Video"
  } else if (messageInfo.message.mediaType === "document") {
    body = "📄 File"
  }

  if (includeSenderNameInMessage) {
    body = `${senderName}: ${body}`
  }

  Notifications.sendToUser({
    userId,
    senderUserId: messageInfo.message.fromId,
    threadId: `chat_${messageInfo.message.chatId}`,
    isThread: chat?.type == "thread",
    title,
    body,
  })

  if (needsExplicitMacNotification) {
    RealtimeUpdates.pushToUser(userId, [
      {
        update: {
          oneofKind: "newMessageNotification",
          newMessageNotification: {
            message: encodeMessageForUser({
              messageInfo,
              updateGroup,
              inputPeer,
              currentUserId,
              targetUserId: userId,
            }),
            reason: reason,
          },
        },
      },
    ])
  }
}
