import {
  InputPeer,
  MessageActions,
  MessageAttachment,
  MessageEntities,
  MessageSendMode,
  Update,
  AgentThreadContext,
  BlockContent,
} from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { FileModel, type DbFullPhoto, type DbFullVideo } from "@in/server/db/models/files"
import type { DbFullDocument, DbFullVoice } from "@in/server/db/models/files"
import { MessageModel } from "@in/server/db/models/messages"
import { UsersModel } from "@in/server/db/models/users"
import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { createHash } from "node:crypto"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { chats, messageAttachments, messages, messageSubmissions, type DbChat, type DbMessage } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { getCachedUserName, UserNamesCache, type UserName } from "@in/server/modules/cache/userNames"
import { encryptMessage, encryptMessageEntities } from "@in/server/modules/encryption/encryptMessage"
import { Notifications } from "@in/server/modules/notifications/notifications"
import { getUpdateGroupFromInputPeer, type UpdateGroup } from "@in/server/modules/updates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodePeerFromChat, encodeOutputPeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { encodeMessageAttachmentUpdate } from "@in/server/realtime/encoders/encodeMessageAttachment"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import { getCachedUserSettings } from "@in/server/modules/cache/userSettings"
import { encryptBinary } from "@in/server/modules/encryption/encryption"
import { getMentionedUserIds, isUserMentioned } from "@in/server/modules/message/helpers"
import { detectHasLink } from "@in/server/modules/message/linkDetection"
import { decideNotification } from "@in/server/modules/notifications/decision"
import {
  decodeDialogNotificationSettings,
  resolveEffectiveNotificationMode,
} from "@in/server/modules/notifications/dialogNotificationSettings"
import { normalizeGlobalNotificationMode } from "@in/server/modules/notifications/notificationSettingsCompat"
import { getInheritedDialogNotificationSettings } from "@in/server/modules/notifications/inheritedDialogNotificationSettings"
import type { UpdateSeqAndDate } from "@in/server/db/models/updates"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { connectionManager, ConnVersion } from "@in/server/ws/connections"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { lockChatAndAncestors } from "@in/server/modules/authorization/chatAccessProjection"
import { getCachedUserProfilePhoto } from "@in/server/modules/cache/userPhotos"
import { processAttachments } from "@in/server/db/models/messages"
import { and, eq, inArray } from "drizzle-orm"
import { unarchiveIfNeeded } from "@in/server/modules/message/unarchiveIfNeeded"
import { desktopPushSuppressionTracker } from "@in/server/modules/notifications/desktopPushSuppression"
import { publishDurableReference } from "@in/server/modules/internalMessaging/durable"
import { maxNotificationNameBytes, messageNotificationBody, notificationText } from "@in/server/modules/notifications/messagePreview"
import { notificationPhotoUrl } from "@in/server/modules/notifications/notificationPhoto"
import { processOutgoingText } from "@in/server/modules/message/processOutgoingText"
import { prepareBlockContent, type PreparedBlockContent } from "@in/server/modules/message/blockContentStorage"
import { getPreviewRoutesFromMessage, processUrlPreviews } from "@in/server/modules/urlPreview/processUrlPreview"
import { normalizeAndValidateMessageActions } from "@in/server/modules/message/messageActions"
import {
  emitChatListOpenUpdates,
  emitMessageSubthreadUpdateIfNeeded,
  getReplyThreadAnchorSenderId,
  isReplyThread,
  isLinkedSubthread,
  queueSubthreadParentUpdate,
  showAndOpenLinkedSubthreadDialogs,
  getChatById,
} from "@in/server/modules/subthreads"
import { queueFirstMessageExperience } from "@in/server/modules/subthreadParentMaterialization"
import { setDialogOpenForUsers } from "@in/server/modules/dialogOpen"
import {
  documentTitleContext,
  getMessageAttachmentTitleContext,
  maybeScheduleThreadTitleGeneration,
  type ThreadTitleAttachmentContext,
} from "@in/server/modules/threadTitles"
import { encodeMessageAttachment } from "@in/server/realtime/encoders/encodeMessageAttachment"
import { VoiceTranscriptionModule } from "@in/server/modules/voiceTranscription"
import { applicationBackgroundWork } from "@in/server/lifecycle/backgroundWork"
import {
  DIALOG_FOLLOWING,
  getFollowingDialogUserIds,
  getUnfollowedDialogUserIds,
  setDialogFollowModeForUsers,
} from "@in/server/modules/dialogFollow"
import { queueMessageThreadLinkMaterialization } from "@in/server/modules/threadGraph"
import { resolveThreadTitleLinks } from "@in/server/modules/message/resolveThreadTitleLinks"
import { resolveGroupMentions } from "@in/server/modules/message/resolveGroupMentions"
import { resolveThreadAutoFollowUserIds } from "@in/server/modules/threadAutoFollow"
import { resolveBotCommandTargets } from "@in/server/modules/message/resolveBotCommandTargets"
import { BotUpdateProjector } from "@in/server/modules/botUpdates/projector"
import { ModelError } from "@in/server/db/models/_errors"
import {
  encodeAgentThreadContext,
  chatAgentContext,
  normalizeAgentThreadContext,
  validateAgentThreadContext,
} from "@in/server/modules/agentConfiguration"
import { getBotUserIdsForChatScope } from "@in/server/functions/bot.peerDiscovery"

type Input = {
  peerId: InputPeer
  message?: string
  replyToMessageId?: bigint
  randomId?: bigint
  photoId?: bigint
  videoId?: bigint
  documentId?: bigint
  voiceId?: bigint
  nudge?: boolean
  sendDate?: number
  isSticker?: boolean
  entities?: MessageEntities
  actions?: MessageActions
  sendMode?: MessageSendMode
  forwardHeader?: {
    fromPeerId: InputPeer
    fromId: number
    fromMessageId: number
  }
  messageAttachments?: { externalTaskId?: bigint; urlPreviewId?: bigint }[]

  /** Canonical structural projection supplied by trusted internal callers such as forwarding. */
  blockContent?: BlockContent

  /** whether to process markdown string */
  parseMarkdown?: boolean

  /** skip processing links into attachments */
  skipLinkProcessing?: boolean

  /** Set-once binding for an existing unbound Chat's first Agent-directed message. */
  initialAgentContext?: AgentThreadContext

  /** Trusted Bot API provenance for an explicit same-bot cross-Chat handoff. */
  sourceChatId?: number

  /** Server-owned immutable forwarding intent; never accepted from SendMessage RPC input. */
  forwardIntentHash?: Buffer
  forwardSourceRevision?: number
}

type Output = {
  updates: Update[]
}

const log = new Log("functions.sendMessage")
const URGENT_NUDGE_TEXT = "🚨"

export const shouldPublishSendMessageToCurrentSession = ({
  isRealtimeV3Session,
  currentUserLayer,
  hasAttachments,
}: {
  isRealtimeV3Session: boolean
  currentUserLayer: number
  hasAttachments: boolean
}): boolean => !isRealtimeV3Session && (currentUserLayer < 2 || hasAttachments)

const submissionIntentHash = (input: Input, chatId: number): Buffer => input.forwardIntentHash ??
  createHash("sha256").update(JSON.stringify({
    version: 1, chatId,
    message: input.message ?? null,
    replyToMessageId: input.replyToMessageId?.toString() ?? null,
    photoId: input.photoId?.toString() ?? null,
    videoId: input.videoId?.toString() ?? null,
    documentId: input.documentId?.toString() ?? null,
    voiceId: input.voiceId?.toString() ?? null,
    nudge: input.nudge ?? false,
    isSticker: input.isSticker ?? false,
    sendDate: input.sendDate ?? null,
    sendMode: input.sendMode ?? 0,
    parseMarkdown: input.parseMarkdown ?? false,
    skipLinkProcessing: input.skipLinkProcessing ?? false,
    entities: input.entities ? Buffer.from(MessageEntities.toBinary(input.entities)).toString("base64") : null,
    actions: input.actions ? Buffer.from(MessageActions.toBinary(input.actions)).toString("base64") : null,
    blockContent: input.blockContent ? Buffer.from(BlockContent.toBinary(input.blockContent)).toString("base64") : null,
    attachments: input.messageAttachments?.map((value) => ({
      externalTaskId: value.externalTaskId?.toString() ?? null,
      urlPreviewId: value.urlPreviewId?.toString() ?? null,
    })) ?? [],
    initialAgentContext: input.initialAgentContext ? Buffer.from(AgentThreadContext.toBinary(input.initialAgentContext)).toString("base64") : null,
    sourceChatId: input.sourceChatId ?? null,
  })).digest()

const recoverSubmission = async (input: {
  randomId: bigint; currentUserId: number; chatId: number; intentHash: Buffer
}, transaction?: Transaction): Promise<Update[] | undefined> => {
  const identity = and(
    eq(messageSubmissions.fromId, input.currentUserId), eq(messageSubmissions.randomId, input.randomId),
  )
  if (!transaction) {
    // Fresh sends have no receipt. Do not take chat locks or open another
    // transaction until a submitted identity actually needs reconciliation.
    const [known] = await db.select({ id: messageSubmissions.randomId }).from(messageSubmissions).where(identity).limit(1)
    if (!known) return undefined
  }
  const recover = async (tx: Transaction): Promise<Update[] | undefined> => {
    const [receipt] = await tx.select().from(messageSubmissions).where(identity).limit(1)
    if (!receipt) return undefined
    if (receipt.chatId !== input.chatId || receipt.sourceRevision !== null ||
      !Encryption2.decryptBinary(receipt.intentHash).equals(input.intentHash)) throw RealtimeRpcError.BadRequest()
    const chat = await lockChatAndAncestors(tx, receipt.chatId, "share")
    if (!chat) throw RealtimeRpcError.PeerIdInvalid()
    await AccessGuards.ensureChatAccess(chat, input.currentUserId, tx)
    const result: Update[] = [{ update: { oneofKind: "updateMessageId", updateMessageId: {
      messageId: BigInt(receipt.messageId), randomId: input.randomId,
    } } }]
    const [existing] = await tx.select({ id: messages.globalId }).from(messages).where(and(
      eq(messages.chatId, receipt.chatId), eq(messages.messageId, receipt.messageId),
      eq(messages.fromId, input.currentUserId), eq(messages.randomId, input.randomId),
    )).limit(1)
    if (!existing) {
      result.push({ update: { oneofKind: "deleteMessages", deleteMessages: {
        peerId: encodeOutputPeerFromChat(chat, { currentUserId: input.currentUserId }),
        messageIds: [BigInt(receipt.messageId)],
      } } })
    }
    return result
  }
  return transaction ? recover(transaction) : db.transaction(recover)
}

/** Internal callers can commit media, attachments and the message together,
 * then run ordinary delivery only after the outer transaction commits. */
export type MessageSendTransaction = {
  transaction: Transaction
  onCommitted: (deliver: () => Promise<Output>) => void
}

export const sendMessage = async (
  input: Input,
  context: FunctionContext,
  submission?: MessageSendTransaction,
): Promise<Output> => {
  if (input.randomId !== undefined && (input.randomId === 0n || input.randomId < -(1n << 63n) || input.randomId >= (1n << 63n))) {
    throw RealtimeRpcError.BadRequest()
  }
  const transaction = submission?.transaction
  const database = transaction ?? db
  const isForwarded = input.forwardIntentHash !== undefined
  // input data
  const date = input.sendDate ? new Date(input.sendDate * 1000) : new Date()
  const fromId = context.currentUserId
  const inputPeer = input.peerId
  const currentUserId = context.currentUserId
  let chat = await ChatModel.getChatFromInputPeer(input.peerId, context)
  await AccessGuards.ensureChatAccess(chat, currentUserId)
  await ensurePrivatePeerCanReceiveMessages(chat, currentUserId)
  const chatId = chat.id
  const intentHash = submissionIntentHash(input, chatId)
  if (input.randomId && !isForwarded) {
    const recovered = await recoverSubmission({ randomId: input.randomId, currentUserId, chatId, intentHash }, transaction)
    if (recovered) return { updates: recovered }
  }
  if (input.sourceChatId !== undefined) {
    const sourceChatId = Number(input.sourceChatId)
    if (!Number.isSafeInteger(sourceChatId) || sourceChatId <= 0 || sourceChatId === chatId) {
      throw RealtimeRpcError.BadRequest()
    }
    const sender = await UsersModel.getUserById(currentUserId)
    const sourceChat = await getChatById(sourceChatId)
    if (!sender?.bot || !sourceChat) throw RealtimeRpcError.BadRequest()
    await AccessGuards.ensureChatAccess(sourceChat, currentUserId)
    const sourceContext = chatAgentContext(sourceChat)
    const destinationContext = chatAgentContext(chat)
    if (
      Number(sourceContext?.botUserId) !== currentUserId ||
      destinationContext === undefined
    ) {
      throw RealtimeRpcError.BadRequest()
    }
  }
  if (input.initialAgentContext && input.randomId) {
    const normalizedRetryContext = normalizeAgentThreadContext(input.initialAgentContext)
    const recovered = await recoverInitialAgentMessageRetry({
      chatId,
      currentUserId,
      randomId: input.randomId,
      expectedContext: normalizedRetryContext,
      intentHash,
    }, transaction)
    if (recovered) return { updates: recovered }
  }
  const replyToMsgIdNumber = input.replyToMessageId ? Number(input.replyToMessageId) : null
  const currentSessionConnections = connectionManager
    .getUserConnections(currentUserId)
    .filter(({ sessionId }) => sessionId === context.currentSessionId)
  const currentUserLayer = currentSessionConnections.reduce(
    (layer, connection) => Math.max(layer, connection.layer ?? 0),
    0,
  )
  const isRealtimeV3Session = currentSessionConnections.some(
    ({ version }) => version === ConnVersion.REALTIME_V3,
  )

  const outgoingText: Awaited<ReturnType<typeof processOutgoingText>> | undefined = input.message
    ? isForwarded ? { text: input.message, entities: input.entities } : await processOutgoingText({
        text: input.message,
        entities: input.entities,
        parseMarkdown: input.parseMarkdown,
      })
    : undefined
  let text = outgoingText?.text
  let entities: MessageEntities | undefined
  try {
    entities = isForwarded ? input.entities : await resolveThreadTitleLinks({
      entities: outgoingText?.entities,
      context,
    })
    if (text && !isForwarded) {
      entities = await resolveBotCommandTargets({
        text,
        entities,
        chat,
        currentUserId,
      })
    }
  } catch (error) {
    log.error("sendMessage failed to resolve outgoing entities", { chatId, currentUserId, error })
    if (RealtimeRpcError.is(error)) {
      throw error
    }
    throw RealtimeRpcError.InternalError()
  }

  await ensureUrgentNudgeHasPriorTwoWayChat({
    chat,
    currentUserId,
    isUrgentNudge: input.nudge === true && text?.trim() === URGENT_NUDGE_TEXT,
  })

  const groupMentions = isForwarded
    ? { entities, mentionedUserIds: [] }
    : await resolveGroupMentions({
        text: text ?? "",
        entities,
        chat,
        currentUserId,
      })
  entities = groupMentions.entities
  const destinationAgentContext = chatAgentContext(chat)
  const selfMentionsExactBoundAgent = Number(destinationAgentContext?.botUserId) === currentUserId &&
    (entities?.entities ?? []).some((entity) => {
      if (entity.entity.oneofKind !== "mention") return false
      const mention = entity.entity.mention
      return Number(mention.userId) === currentUserId && mention.agentId === destinationAgentContext?.agentId
    })
  if (selfMentionsExactBoundAgent && !isForwarded && input.sourceChatId === undefined) {
    throw RealtimeRpcError.BadRequest()
  }
  const mentionedUserIds = new Set<number>(isForwarded ? [] : [
    ...getMentionedUserIds(entities),
    ...groupMentions.mentionedUserIds,
  ])

  let preparedBlockContent: PreparedBlockContent | undefined
  const parsedBlockContent = input.blockContent
    ? { blockContent: input.blockContent, imageSources: [] }
    : outgoingText?.blockContent
      ? {
          blockContent: outgoingText.blockContent,
          imageSources: outgoingText.blockImageSources ?? [],
        }
      : undefined
  if (text && parsedBlockContent) {
    try {
      preparedBlockContent = prepareBlockContent({
        text,
        entities,
        parsed: parsedBlockContent,
      })
    } catch (error) {
      log.error("rich content preparation failed; sending the plain projection", {
        chatId,
        currentUserId,
        errorType: error instanceof Error ? error.name : "UnknownError",
      })
    }
  }

  const hasInputUrlPreview = input.messageAttachments?.some((attachment) => attachment.urlPreviewId != null) ?? false
  const previewRoutes = text && !input.skipLinkProcessing && !hasInputUrlPreview
    ? getPreviewRoutesFromMessage(text, entities)
    : []
  const hasLink = detectHasLink({ entities }) || hasInputUrlPreview || previewRoutes.length > 0

  // Encrypt
  const encryptedMessage = text ? encryptMessage(text) : undefined
  const normalizedActions = normalizeAndValidateMessageActions(input.actions)
  if (normalizedActions !== undefined) {
    const sender = await UsersModel.getUserById(currentUserId)
    if (!sender?.bot) {
      throw RealtimeRpcError.BadRequest()
    }
  }

  // photo, video, document, voice ids
  let dbFullPhoto: DbFullPhoto | undefined
  let dbFullVideo: DbFullVideo | undefined
  let dbFullDocument: DbFullDocument | undefined
  let dbFullVoice: DbFullVoice | undefined
  let mediaType: "photo" | "video" | "document" | "nudge" | "voice" | null = null

  if (input.nudge) {
    mediaType = "nudge"
  } else if (input.photoId) {
    dbFullPhoto = await FileModel.getPhotoById(input.photoId, transaction)
    mediaType = "photo"
  } else if (input.videoId) {
    dbFullVideo = await FileModel.getVideoById(input.videoId, transaction)
    mediaType = "video"
  } else if (input.documentId) {
    dbFullDocument = await FileModel.getDocumentById(input.documentId, transaction)
    mediaType = "document"
  } else if (input.voiceId) {
    dbFullVoice = await FileModel.getVoiceById(input.voiceId, transaction)
    mediaType = "voice"
  }

  let initialAgentContext: AgentThreadContext | undefined
  let encodedInitialAgentContext: Buffer | undefined
  if (input.initialAgentContext) {
    initialAgentContext = await validateAgentThreadContext(
      input.initialAgentContext,
      { bindingActorUserId: currentUserId, operation: "initial_message" },
    )
    const botUserId = Number(initialAgentContext.botUserId)
    encodedInitialAgentContext = encodeAgentThreadContext(initialAgentContext)
    if (chat.agentContext !== null) {
      if (!input.randomId || !Buffer.from(chat.agentContext).equals(encodedInitialAgentContext)) {
        throw RealtimeRpcError.BadRequest()
      }
      try {
        const existing = await MessageModel.getMessageByRandomId(input.randomId, currentUserId)
        if (existing.chatId !== chatId) throw RealtimeRpcError.BadRequest()
        return { updates: await selfUpdatesFromExistingMessage(input.randomId, currentUserId, chatId, intentHash, transaction) }
      } catch (error) {
        if (error instanceof RealtimeRpcError) throw error
        throw RealtimeRpcError.BadRequest()
      }
    }

    const visibleBotIds = await getBotUserIdsForChatScope(chat, currentUserId)
    if (!visibleBotIds.includes(botUserId)) throw RealtimeRpcError.UserIdInvalid()

    const hasConsumableInput = Boolean(text?.trim()) ||
      mediaType === "photo" || mediaType === "video" || mediaType === "document" || mediaType === "voice"
    if (!hasConsumableInput) throw RealtimeRpcError.BadRequest()
  }

  // encrypt entities
  const binaryEntities = entities ? MessageEntities.toBinary(entities) : undefined
  const encryptedEntities = binaryEntities && binaryEntities.length > 0
    ? encryptMessageEntities(binaryEntities)
    : undefined
  const binaryActions = normalizedActions ? MessageActions.toBinary(normalizedActions) : undefined
  const encryptedActions = binaryActions && binaryActions.length > 0 ? encryptBinary(binaryActions) : undefined

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

  let newMessage: DbMessage & { blockContent?: BlockContent | null }
  let update: UpdateSeqAndDate
  let agentContextUpdate: UpdateSeqAndDate | undefined
  try {
    // insert new msg with new ID
    ;({ chat, message: newMessage, update, agentContextUpdate } = await MessageModel.insertMessage({
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
      forwardIntentHash: input.forwardIntentHash ?? null,
      date: date,
      mediaType: mediaType,
      photoId: dbFullPhoto?.id ?? null,
      videoId: dbFullVideo?.id ?? null,
      documentId: dbFullDocument?.id ?? null,
      voiceId: dbFullVoice?.id ?? null,
      isSticker: input.isSticker ?? false,
      hasLink: hasLink,
      entitiesEncrypted: encryptedEntities?.encrypted ?? null,
      entitiesIv: encryptedEntities?.iv ?? null,
      entitiesTag: encryptedEntities?.authTag ?? null,
      actionsEncrypted: encryptedActions?.encrypted ?? null,
      actionsIv: encryptedActions?.iv ?? null,
      actionsTag: encryptedActions?.authTag ?? null,
    }, preparedBlockContent, transaction, initialAgentContext && encodedInitialAgentContext
      ? { value: initialAgentContext, encoded: encodedInitialAgentContext }
      : undefined, input.randomId !== undefined
      ? { intentHash, sourceRevision: input.forwardSourceRevision }
      : undefined))
  } catch (error) {
    if (error instanceof ModelError && error.code === ModelError.Codes.AGENT_CONTEXT_ALREADY_SET) {
      if (input.randomId && encodedInitialAgentContext && initialAgentContext) {
        const recovered = await recoverInitialAgentMessageRetry({
          chatId,
          currentUserId,
          randomId: input.randomId,
          expectedContext: initialAgentContext,
          intentHash,
        }, transaction)
        if (recovered) return { updates: recovered }
      }
      throw RealtimeRpcError.BadRequest()
    }
    if (error instanceof Error && (error.message.includes("random_id_per_sender_unique") || error.message.includes("message_submissions_identity")) && input.randomId) {
      log.debug("duplicate random id recovered from existing message", { currentUserId })

      // Forwarding owns a stricter intent check before cloning. A constraint
      // conflict inside its transaction must roll back every clone.
      if (isForwarded || transaction) throw RealtimeRpcError.BadRequest()
      return { updates: await selfUpdatesFromExistingMessage(input.randomId, currentUserId, chatId, intentHash) }
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
      await database.insert(messageAttachments).values(attachmentRows)
    }
  }

  const deliver = async (): Promise<Output> => {
    queueMessageThreadLinkMaterialization({
      sourceChat: chat,
      sourceChatId: chat.id,
      sourceMessageGlobalId: newMessage.globalId,
      sourceMessageId: newMessage.messageId,
      sourceMessageFromId: newMessage.fromId,
      sourceMessageRevision: newMessage.rev,
      entities,
    })

    const titleAttachments = documentTitleContext(dbFullDocument)

    const recordDesktopChatActivityPromise = desktopPushSuppressionTracker.recordChatActivity({
      userId: currentUserId,
      sessionId: context.currentSessionId,
      connectionId: context.currentConnectionId,
      chatId,
    })

    // encode message info
    const messageInfo: MessageInfo = {
      message: newMessage,
      photo: dbFullPhoto,
      video: dbFullVideo,
      document: dbFullDocument,
      voice: dbFullVoice,
      sendMode: input.sendMode,
      mentionedUserIds,
    }

    //await debugDelay(5000)

    const hasAttachments =
      messageInfo.photo !== undefined ||
      messageInfo.video !== undefined ||
      messageInfo.document !== undefined ||
      messageInfo.voice !== undefined

    // send new updates
    // TODO: need to create the update, use the sequence number
    // we probably need to create the update and message in one transaction
    // to avoid multiple times locking the chat row for last message and pts.
    // we can also separate the sequence caching. this will speed up and
    // remove the need to lock the chat row. then we should deliver the update
    // with sequence number so we can ensure gap-free delivery.
    const updateGroup = await getUpdateGroupFromInputPeer(inputPeer, { currentUserId })
    let initialAgentContextRealtimeUpdate: Update | undefined
    if (initialAgentContext && agentContextUpdate) {
      initialAgentContextRealtimeUpdate = {
        update: {
          oneofKind: "chatInfo",
          chatInfo: { chatId: BigInt(chat.id), agentContext: initialAgentContext },
        },
        seq: agentContextUpdate.seq,
        date: encodeDateStrict(agentContextUpdate.date),
      }
      updateGroup.userIds.forEach((userId) => {
        RealtimeUpdates.pushToUser(userId, [initialAgentContextRealtimeUpdate!], {
          skipSessionId: userId === currentUserId ? context.currentSessionId : undefined,
        })
      })
    }
    await autoFollowThreadMessage({
      chat,
      currentUserId,
      updateGroup,
      newMessageId: newMessage.messageId,
    })

    const sidebarOpenUserIds = await getSidebarOpenUserIds({
      chat,
      currentUserId,
      replyToMessageId: replyToMsgIdNumber ?? undefined,
      mentionedUserIds,
      updateGroup,
    })
    if (sidebarOpenUserIds.length > 0) {
      const { changedDialogs } = isLinkedSubthread(chat)
        ? await showAndOpenLinkedSubthreadDialogs({
            chat,
            userIds: sidebarOpenUserIds,
          })
        : await setDialogOpenForUsers({
            chat,
            userIds: sidebarOpenUserIds,
            open: true,
            showInChatList: true,
          })

      await emitChatListOpenUpdates({
        chat,
        dialogs: changedDialogs,
      })
    }
    const { updates: unarchiveUpdates } = await unarchiveIfNeeded({
      chat,
      updateGroup,
      senderUserId: currentUserId,
      userIds: isReplyThread(chat) ? sidebarOpenUserIds : undefined,
    })

    unarchiveUpdates.forEach(({ userId, update }) => {
      RealtimeUpdates.pushToUser(userId, [update])
    })

    await recordDesktopChatActivityPromise

    const publishToSelfSession = shouldPublishSendMessageToCurrentSession({
      isRealtimeV3Session,
      currentUserLayer,
      hasAttachments,
    })
    let { selfUpdates } = await pushUpdates({
      inputPeer,
      messageInfo,
      currentUserId,
      update,
      currentSessionId: context.currentSessionId,
      publishToSelfSession,
      updateGroup,
    })
    publishDurableReference({
      bucket: { kind: "chat", chatId },
      frontier: update.seq,
      senderUserId: currentUserId,
      ...(!publishToSelfSession ? { excludeSessionId: context.currentSessionId } : {}),
    })
    if (initialAgentContextRealtimeUpdate) selfUpdates.unshift(initialAgentContextRealtimeUpdate)

    BotUpdateProjector.messageCreated({
      chat,
      messageId: newMessage.messageId,
      updateGroup,
      sourceChatId: input.sourceChatId,
    })

    // Start after the new-message update is pushed so attachment updates cannot race ahead of the message.
    if (previewRoutes.length > 0) {
      const previewWork = processUrlPreviews({
        message: newMessage,
        previewRoutes,
        chatId,
        spaceId: chat.spaceId,
        currentUserId,
        inputPeer,
        chat,
        messageText: text,
        messageEntities: entities,
        titleAttachments,
      }).catch((error) => {
        log.error("Failed to process message URL previews", {
          error,
          chatId,
          messageId: newMessage.messageId,
        })
      })
      applicationBackgroundWork.track(previewWork)
    }

    if (dbFullVoice && !text) {
      VoiceTranscriptionModule.schedule({
        message: newMessage,
        voice: dbFullVoice,
        inputPeer,
        context,
      })
    }

    // send notification
    const notificationWork = sendNotifications({
      updateGroup,
      messageInfo,
      currentUserId,
      chat,
      unencryptedEntities: entities,
      mentionedUserIds,
      unencryptedText: text,
      inputPeer,
      sendMode: input.sendMode,
    }).catch((error) => {
      log.error("Failed to send message notifications", {
        error,
        chatId,
        messageId: newMessage.messageId,
        currentUserId,
      })
    })
    applicationBackgroundWork.track(notificationWork)

    if (previewRoutes.length === 0) {
      if (input.messageAttachments && input.messageAttachments.length > 0) {
        const titleContextWork = scheduleThreadTitleGenerationWithMessageAttachments({
          chat,
          message: newMessage,
          text,
          entities,
          attachments: titleAttachments,
          currentUserId,
        }).catch((error) => {
          log.error("Failed to schedule message thread title generation", {
            error,
            chatId,
            messageId: newMessage.messageId,
          })
        })
        applicationBackgroundWork.track(titleContextWork)
      } else {
        maybeScheduleThreadTitleGeneration({
          chat,
          message: newMessage,
          text,
          entities,
          attachments: titleAttachments,
          currentUserId,
        })
      }
    }

    queueFirstMessageExperience({
      chat,
      message: newMessage,
      text,
      entities,
      attachments: titleAttachments,
      currentUserId,
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

    if (isReplyThread(chat)) {
      await emitMessageSubthreadUpdateIfNeeded({ chatId: chat.id, currentUserId })
    } else if (isLinkedSubthread(chat)) {
      queueSubthreadParentUpdate({
        chatId: chat.id,
        currentUserId,
        reason: "message send",
      })
    }

    // return new updates
    return { updates: selfUpdates }
  }
  if (submission) {
    submission.onCommitted(deliver)
    return { updates: [{ update: {
      oneofKind: "updateMessageId",
      updateMessageId: { messageId: BigInt(newMessage.messageId), randomId: input.randomId ?? 0n },
    } }] }
  }
  return deliver()
}

async function ensurePrivatePeerCanReceiveMessages(chat: DbChat, currentUserId: number): Promise<void> {
  if (chat.type !== "private" || chat.minUserId == null || chat.maxUserId == null) {
    return
  }

  const peerUserId = chat.minUserId === currentUserId ? chat.maxUserId : chat.minUserId
  if (peerUserId === currentUserId) {
    return
  }

  const peerUser = await UsersModel.getUserById(peerUserId)
  if (!peerUser || UsersModel.isDeleted(peerUser)) {
    throw RealtimeRpcError.PeerIdInvalid()
  }
}

async function ensureUrgentNudgeHasPriorTwoWayChat({
  chat,
  currentUserId,
  isUrgentNudge,
}: {
  chat: DbChat
  currentUserId: number
  isUrgentNudge: boolean
}): Promise<void> {
  if (!isUrgentNudge) {
    return
  }

  if (chat.type !== "private" || chat.minUserId == null || chat.maxUserId == null) {
    throw RealtimeRpcError.BadRequest()
  }

  const peerUserId = chat.minUserId === currentUserId ? chat.maxUserId : chat.minUserId
  if (peerUserId === currentUserId) {
    return
  }

  const priorAuthors = await db
    .selectDistinct({ fromId: messages.fromId })
    .from(messages)
    .where(and(eq(messages.chatId, chat.id), inArray(messages.fromId, [currentUserId, peerUserId])))
    .limit(2)

  const priorAuthorIds = new Set(priorAuthors.map(({ fromId }) => fromId))
  if (!priorAuthorIds.has(currentUserId) || !priorAuthorIds.has(peerUserId)) {
    throw RealtimeRpcError.BadRequest()
  }
}

async function scheduleThreadTitleGenerationWithMessageAttachments(input: {
  chat: DbChat
  message: DbMessage
  text: string | undefined
  entities: MessageEntities | undefined
  attachments: ThreadTitleAttachmentContext[]
  currentUserId: number
}): Promise<void> {
  let attachments = input.attachments
  try {
    attachments = [...attachments, ...(await getMessageAttachmentTitleContext(input.message.globalId))]
  } catch (error) {
    log.warn("Failed to load message attachment context for thread title generation", {
      error,
      chatId: input.chat.id,
      messageId: input.message.messageId,
    })
  }

  maybeScheduleThreadTitleGeneration({
    chat: input.chat,
    message: input.message,
    text: input.text,
    entities: input.entities,
    attachments,
    currentUserId: input.currentUserId,
  })
}

const getSidebarOpenUserIds = async ({
  chat,
  currentUserId,
  replyToMessageId,
  mentionedUserIds,
  updateGroup,
}: {
  chat: DbChat
  currentUserId: number
  replyToMessageId: number | undefined
  mentionedUserIds: ReadonlySet<number>
  updateGroup: UpdateGroup
}): Promise<number[]> => {
  const eligibleUserIds = new Set(updateGroup.userIds.filter((userId) => userId !== currentUserId))
  const openUserIds = new Set<number>()

  if (updateGroup.type === "dmUsers") {
    for (const userId of eligibleUserIds) {
      openUserIds.add(userId)
    }
  }

  for (const mentionedUserId of mentionedUserIds) {
    if (eligibleUserIds.has(mentionedUserId)) {
      openUserIds.add(mentionedUserId)
    }
  }

  if (replyToMessageId !== undefined) {
    try {
      const repliedToMessage = await MessageModel.getMessage(replyToMessageId, chat.id)
      if (eligibleUserIds.has(repliedToMessage.fromId)) {
        openUserIds.add(repliedToMessage.fromId)
      }
    } catch {
      // Keep send semantics unchanged if reply target is missing or inaccessible.
    }
  }

  if (chat.type === "thread") {
    const followingUserIds = await getFollowingDialogUserIds({
      chatId: chat.id,
      userIds: Array.from(eligibleUserIds),
    })

    followingUserIds.forEach((userId) => openUserIds.add(userId))
  }

  return Array.from(openUserIds)
}

const autoFollowThreadMessage = async ({
  chat,
  currentUserId,
  updateGroup,
  newMessageId,
}: {
  chat: DbChat
  currentUserId: number
  updateGroup: UpdateGroup
  newMessageId: number
}) => {
  const eligibleUserIds = new Set(updateGroup.userIds)
  const candidateUserIds = await resolveThreadAutoFollowUserIds({
    chat,
    currentUserId,
    eligibleUserIds,
    newMessageId,
  })
  if (candidateUserIds.length === 0) {
    return
  }

  const unfollowedUserIds = new Set(
    await getUnfollowedDialogUserIds({
      chatId: chat.id,
      userIds: candidateUserIds,
    }),
  )
  const followUserIds = candidateUserIds.filter((userId) => !unfollowedUserIds.has(userId))
  if (followUserIds.length === 0) {
    return
  }

  const { changedDialogs, unhiddenDialogs } = await setDialogFollowModeForUsers({
    chat,
    userIds: followUserIds,
    followMode: DIALOG_FOLLOWING,
    showInChatList: true,
  })

  const unhiddenUserIds = new Set(unhiddenDialogs.map((dialog) => dialog.userId))
  await emitChatListOpenUpdates({
    chat,
    dialogs: changedDialogs.filter((dialog) => {
      if (dialog.userId === currentUserId) {
        return true
      }

      return (
        unhiddenUserIds.has(dialog.userId) &&
        dialog.open === true &&
        dialog.order != null &&
        dialog.archived !== true
      )
    }),
  })
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
  const sends: Promise<void>[] = []

  if (resolvedUpdateGroup.type === "dmUsers") {
    resolvedUpdateGroup.userIds.forEach((userId) => {
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
        sends.push(RealtimeUpdates.pushToUser(
          userId,
          [
            // order matters here
            messageIdUpdate,
            newMessageUpdate,
          ],
          { skipSessionId },
        ))

        selfUpdates = [
          // order matters here
          messageIdUpdate,
          newMessageUpdate,
        ]
      } else {
        // other users get the message only
        sends.push(RealtimeUpdates.pushToUser(userId, [newMessageUpdate]))
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
        sends.push(RealtimeUpdates.pushToUser(
          userId,
          [
            // order matters here
            messageIdUpdate,
            newMessageUpdate,
          ],
          { skipSessionId },
        ))

        selfUpdates = [
          // order matters here
          messageIdUpdate,
          newMessageUpdate,
        ]
      } else {
        // other users get the message only
        sends.push(RealtimeUpdates.pushToUser(userId, [newMessageUpdate]))
      }
    })
  }

  await Promise.all(sends)
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
          video: {
            with: {
              file: true,
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
          document: {
            with: {
              file: true,
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

  const attachmentUpdates = processed
    .map((attachment) => encodeMessageAttachment(attachment))
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

async function selfUpdatesFromExistingMessage(
  randomId: bigint, currentUserId: number, chatId: number, intentHash: Buffer, transaction?: Transaction,
): Promise<Update[]> {
  const recovered = await recoverSubmission({ randomId, currentUserId, chatId, intentHash }, transaction)
  if (recovered) return recovered
  const recoverLegacy = async (tx: Transaction): Promise<Update[]> => {
    const chat = await lockChatAndAncestors(tx, chatId, "share")
    if (!chat) throw RealtimeRpcError.PeerIdInvalid()
    await AccessGuards.ensureChatAccess(chat, currentUserId, tx)
    const [message] = await tx.select({
      chatId: messages.chatId, messageId: messages.messageId,
      forwardIntentHash: messages.forwardIntentHash, fwdFromMessageId: messages.fwdFromMessageId,
    }).from(messages).where(and(eq(messages.randomId, randomId), eq(messages.fromId, currentUserId))).limit(1)
    if (!message) throw ModelError.MessageInvalid
    // Pre-ledger rows retain ID-only compatibility, not retrospective content
    // proof. They still require current authority, and cannot cross forwarding.
    if (message.chatId !== chatId || message.forwardIntentHash != null || message.fwdFromMessageId != null) {
      throw RealtimeRpcError.BadRequest()
    }
    return [{ update: { oneofKind: "updateMessageId", updateMessageId: {
      messageId: BigInt(message.messageId), randomId,
    } } }]
  }
  return transaction ? recoverLegacy(transaction) : db.transaction(recoverLegacy)
}

async function recoverInitialAgentMessageRetry(input: {
  chatId: number
  currentUserId: number
  randomId: bigint
  expectedContext: AgentThreadContext
  intentHash: Buffer
}, transaction?: Transaction): Promise<Update[] | undefined> {
  let message: DbMessage
  try {
    const [existing] = await (transaction ?? db).select().from(messages).where(and(
      eq(messages.randomId, input.randomId), eq(messages.fromId, input.currentUserId),
    )).limit(1)
    if (!existing) throw ModelError.MessageInvalid
    message = existing
  } catch (error) {
    if (error instanceof ModelError && error.code === ModelError.Codes.MESSAGE_INVALID) {
      return undefined
    }
    throw error
  }
  const persistedChat = await (transaction ?? db)._query.chats.findFirst({ where: eq(chats.id, input.chatId) })
  const persistedContext = persistedChat ? chatAgentContext(persistedChat) : undefined
  // The committed message already owns its optional Agent/configuration. Retry
  // identity is anchored by sender, random ID, Chat, and the required bot target.
  if (
    message.chatId !== input.chatId ||
    persistedContext?.botUserId !== input.expectedContext.botUserId
  ) {
    throw RealtimeRpcError.BadRequest()
  }
  return selfUpdatesFromExistingMessage(input.randomId, input.currentUserId, input.chatId, input.intentHash, transaction)
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
  mentionedUserIds: ReadonlySet<number>
  inputPeer: InputPeer
  sendMode?: MessageSendMode
}

/** Send push notifications for this message */
async function sendNotifications(input: SendPushForMsgInput) {
  if (input.sendMode === MessageSendMode.MODE_SILENT) {
    return
  }

  const { updateGroup, messageInfo, currentUserId, chat, unencryptedText, inputPeer, mentionedUserIds } = input
  const isNudge = isNudgeMessage({ messageInfo })
  const trimmedText = unencryptedText?.trim()
  const isUrgentNudge = isNudge && trimmedText === URGENT_NUDGE_TEXT

  // A direct reply (replyToMsgId) targets a concrete message in this chat.
  const repliedToSenderId = messageInfo.message.replyToMsgId
    ? await MessageModel.getSenderIdForMessage({
        chatId: messageInfo.message.chatId,
        messageId: messageInfo.message.replyToMsgId,
      })
    : undefined

  // In linked reply threads (anchored by parentMessageId), each child message is
  // semantically a reply to the anchor message. We treat the anchor author as a
  // reply/mention target so users in mention-based modes don't miss thread activity.
  const replyThreadAnchorSenderId = await getReplyThreadAnchorSenderId(chat)
  const replyMentionUserIds = new Set<number>(
    [repliedToSenderId, replyThreadAnchorSenderId].filter(
      (userId): userId is number => userId != null && Number.isSafeInteger(userId) && userId > 0,
    ),
  )

  // decrypt message text
  let messageText = input.unencryptedText
  let messageEntities = input.unencryptedEntities

  const senderNameInfo = await getCachedUserName(messageInfo.message.fromId)
  const senderPhoto = await getCachedUserProfilePhoto(messageInfo.message.fromId)

  const recipientUserIds = updateGroup.userIds.filter((userId) => userId !== currentUserId)
  const dialogNotificationSettingsByUserId = await getInheritedDialogNotificationSettings(chat.id, recipientUserIds)

  // TODO: send to users who have it set to All immediately
  // Handle DMs and threads
  await Promise.all(
    updateGroup.userIds
      .filter((userId) => userId !== currentUserId)
      .map(async (userId) => {
        try {
          await sendNotificationToUser({
            userId,
            messageInfo,
            messageText,
            messageEntities,
            mentionedUserIds,
            replyMentionUserIds,
            chat,
            isNudge,
            isUrgentNudge,
            updateGroup,
            inputPeer,
            currentUserId,
            senderNameInfo,
            senderProfilePhotoUrl: senderPhoto?.cdnUrl,
            senderHasProfilePhoto: senderPhoto?.hasPhoto,
            dialogNotificationSettings: dialogNotificationSettingsByUserId.get(userId),
          })
        } catch (error) {
          log.error("Failed to send message notification to user", {
            error,
            userId,
            chatId: chat.id,
            messageId: messageInfo.message.messageId,
          })
        }
      }),
  )
}

/**
 * Reuse the ordinary notification policy for a newly committed live agent
 * projection without reusing the ordinary send path (which would activate
 * bots, title work, previews, and dialog mutations).
 */
export async function sendProjectedMessageNotification(input: {
  chat: DbChat
  message: DbMessage
  text: string | undefined
  entities: MessageEntities | undefined
}): Promise<void> {
  const inputPeer = encodePeerFromChat(input.chat, { currentUserId: input.message.fromId })
  const updateGroup = await getUpdateGroupFromInputPeer(inputPeer, {
    currentUserId: input.message.fromId,
  })
  await sendNotifications({
    updateGroup,
    messageInfo: { message: input.message },
    currentUserId: input.message.fromId,
    chat: input.chat,
    unencryptedText: input.text,
    unencryptedEntities: input.entities,
    mentionedUserIds: new Set(getMentionedUserIds(input.entities)),
    inputPeer,
  })
}

/** Send push notifications for this message */
async function sendNotificationToUser({
  userId,
  messageInfo,
  messageText,
  messageEntities,
  mentionedUserIds,
  replyMentionUserIds,
  chat,
  isNudge,
  isUrgentNudge,
  updateGroup,
  inputPeer,
  currentUserId,
  senderNameInfo,
  senderProfilePhotoUrl,
  senderHasProfilePhoto,
  dialogNotificationSettings,
}: {
  userId: number
  messageInfo: MessageInfo
  messageText: string | undefined
  messageEntities: MessageEntities | undefined
  mentionedUserIds: ReadonlySet<number>
  replyMentionUserIds: Set<number>
  chat?: DbChat
  isNudge: boolean
  isUrgentNudge: boolean
  // For explicit mac notification
  updateGroup: UpdateGroup
  inputPeer: InputPeer
  currentUserId: number
  senderNameInfo?: UserName
  senderProfilePhotoUrl?: string
  senderHasProfilePhoto?: boolean
  dialogNotificationSettings?: ReturnType<typeof decodeDialogNotificationSettings>
}) {
  // FIRST, check if we should notify this user or not ---------------------------------
  const userSettings = await getCachedUserSettings(userId)
  const globalMode = normalizeGlobalNotificationMode(userSettings)
  const effectiveMode = resolveEffectiveNotificationMode({
    globalMode,
    dialogNotificationSettings,
  })

  const isDM = inputPeer.type.oneofKind === "user"
  const isReplyToUser = replyMentionUserIds.has(userId)
  const isExplicitlyMentioned =
    messageInfo.message.forwardIntentHash == null && messageInfo.message.fwdFromMessageId == null &&
    (mentionedUserIds.has(userId) || (messageEntities ? isUserMentioned(messageEntities, userId, mentionedUserIds) : false))

  const decision = decideNotification({
    mode: effectiveMode,
    isUrgentNudge,
    isNudge,
    isDM,
    isReplyToUser,
    isExplicitlyMentioned,
  })

  if (!decision.shouldNotify) {
    return
  }

  const needsExplicitMacNotification = decision.needsExplicitMacNotification
  const reason = decision.reason

  // THEN, send notification ------------------------------------------------------------

  const senderUserName = senderNameInfo ?? (await getCachedUserName(messageInfo.message.fromId))

  if (!senderUserName) {
    Log.shared.warn("No user name found for sender", { senderUserId: messageInfo.message.fromId })
    return
  }

  let title = "Message"
  let body = messageNotificationBody({
    messageText,
    mediaType: messageInfo.message.mediaType,
    isSticker: messageInfo.message.isSticker,
    documentFileName: messageInfo.document?.fileName,
    isAnimated: messageInfo.video?.isAnimated,
    voiceDuration: messageInfo.voice?.duration,
  })

  let includeSenderNameInMessage = false
  const senderName = notificationText(UserNamesCache.getDisplayName(senderUserName), maxNotificationNameBytes)
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

  if (includeSenderNameInMessage) {
    body = `${senderName}: ${body}`
  }

  const suppressionDecision = await desktopPushSuppressionTracker.shouldSuppressIOSSendMessagePush({
    userId,
    chatId: messageInfo.message.chatId,
    isUrgentNudge,
  })

  if (!suppressionDecision.suppress) {
    await Notifications.sendToUser({
      userId,
      payload: {
        kind: "send_message",
        senderUserId: messageInfo.message.fromId,
        threadId: `chat_${messageInfo.message.chatId}`,
        isThread: chat?.type == "thread",
        isReplyThread: chat != null ? isReplyThread(chat) : false,
        messageId: String(messageInfo.message.messageId),
        title,
        body,
        isUrgentNudge: isUrgentNudge,
        senderDisplayName: senderName ?? undefined,
        senderProfilePhotoUrl,
        senderHasProfilePhoto,
        threadEmoji: chat?.emoji ?? undefined,
        photoUrl: messageInfo.message.isSticker ? undefined : notificationPhotoUrl(messageInfo.photo),
      },
    })
  } else {
    log.debug("Suppressing iOS send_message push due to active desktop chat", {
      userId,
      chatId: messageInfo.message.chatId,
      reason: suppressionDecision.reason,
    })
  }

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
