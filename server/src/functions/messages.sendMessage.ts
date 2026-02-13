import {
  InputPeer,
  MessageAttachment,
  MessageEntities,
  type MessageEntity,
  MessageEntity_Type,
  MessageSendMode,
  Update,
  UpdateNewMessageNotification_Reason,
} from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { FileModel, type DbFullPhoto, type DbFullVideo } from "@in/server/db/models/files"
import type { DbFullDocument } from "@in/server/db/models/files"
import { MessageModel } from "@in/server/db/models/messages"
import { db } from "@in/server/db"
import { lower, messageAttachments, users, type DbChat, type DbMessage } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { getCachedUserName, UserNamesCache, type UserName } from "@in/server/modules/cache/userNames"
import { decryptMessage, encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { Notifications } from "@in/server/modules/notifications/notifications"
import { getUpdateGroupFromInputPeer, type UpdateGroup } from "@in/server/modules/updates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeMessageAttachmentUpdate } from "@in/server/realtime/encoders/encodeMessageAttachment"
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
import { detectHasLink } from "@in/server/modules/message/linkDetection"
import type { UpdateSeqAndDate } from "@in/server/db/models/updates"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { debugDelay } from "@in/server/utils/helpers/time"
import { connectionManager } from "@in/server/ws/connections"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { getCachedUserProfilePhotoUrl } from "@in/server/modules/cache/userPhotos"
import { processAttachments } from "@in/server/db/models/messages"
import { eq, inArray } from "drizzle-orm"
import { unarchiveIfNeeded } from "@in/server/modules/message/unarchiveIfNeeded"

type Input = {
  peerId: InputPeer
  message?: string
  replyToMessageId?: bigint
  randomId?: bigint
  photoId?: bigint
  videoId?: bigint
  documentId?: bigint
  nudge?: boolean
  sendDate?: number
  isSticker?: boolean
  entities?: MessageEntities
  sendMode?: MessageSendMode
  forwardHeader?: {
    fromPeerId: InputPeer
    fromId: number
    fromMessageId: number
  }
  messageAttachments?: { externalTaskId?: bigint; urlPreviewId?: bigint }[]

  /** whether to process markdown string */
  parseMarkdown?: boolean

  /** skip processing links into attachments */
  skipLinkProcessing?: boolean
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
  try {
    await AccessGuards.ensureChatAccess(chat, currentUserId)
  } catch (error) {
    log.error("sendMessage blocked: chat access denied", { chatId: chat.id, currentUserId, inputPeer, error })
    throw error
  }
  const chatId = chat.id
  const replyToMsgIdNumber = input.replyToMessageId ? Number(input.replyToMessageId) : null
  // FIXME: create a helper function to get the layer
  const currentUserLayer = connectionManager.getConnectionBySession(currentUserId, context.currentSessionId)?.layer ?? 0

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

  entities = await parseMissingMentionEntitiesByUsername({
    text,
    entities,
  })

  const hasLink =
    detectHasLink({ entities }) ||
    (input.messageAttachments?.some((attachment) => attachment.urlPreviewId != null) ?? false)

  // Encrypt
  const encryptedMessage = text ? encryptMessage(text) : undefined

  // photo, video, document ids
  let dbFullPhoto: DbFullPhoto | undefined
  let dbFullVideo: DbFullVideo | undefined
  let dbFullDocument: DbFullDocument | undefined
  let mediaType: "photo" | "video" | "document" | "nudge" | null = null

  if (input.nudge) {
    mediaType = "nudge"
  } else if (input.photoId) {
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

  let fwdFromPeerUserId: number | null = null
  let fwdFromPeerChatId: number | null = null
  let fwdFromMessageId: number | null = null
  let fwdFromSenderId: number | null = null

  if (input.forwardHeader) {
    const forwardPeer = input.forwardHeader.fromPeerId.type
    switch (forwardPeer.oneofKind) {
      case "user":
        fwdFromPeerUserId = Number(forwardPeer.user.userId)
        break
      case "chat":
        fwdFromPeerChatId = Number(forwardPeer.chat.chatId)
        break
      case "self":
        fwdFromPeerUserId = currentUserId
        break
      default:
        break
    }

    fwdFromMessageId = Number(input.forwardHeader.fromMessageId)
    fwdFromSenderId = Number(input.forwardHeader.fromId)
  }

  let newMessage: DbMessage
  let update: UpdateSeqAndDate
  try {
    // insert new msg with new ID
    ;({ message: newMessage, update } = await MessageModel.insertMessage({
      chatId: chatId,
      fromId: fromId,
      textEncrypted: encryptedMessage?.encrypted ?? null,
      textIv: encryptedMessage?.iv ?? null,
      textTag: encryptedMessage?.authTag ?? null,
      replyToMsgId: replyToMsgIdNumber,
      fwdFromPeerUserId: fwdFromPeerUserId,
      fwdFromPeerChatId: fwdFromPeerChatId,
      fwdFromMessageId: fwdFromMessageId,
      fwdFromSenderId: fwdFromSenderId,
      randomId: input.randomId,
      date: date,
      mediaType: mediaType,
      photoId: dbFullPhoto?.id ?? null,
      videoId: dbFullVideo?.id ?? null,
      documentId: dbFullDocument?.id ?? null,
      isSticker: input.isSticker ?? false,
      hasLink: hasLink,
      entitiesEncrypted: encryptedEntities?.encrypted ?? null,
      entitiesIv: encryptedEntities?.iv ?? null,
      entitiesTag: encryptedEntities?.authTag ?? null,
    }))
  } catch (error) {
    if (error instanceof Error && error.message.includes("random_id_per_sender_unique") && input.randomId) {
      log.error(error, "duplicate random id, fetching message from database to recover")

      // Just fetch the message from the database
      return { updates: await selfUpdatesFromExistingMessage(input.randomId, currentUserId) }
    } else {
      log.error("error inserting message", error)
      throw RealtimeRpcError.InternalError()
    }
  }

  if (input.messageAttachments && input.messageAttachments.length > 0) {
    const attachmentRows = input.messageAttachments
      .map((attachment) => ({
        messageId: newMessage.globalId,
        externalTaskId: attachment.externalTaskId ?? null,
        urlPreviewId: attachment.urlPreviewId ?? null,
      }))
      .filter((attachment) => attachment.externalTaskId !== null || attachment.urlPreviewId !== null)

    if (attachmentRows.length > 0) {
      await db.insert(messageAttachments).values(attachmentRows)
    }
  }

  // Process Loom links in the message if any
  if (text && !input.skipLinkProcessing) {
    // Process Loom links in parallel with message sending
    processLoomLink(newMessage, text, BigInt(chatId), currentUserId, inputPeer)
  }

  // encode message info
  const messageInfo: MessageInfo = {
    message: newMessage,
    photo: dbFullPhoto,
    video: dbFullVideo,
    document: dbFullDocument,
    sendMode: input.sendMode,
  }

  //await debugDelay(5000)

  const hasAttachments =
    messageInfo.photo !== undefined || messageInfo.video !== undefined || messageInfo.document !== undefined

  // send new updates
  // TODO: need to create the update, use the sequence number
  // we probably need to create the update and message in one transaction
  // to avoid multiple times locking the chat row for last message and pts.
  // we can also separate the sequence caching. this will speed up and
  // remove the need to lock the chat row. then we should deliver the update
  // with sequence number so we can ensure gap-free delivery.
  const updateGroup = await getUpdateGroupFromInputPeer(inputPeer, { currentUserId })
  const { updates: unarchiveUpdates } = await unarchiveIfNeeded({
    chat,
    updateGroup,
    senderUserId: currentUserId,
  })

  unarchiveUpdates.forEach(({ userId, update }) => {
    RealtimeUpdates.pushToUser(userId, [update])
  })

  let { selfUpdates } = await pushUpdates({
    inputPeer,
    messageInfo,
    currentUserId,
    update,
    currentSessionId: context.currentSessionId,
    publishToSelfSession: currentUserLayer < 2 || hasAttachments,
    updateGroup,
  })

  // send notification
  sendNotifications({
    updateGroup,
    messageInfo,
    currentUserId,
    chat,
    unencryptedEntities: entities,
    unencryptedText: text,
    inputPeer,
    sendMode: input.sendMode,
  })

  if (input.messageAttachments && input.messageAttachments.length > 0) {
    try {
      const attachmentUpdates = await buildAttachmentUpdates({
        message: newMessage,
        chatId,
        inputPeer,
        currentUserId,
        updateGroup,
      })
      if (attachmentUpdates.length > 0) {
        selfUpdates.push(...attachmentUpdates)
      }
    } catch (error) {
      log.error("Failed to push message attachment updates", {
        error,
        chatId,
        messageId: newMessage.messageId,
      })
    }
  }

  // return new updates
  return { updates: selfUpdates }
}

type MentionCandidate = {
  offset: number
  length: number
  username: string
}

const isMentionChar = (char: string): boolean => {
  const code = char.charCodeAt(0)
  return (
    (code >= 48 && code <= 57) || // 0-9
    (code >= 65 && code <= 90) || // A-Z
    (code >= 97 && code <= 122) || // a-z
    code === 95 // _
  )
}

const extractMentionCandidates = (text: string): MentionCandidate[] => {
  const candidates: MentionCandidate[] = []

  for (let i = 0; i < text.length; i++) {
    if (text[i] !== "@") {
      continue
    }

    if (i > 0 && isMentionChar(text[i - 1]!)) {
      // Skip things like email addresses (foo@bar.com)
      continue
    }

    let end = i + 1
    while (end < text.length && isMentionChar(text[end]!)) {
      end += 1
    }

    const username = text.slice(i + 1, end)
    if (username.length < 2) {
      continue
    }

    candidates.push({
      offset: i,
      length: end - i,
      username,
    })

    i = end - 1
  }

  return candidates
}

const getClientEntityRanges = (entities: MessageEntities | undefined): Array<{ start: number; end: number }> => {
  if (!entities || entities.entities.length === 0) {
    return []
  }

  return entities.entities
    .filter((entity): entity is MessageEntity => entity !== undefined)
    .map((entity) => {
      const start = Number(entity.offset)
      const end = Number(entity.offset + entity.length)
      return { start, end }
    })
}

const isRangeOverlappingClientEntity = (
  range: { start: number; end: number },
  clientEntityRanges: Array<{ start: number; end: number }>,
): boolean => {
  return clientEntityRanges.some((clientRange) => {
    return range.start < clientRange.end && clientRange.start < range.end
  })
}

const parseMissingMentionEntitiesByUsername = async ({
  text,
  entities,
}: {
  text: string | undefined
  entities: MessageEntities | undefined
}): Promise<MessageEntities | undefined> => {
  if (!text || !text.includes("@")) {
    return entities
  }

  const mentionCandidates = extractMentionCandidates(text)
  if (mentionCandidates.length === 0) {
    return entities
  }

  const clientEntityRanges = getClientEntityRanges(entities)

  const unresolvedMentionCandidates = mentionCandidates.filter((candidate) => {
    return !isRangeOverlappingClientEntity(
      { start: candidate.offset, end: candidate.offset + candidate.length },
      clientEntityRanges,
    )
  })

  if (unresolvedMentionCandidates.length === 0) {
    return entities
  }

  const normalizedUsernames = [...new Set(unresolvedMentionCandidates.map((candidate) => candidate.username.toLowerCase()))]
  if (normalizedUsernames.length === 0) {
    return entities
  }

  const matchedUsers = await db
    .select({
      id: users.id,
      username: users.username,
    })
    .from(users)
    .where(inArray(lower(users.username), normalizedUsernames))

  if (matchedUsers.length === 0) {
    return entities
  }

  const userIdByUsername = new Map<string, number>()
  for (const matchedUser of matchedUsers) {
    if (!matchedUser.username) {
      continue
    }
    userIdByUsername.set(matchedUser.username.toLowerCase(), matchedUser.id)
  }

  const parsedMentionEntities: MessageEntity[] = []
  for (const candidate of unresolvedMentionCandidates) {
    const userId = userIdByUsername.get(candidate.username.toLowerCase())
    if (!userId) {
      continue
    }

    parsedMentionEntities.push({
      type: MessageEntity_Type.MENTION,
      offset: BigInt(candidate.offset),
      length: BigInt(candidate.length),
      entity: {
        oneofKind: "mention",
        mention: {
          userId: BigInt(userId),
        },
      },
    })
  }

  if (parsedMentionEntities.length === 0) {
    return entities
  }

  const existingEntities = (entities?.entities ?? []).filter((entity): entity is MessageEntity => entity !== undefined)
  const combinedEntities = [...existingEntities, ...parsedMentionEntities]
  combinedEntities.sort((a, b) => {
    if (a.offset === b.offset) {
      if (a.length === b.length) {
        return 0
      }
      return a.length < b.length ? -1 : 1
    }
    return a.offset < b.offset ? -1 : 1
  })

  return {
    entities: combinedEntities,
  }
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
  update,
  publishToSelfSession,
  currentSessionId,
  updateGroup,
}: {
  inputPeer: InputPeer
  messageInfo: MessageInfo
  currentUserId: number
  update: UpdateSeqAndDate
  currentSessionId: number
  publishToSelfSession: boolean
  updateGroup?: UpdateGroup
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> => {
  const resolvedUpdateGroup = updateGroup ?? (await getUpdateGroupFromInputPeer(inputPeer, { currentUserId }))
  const skipSessionId = publishToSelfSession ? undefined : currentSessionId

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

  if (resolvedUpdateGroup.type === "dmUsers") {
    resolvedUpdateGroup.userIds.forEach((userId) => {
      const encodingForUserId = userId
      const encodingForInputPeer: InputPeer =
        userId === currentUserId ? inputPeer : { type: { oneofKind: "user", user: { userId: BigInt(currentUserId) } } }

      let newMessageUpdate: Update = {
        update: {
          oneofKind: "newMessage",
          newMessage: {
            message: encodeMessageForUser({
              messageInfo,
              updateGroup: resolvedUpdateGroup,
              inputPeer,
              currentUserId,
              targetUserId: userId,
            }),
          },
        },
        seq: update.seq,
        date: encodeDateStrict(update.date),
      }

      if (userId === currentUserId) {
        // current user gets the message id update and new message update
        RealtimeUpdates.pushToUser(
          userId,
          [
            // order matters here
            messageIdUpdate,
            newMessageUpdate,
          ],
          { skipSessionId },
        )

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
  } else if (resolvedUpdateGroup.type === "threadUsers") {
    resolvedUpdateGroup.userIds.forEach((userId) => {
      // New updates
      let newMessageUpdate: Update = {
        update: {
          oneofKind: "newMessage",
          newMessage: {
            message: encodeMessageForUser({
              messageInfo,
              updateGroup: resolvedUpdateGroup,
              inputPeer,
              currentUserId,
              targetUserId: userId,
            }),
          },
        },
        seq: update.seq,
        date: encodeDateStrict(update.date),
      }

      if (userId === currentUserId) {
        // current user gets the message id update and new message update
        RealtimeUpdates.pushToUser(
          userId,
          [
            // order matters here
            messageIdUpdate,
            newMessageUpdate,
          ],
          { skipSessionId },
        )

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

  return { selfUpdates, updateGroup: resolvedUpdateGroup }
}

const buildAttachmentUpdates = async ({
  message,
  chatId,
  inputPeer,
  currentUserId,
  updateGroup,
}: {
  message: DbMessage
  chatId: number
  inputPeer: InputPeer
  currentUserId: number
  updateGroup: UpdateGroup
}): Promise<Update[]> => {
  const attachments = await db._query.messageAttachments.findMany({
    where: eq(messageAttachments.messageId, message.globalId),
    with: {
      externalTask: true,
      linkEmbed: {
        with: {
          photo: {
            with: {
              photoSizes: {
                with: {
                  file: true,
                },
              },
            },
          },
        },
      },
    },
  })

  if (attachments.length === 0) {
    return []
  }

  const processed = processAttachments(attachments)
  const selfUpdates: Update[] = []

  const updateForUser = (userId: number, attachment: MessageAttachment): Update => {
    const encodingForInputPeer: InputPeer =
      updateGroup.type === "dmUsers" && userId !== currentUserId
        ? { type: { oneofKind: "user", user: { userId: BigInt(currentUserId) } } }
        : inputPeer

    return encodeMessageAttachmentUpdate({
      messageId: BigInt(message.messageId),
      chatId: BigInt(chatId),
      encodingForUserId: userId,
      encodingForPeer: { inputPeer: encodingForInputPeer },
      attachment,
    })
  }

  const buildAttachment = (attachment: ReturnType<typeof processAttachments>[number]): MessageAttachment | null => {
    if (!attachment.linkEmbed) {
      return null
    }

    const photo = attachment.linkEmbed.photo ? Encoders.photo({ photo: attachment.linkEmbed.photo }) : undefined

    return {
      id: BigInt(attachment.id ?? 0),
      attachment: {
        oneofKind: "urlPreview",
        urlPreview: {
          id: BigInt(attachment.linkEmbed.id),
          url: attachment.linkEmbed.url ?? undefined,
          siteName: attachment.linkEmbed.siteName ?? undefined,
          title: attachment.linkEmbed.title ?? undefined,
          description: attachment.linkEmbed.description ?? undefined,
          photo,
          duration: attachment.linkEmbed.duration == null ? undefined : BigInt(attachment.linkEmbed.duration),
        },
      },
    }
  }

  const attachmentUpdates = processed
    .map(buildAttachment)
    .filter((attachment): attachment is MessageAttachment => attachment !== null)

  if (attachmentUpdates.length === 0) {
    return []
  }

  const publishUpdate = (userId: number, update: Update) => {
    if (userId === currentUserId) {
      selfUpdates.push(update)
    } else {
      RealtimeUpdates.pushToUser(userId, [update])
    }
  }

  if (updateGroup.type === "dmUsers") {
    updateGroup.userIds.forEach((userId) => {
      attachmentUpdates.forEach((attachment) => {
        publishUpdate(userId, updateForUser(userId, attachment))
      })
    })
  } else if (updateGroup.type === "threadUsers") {
    updateGroup.userIds.forEach((userId) => {
      attachmentUpdates.forEach((attachment) => {
        publishUpdate(userId, updateForUser(userId, attachment))
      })
    })
  } else if (updateGroup.type === "spaceUsers") {
    const userIds = connectionManager.getSpaceUserIds(updateGroup.spaceId)
    userIds.forEach((userId) => {
      attachmentUpdates.forEach((attachment) => {
        publishUpdate(userId, updateForUser(userId, attachment))
      })
    })
  }

  return selfUpdates
}

async function selfUpdatesFromExistingMessage(randomId: bigint, currentUserId: number): Promise<Update[]> {
  const message = await MessageModel.getMessageByRandomId(randomId, currentUserId)
  return [
    {
      update: {
        oneofKind: "updateMessageId",
        updateMessageId: { messageId: BigInt(message.messageId), randomId: randomId },
      },
    },

    // Note(@mo): No need for this, this will be fetched by the sync engine once it detects missing PTS
    // Moreover we don't have access to the exact update caused by this message
    // so we can't send it to the user.
    // {
    //   update: {
    //     oneofKind: "newMessage",
  ]
}

// ------------------------------------------------------------
// Push notifications
// ------------------------------------------------------------

const isNudgeMessage = ({ messageInfo }: { messageInfo: MessageInfo }): boolean =>
  messageInfo.message.mediaType === "nudge"

type SendPushForMsgInput = {
  updateGroup: UpdateGroup
  messageInfo: MessageInfo
  currentUserId: number
  chat: DbChat
  unencryptedText: string | undefined
  unencryptedEntities: MessageEntities | undefined
  inputPeer: InputPeer
  sendMode?: MessageSendMode
}

/** Send push notifications for this message */
async function sendNotifications(input: SendPushForMsgInput) {
  if (input.sendMode === MessageSendMode.MODE_SILENT) {
    return
  }

  const { updateGroup, messageInfo, currentUserId, chat, unencryptedText, unencryptedEntities, inputPeer } = input
  const isNudge = isNudgeMessage({ messageInfo })
  const trimmedText = unencryptedText?.trim()
  const isUrgentNudge = isNudge && trimmedText === "🚨"

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

    if (needsAIEval && hasText && !isNudge) {
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

  const senderNameInfo = await getCachedUserName(messageInfo.message.fromId)
  const senderProfilePhotoUrl = await getCachedUserProfilePhotoUrl(messageInfo.message.fromId)

  // TODO: send to users who have it set to All immediately
  // Handle DMs and threads
  for (let userId of updateGroup.userIds) {
    if (userId === currentUserId) {
      // Don't send push notifications to yourself.
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
      isNudge,
      isUrgentNudge,
      updateGroup,
      inputPeer,
      currentUserId,
      senderNameInfo,
      senderProfilePhotoUrl,
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
  isNudge,
  isUrgentNudge,
  updateGroup,
  inputPeer,
  currentUserId,
  senderNameInfo,
  senderProfilePhotoUrl,
}: {
  userId: number
  messageInfo: MessageInfo
  messageText: string | undefined
  messageEntities: MessageEntities | undefined
  repliedToSenderId: number | undefined
  chat?: DbChat
  evalResult?: NotificationEvalResult
  isNudge: boolean
  isUrgentNudge: boolean
  // For explicit mac notification
  updateGroup: UpdateGroup
  inputPeer: InputPeer
  currentUserId: number
  senderNameInfo?: UserName
  senderProfilePhotoUrl?: string
}) {
  // FIRST, check if we should notify this user or not ---------------------------------
  let needsExplicitMacNotification = false
  let reason = UpdateNewMessageNotification_Reason.UNSPECIFIED
  let userSettings = await getCachedUserSettings(userId)
  const rawMode = userSettings?.notifications.mode
  const legacyOnlyMentions =
    rawMode === UserSettingsNotificationsMode.OnlyMentions ||
    (rawMode === UserSettingsNotificationsMode.Mentions && userSettings?.notifications.disableDmNotifications)
  const effectiveMode = legacyOnlyMentions ? UserSettingsNotificationsMode.OnlyMentions : rawMode

  if (effectiveMode === UserSettingsNotificationsMode.None && !isUrgentNudge) {
    // Do not notify
    return
  }

  // TODO: evaluate reply to a user as a mention
  const isDM = inputPeer.type.oneofKind === "user"
  const isReplyToUser = repliedToSenderId === userId
  const isExplicitlyMentioned = messageEntities ? isUserMentioned(messageEntities, userId) : false

  if (
    isDM &&
    effectiveMode === UserSettingsNotificationsMode.OnlyMentions &&
    !isNudge &&
    !isExplicitlyMentioned
  ) {
    return
  }

  const countsDmAsMention = effectiveMode !== UserSettingsNotificationsMode.OnlyMentions
  const isMentioned = isExplicitlyMentioned || isReplyToUser || (countsDmAsMention && isDM)
  const requiresNotification = isNudge || evalResult?.notifyUserIds?.includes(userId)

  // Mentions
  if (
    effectiveMode === UserSettingsNotificationsMode.Mentions ||
    effectiveMode === UserSettingsNotificationsMode.OnlyMentions
  ) {
    if (
      // Not mentioned
      !isMentioned &&
      // Not notified
      !requiresNotification &&
      // Not DMs - always send for DMs if it's set to "Mentions"
      !(effectiveMode === UserSettingsNotificationsMode.Mentions && isDM)
    ) {
      // Do not notify
      return
    }
    needsExplicitMacNotification = true
    reason = UpdateNewMessageNotification_Reason.MENTION
  }

  // Important only
  if (effectiveMode === UserSettingsNotificationsMode.ImportantOnly) {
    if (!isMentioned || !requiresNotification) {
      // Do not notify
      return
    }
    needsExplicitMacNotification = true
    reason = UpdateNewMessageNotification_Reason.IMPORTANT
  }

  // THEN, send notification ------------------------------------------------------------

  const senderUserName = senderNameInfo ?? (await getCachedUserName(messageInfo.message.fromId))

  if (!senderUserName) {
    Log.shared.warn("No user name found for sender", { senderUserId: messageInfo.message.fromId })
    return
  }

  let title = "Message"
  let body = "New message" // default

  let includeSenderNameInMessage = false
  const senderName = UserNamesCache.getDisplayName(senderUserName)
  // Only provide chat title for threads not DMs
  const chatTitle = chat?.type === "thread" ? chat.title ?? undefined : undefined

  if (chatTitle) {
    // If thread
    title = chatTitle
    if (senderName) {
      includeSenderNameInMessage = true
    }
  } else if (senderName) {
    // If DM
    title = senderName
  } else {
    // If no sender name, use default
    title = "Message"
  }

  if (messageText) {
    // if has text, use text
    body = messageText.substring(0, 240)

    // Add media type to the body if it's a media message with text
    if (messageInfo.message.mediaType === "photo") {
      body = "🖼️ " + body
    } else if (messageInfo.message.mediaType === "video") {
      body = "🎥 " + body
    } else if (messageInfo.message.mediaType === "document") {
      body = "📄 " + body
    }
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

  const senderEmail = senderUserName.email ?? undefined
  const senderPhone = senderUserName.phone ?? undefined

  Notifications.sendToUser({
    userId,
    payload: {
      kind: "send_message",
      senderUserId: messageInfo.message.fromId,
      threadId: `chat_${messageInfo.message.chatId}`,
      isThread: chat?.type == "thread",
      messageId: String(messageInfo.message.messageId),
      title,
      body,
      isUrgentNudge: isUrgentNudge,
      senderDisplayName: senderName ?? undefined,
      senderEmail,
      senderPhone,
      senderProfilePhotoUrl,
      threadEmoji: chat?.emoji ?? undefined,
    },
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
