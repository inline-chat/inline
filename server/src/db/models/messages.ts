import {
  MessageActions,
  MessageEntities,
  type AgentThreadContext,
  type AgentSessionMessageInfo,
  type BlockContent,
  type InputPeer,
} from "@inline-chat/protocol/core"
import { cleanMultilinePreviewText, cleanPreviewText } from "@inline-chat/url-preview"
import { db } from "@in/server/db"
import { ModelError } from "@in/server/db/models/_errors"
import { ChatModel } from "@in/server/db/models/chats"
import {
  FileModel,
  type DbFullDocument,
  type DbFullPhoto,
  type DbFullVideo,
  type DbFullVoice,
  type InputDbFullDocument,
  type InputDbFullPhoto,
  type InputDbFullVideo,
  type InputDbFullVoice,
} from "@in/server/db/models/files"
import {
  chats,
  agentSessionMessages,
  agentSessions,
  blockContents,
  messages,
  type DbBlockContent,
  type DbMessage,
  type DbNewMessage,
  type DbReaction,
  type DbTranslation,
  type DbUser,
} from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { messageAttachments, type DbMessageAttachment } from "@in/server/db/schema/attachments"
import {
  decryptMessage,
  encryptMessage,
  encryptMessageEntities,
} from "@in/server/modules/encryption/encryptMessage"
import { Log, LogLevel } from "@in/server/utils/log"
import { and, asc, desc, eq, gt, inArray, isNull, lt, not, or, sql } from "drizzle-orm"
import { decrypt, decryptBinary, encryptBinary } from "@in/server/modules/encryption/encryption"
import type { DbExternalTask, DbLinkEmbed } from "@in/server/db/schema/attachments"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { detectHasLink } from "@in/server/modules/message/linkDetection"
import { persistChatMetadataUpdates, type ChatMetadataUpdate } from "@in/server/modules/chatMetadataUpdates"
import { decryptSystemMessagePayload, type SystemMessage } from "@in/server/modules/systemMessages/payload"
import {
  insertPreparedBlockContent,
  deleteUnreferencedBlockContents,
  replacePreparedBlockContent,
  type PreparedBlockContent,
} from "@in/server/modules/message/blockContentStorage"
import { decryptStoredBlockContent } from "@in/server/modules/message/blockContentPayload"
import {
  collectReadyBlockPhotoIds,
  validateBlockContent,
} from "@in/server/modules/message/blockContent"
import { decryptAgentRef } from "@in/server/modules/agentSessions/crypto"

const log = new Log("MessageModel", LogLevel.INFO)

const previewTitleLength = 180
const previewDescriptionLength = 420
const previewSiteNameLength = 80

export const MessageModel = {
  //deleteMessage: deleteMessage,
  deleteMessages: deleteMessages,
  insertMessage: insertMessage,
  getMessages: getMessages,
  getLatestMessagesForChat: getLatestMessagesForChat,
  getMessagesWithMediaFilter: getMessagesWithMediaFilter,
  getMessage: getMessage, // 1 msg
  getMessageByRandomId: getMessageByRandomId,
  getMessagesByIds: getMessagesByIds,
  getMessagesAroundTarget: getMessagesAroundTarget,
  getNonFullMessagesRange: getNonFullMessagesRange,
  processMessages: processMessages,
  processMessage: processMessage,
  editMessage: editMessage,
  processAttachments: processAttachments,
  getAttachmentsByMessageGlobalIds: getAttachmentsByMessageGlobalIds,
  getNonFullMessagesFromNewToOld: getNonFullMessagesFromNewToOld,
  getSenderIdForMessage: getSenderIdForMessage,
}

export type DbInputFullAttachment = DbMessageAttachment & {
  externalTask?: DbExternalTask | null
  linkEmbed?: (DbLinkEmbed & {
    photo?: InputDbFullPhoto | null
    authorPhoto?: InputDbFullPhoto | null
    video?: InputDbFullVideo | null
    document?: InputDbFullDocument | null
  }) | null
}

export type DbInputFullMessage = DbMessage & {
  from: DbUser
  reactions: DbReaction[]
  photo: InputDbFullPhoto | null
  video: InputDbFullVideo | null
  document: InputDbFullDocument | null
  voice?: InputDbFullVoice | null
  messageAttachments?: DbInputFullAttachment[]
  blockContent?: DbBlockContent | null
  agentSession?: AgentSessionMessageInfo
}

export type MessageMediaFilter = "photos" | "videos" | "photo_video" | "documents" | "links" | "voice_memos"

export type ProcessedMessage = Omit<
  DbMessage,
  | "textEncrypted"
  | "textIv"
  | "textTag"
  | "entitiesEncrypted"
  | "entitiesIv"
  | "entitiesTag"
  | "actionsEncrypted"
  | "actionsIv"
  | "actionsTag"
  | "systemMessageEncrypted"
  | "systemMessageIv"
  | "systemMessageTag"
> & {
  text: string | null
  entities: MessageEntities | null
  actions?: MessageActions | null
  systemMessage: SystemMessage | null
  blockContent: BlockContent | null
}

export type ProcessedMessageTranslation = Omit<
  DbTranslation,
  "translation" | "translationIv" | "translationTag" | "entities"
> & {
  translation: string | null

  /** entities in the translation */
  entities: MessageEntities | null
}

export type ProcessedMessageAndTranslation = ProcessedMessage & {
  translation: ProcessedMessageTranslation | null
}

export type DbFullMessage = Omit<
  DbMessage,
  | "textEncrypted"
  | "textIv"
  | "textTag"
  | "entitiesEncrypted"
  | "entitiesIv"
  | "entitiesTag"
  | "actionsEncrypted"
  | "actionsIv"
  | "actionsTag"
  | "systemMessageEncrypted"
  | "systemMessageIv"
  | "systemMessageTag"
> & {
  text: string | null
  entities: MessageEntities | null
  actions?: MessageActions | null
  systemMessage: SystemMessage | null
  blockContent: BlockContent | null
  blockContentPhotos?: ReadonlyMap<bigint, DbFullPhoto>
  from: DbUser
  reactions: DbReaction[]
  photo: DbFullPhoto | null
  video: DbFullVideo | null
  document: DbFullDocument | null
  voice: DbFullVoice | null
  messageAttachments?: ProcessedAttachment[]
  agentSession?: AgentSessionMessageInfo
}

export type ProcessedExternalTask = Omit<DbExternalTask, "title" | "titleIv" | "titleTag"> & {
  title: string | null
}

export type ProcessedLinkEmbed = Omit<
  DbLinkEmbed,
  | "url"
  | "urlIv"
  | "urlTag"
  | "title"
  | "titleIv"
  | "titleTag"
  | "description"
  | "descriptionIv"
  | "descriptionTag"
  | "author"
  | "authorIv"
  | "authorTag"
  | "externalUrl"
  | "externalUrlIv"
  | "externalUrlTag"
  | "embedUrl"
  | "embedUrlIv"
  | "embedUrlTag"
> & {
  url: string | null
  title: string | null
  description: string | null
  author: string | null
  externalUrl: string | null
  embedUrl: string | null
  photo?: DbFullPhoto | null
  authorPhoto?: DbFullPhoto | null
  video?: DbFullVideo | null
  document?: DbFullDocument | null
}

export type ProcessedAttachment = Omit<DbMessageAttachment, "externalTask" | "linkEmbed"> & {
  externalTask?: ProcessedExternalTask | null
  linkEmbed?: ProcessedLinkEmbed | null
}

export type ProcessedMessageAttachment = Omit<DbMessageAttachment, "externalTask" | "linkEmbed"> & {
  externalTask?: ProcessedExternalTask | null
  linkEmbed?: ProcessedLinkEmbed | null
}

function cleanStoredPreviewText(value: string | null | undefined, maxLength: number): string | null {
  return cleanPreviewText(value, maxLength)
}

function cleanStoredPreviewDescription(value: string | null | undefined): string | null {
  return cleanMultilinePreviewText(value, previewDescriptionLength)
}

type GetMessagesMode = "latest" | "older" | "newer" | "around"

type GetMessagesInput = {
  currentUserId: number
  offsetId?: bigint
  limit?: number
  mode?: GetMessagesMode
  beforeId?: bigint
  afterId?: bigint
  anchorId?: bigint
  beforeLimit?: number
  afterLimit?: number
  includeAnchor?: boolean
}

const fullPhotoRelations = {
  with: {
    photoSizes: {
      with: {
        file: true,
      },
    },
  },
} as const

const fullVideoRelations = {
  with: {
    file: true,
    photo: fullPhotoRelations,
  },
} as const

const fullDocumentRelations = {
  with: {
    file: true,
    photo: fullPhotoRelations,
  },
} as const

const fullVoiceRelations = {
  with: {
    file: true,
  },
} as const

const messageAttachmentRelations = {
  externalTask: true,
  linkEmbed: {
    with: {
      photo: fullPhotoRelations,
      authorPhoto: fullPhotoRelations,
      video: fullVideoRelations,
      document: fullDocumentRelations,
    },
  },
} as const

// Keep attachments out of message-root relation trees. Drizzle builds aliases from
// the full relation path, and Postgres truncates identifiers over 63 bytes.
const fullMessageRelations = {
  from: true,
  reactions: true,
  photo: fullPhotoRelations,
  video: fullVideoRelations,
  document: fullDocumentRelations,
  voice: fullVoiceRelations,
  blockContent: true,
} as const

function getResolvedHistoryMode(input: GetMessagesInput): GetMessagesMode {
  if (input.mode) {
    return input.mode
  }

  // Legacy compatibility: offset_id implies older-page mode.
  if (input.offsetId !== undefined) {
    return "older"
  }

  return "latest"
}

async function getAttachmentsByMessageGlobalIds(globalIds: bigint[]): Promise<Map<bigint, DbInputFullAttachment[]>> {
  const ids = Array.from(new Set(globalIds))
  const byMessageId = new Map<bigint, DbInputFullAttachment[]>()

  if (ids.length === 0) {
    return byMessageId
  }

  const attachments = await db._query.messageAttachments.findMany({
    where: inArray(messageAttachments.messageId, ids),
    orderBy: asc(messageAttachments.id),
    with: messageAttachmentRelations,
  })

  for (const attachment of attachments) {
    if (attachment.messageId === null) {
      continue
    }

    let list = byMessageId.get(attachment.messageId)
    if (!list) {
      list = []
      byMessageId.set(attachment.messageId, list)
    }

    list.push(attachment)
  }

  return byMessageId
}

async function addMessageAttachments(messagesList: DbInputFullMessage[]): Promise<DbInputFullMessage[]> {
  const attachmentsByMessageId = await getAttachmentsByMessageGlobalIds(messagesList.map((message) => message.globalId))

  return messagesList.map((message) => ({
    ...message,
    messageAttachments: attachmentsByMessageId.get(message.globalId) ?? [],
  }))
}

async function addAgentSessionInfo(messagesList: DbInputFullMessage[]): Promise<DbInputFullMessage[]> {
  const globalIds = Array.from(new Set(messagesList.map((message) => message.globalId)))
  if (globalIds.length === 0) return messagesList

  const rows = await db
    .select({
      messageGlobalId: agentSessionMessages.messageGlobalId,
      agentSessionId: agentSessionMessages.agentSessionId,
      provider: agentSessions.provider,
      role: agentSessionMessages.role,
      relation: agentSessionMessages.relation,
    })
    .from(agentSessionMessages)
    .innerJoin(agentSessions, eq(agentSessions.id, agentSessionMessages.agentSessionId))
    .where(inArray(agentSessionMessages.messageGlobalId, globalIds))

  const byMessageGlobalId = new Map<bigint, AgentSessionMessageInfo>()
  const ambiguousMessageGlobalIds = new Set<bigint>()
  for (const row of rows) {
    if (row.messageGlobalId === null) continue
    if (ambiguousMessageGlobalIds.has(row.messageGlobalId)) continue
    if (byMessageGlobalId.has(row.messageGlobalId)) {
      byMessageGlobalId.delete(row.messageGlobalId)
      ambiguousMessageGlobalIds.add(row.messageGlobalId)
      continue
    }
    byMessageGlobalId.set(row.messageGlobalId, {
      agentSessionId: row.agentSessionId,
      provider: row.provider,
      role: row.role,
      relation: row.relation,
    })
  }

  return messagesList.map((message) => ({
    ...message,
    agentSession: byMessageGlobalId.get(message.globalId),
  }))
}

async function processMessages(messagesList: DbInputFullMessage[]): Promise<DbFullMessage[]> {
  const hydrated = await addAgentSessionInfo(await addMessageAttachments(messagesList))
  const processed = hydrated.map(processMessage)
  const readyPhotoIdsByMessage = processed.map((message) =>
    message.blockContent ? collectReadyBlockPhotoIds(message.blockContent) : []
  )
  const readyPhotoIds = readyPhotoIdsByMessage.flat()
  if (readyPhotoIds.length === 0) return processed

  const photos = await FileModel.getPhotosByIds(readyPhotoIds)
  if (photos.length === 0) return processed

  const photosById = new Map(photos.map((photo) => [BigInt(photo.id), photo]))
  return processed.map((message, index) => {
    const blockContentPhotos = new Map<bigint, DbFullPhoto>()
    for (const photoId of readyPhotoIdsByMessage[index] ?? []) {
      const photo = photosById.get(photoId)
      if (photo) blockContentPhotos.set(photoId, photo)
    }
    return blockContentPhotos.size > 0 ? { ...message, blockContentPhotos } : message
  })
}

async function getMessages(
  inputPeer: InputPeer,
  input: GetMessagesInput,
): Promise<DbFullMessage[]> {
  const { currentUserId } = input
  let chatId = await ChatModel.getChatIdFromInputPeer(inputPeer, { currentUserId })

  if (!chatId) {
    throw ModelError.ChatInvalid
  }

  const mode = getResolvedHistoryMode(input)

  if (mode === "latest") {
    const latestMessages = await db._query.messages.findMany({
      where: eq(messages.chatId, chatId),
      orderBy: desc(messages.messageId),
      limit: input.limit ?? 60,
      with: fullMessageRelations,
    })

    return processMessages(latestMessages)
  }

  if (mode === "older") {
    const beforeId = input.beforeId ?? input.offsetId
    const beforeIdNumber = beforeId ? Number(beforeId) : undefined

    const olderMessages = await db._query.messages.findMany({
      where: beforeIdNumber
        ? and(eq(messages.chatId, chatId), lt(messages.messageId, beforeIdNumber))
        : eq(messages.chatId, chatId),
      orderBy: desc(messages.messageId),
      limit: input.limit ?? 60,
      with: fullMessageRelations,
    })

    return processMessages(olderMessages)
  }

  if (mode === "newer") {
    if (input.afterId === undefined) {
      return []
    }

    const afterIdNumber = Number(input.afterId)

    const newerMessagesAsc = await db._query.messages.findMany({
      where: and(eq(messages.chatId, chatId), gt(messages.messageId, afterIdNumber)),
      orderBy: asc(messages.messageId),
      limit: input.limit ?? 60,
      with: fullMessageRelations,
    })

    newerMessagesAsc.reverse()
    return processMessages(newerMessagesAsc)
  }

  // mode === "around"
  if (input.anchorId === undefined) {
    return []
  }

  const anchorIdNumber = Number(input.anchorId)
  const includeAnchor = input.includeAnchor ?? true
  const aroundLimit = input.limit ?? 60
  const combinedAround = await db.transaction(
    async (tx) => {
      const anchorMessages = includeAnchor
        ? await tx._query.messages.findMany({
            where: and(eq(messages.chatId, chatId), eq(messages.messageId, anchorIdNumber)),
            limit: 1,
            with: fullMessageRelations,
          })
        : []

      const defaultBeforeLimit = Math.floor(aroundLimit / 2)
      const defaultAfterLimit = Math.max(aroundLimit - defaultBeforeLimit - anchorMessages.length, 0)
      const beforeLimit = Math.max(input.beforeLimit ?? defaultBeforeLimit, 0)
      const afterLimit = Math.max(input.afterLimit ?? defaultAfterLimit, 0)

      const beforeMessages =
        beforeLimit > 0
          ? await tx._query.messages.findMany({
              where: and(eq(messages.chatId, chatId), lt(messages.messageId, anchorIdNumber)),
              orderBy: desc(messages.messageId),
              limit: beforeLimit,
              with: fullMessageRelations,
            })
          : []
      const afterMessages =
        afterLimit > 0
          ? await tx._query.messages.findMany({
              where: and(eq(messages.chatId, chatId), gt(messages.messageId, anchorIdNumber)),
              orderBy: asc(messages.messageId),
              limit: afterLimit,
              with: fullMessageRelations,
            })
          : []

      return [...beforeMessages, ...anchorMessages, ...afterMessages]
    },
    { isolationLevel: "repeatable read", accessMode: "read only" },
  )

  combinedAround.sort((a, b) => b.messageId - a.messageId)

  return processMessages(combinedAround)
}

/** Reads the newest message identities and core rows from an existing snapshot. */
async function getLatestMessagesForChat(
  chatId: number,
  limit: number,
  tx: Transaction,
): Promise<DbFullMessage[]> {
  const latestMessages = await tx._query.messages.findMany({
    where: eq(messages.chatId, chatId),
    orderBy: desc(messages.messageId),
    limit,
    with: fullMessageRelations,
  })

  return processMessages(latestMessages)
}

async function getMessagesWithMediaFilter(input: {
  chatId: number
  offsetId?: bigint
  limit: number
  filter: MessageMediaFilter
}): Promise<DbFullMessage[]> {
  const offsetIdNumber = input.offsetId ? Number(input.offsetId) : undefined
  const baseWhereClause = offsetIdNumber
    ? and(eq(messages.chatId, input.chatId), lt(messages.messageId, offsetIdNumber))
    : eq(messages.chatId, input.chatId)
  const mediaClause = buildMediaFilterClause(input.filter)
  const whereClause = and(baseWhereClause, mediaClause)

  const result = await db._query.messages.findMany({
    where: whereClause,
    orderBy: desc(messages.messageId),
    limit: input.limit,
    with: fullMessageRelations,
  })

  return processMessages(result)
}

function buildMediaFilterClause(filter: MessageMediaFilter) {
  switch (filter) {
    case "photos":
      return not(isNull(messages.photoId))
    case "videos":
      return not(isNull(messages.videoId))
    case "photo_video":
      return or(not(isNull(messages.photoId)), not(isNull(messages.videoId)))
    case "documents":
      return not(isNull(messages.documentId))
    case "links":
      return eq(messages.hasLink, true)
    case "voice_memos":
      return not(isNull(messages.voiceId))
  }
}

function processMessage(message: DbInputFullMessage): DbFullMessage {
  const text =
    message.textEncrypted && message.textIv && message.textTag
      ? decryptMessage({
          encrypted: message.textEncrypted,
          iv: message.textIv,
          authTag: message.textTag,
        })
      : message.text
  const entities =
    message.entitiesEncrypted && message.entitiesIv && message.entitiesTag
      ? MessageEntities.fromBinary(
          decryptBinary({
            encrypted: message.entitiesEncrypted,
            iv: message.entitiesIv,
            authTag: message.entitiesTag,
          }),
        )
      : null

  return {
    ...message,
    text,
    entities,
    actions:
      message.actionsEncrypted && message.actionsIv && message.actionsTag
        ? MessageActions.fromBinary(
            decryptBinary({
              encrypted: message.actionsEncrypted,
              iv: message.actionsIv,
              authTag: message.actionsTag,
            }),
          )
        : null,
    systemMessage:
      message.systemMessageEncrypted && message.systemMessageIv && message.systemMessageTag
        ? decryptSystemMessagePayload({
            encrypted: message.systemMessageEncrypted,
            iv: message.systemMessageIv,
            authTag: message.systemMessageTag,
          })
        : null,
    blockContent: decodeBlockContentProjection(message.blockContent, text, entities),
    photo: message.photo ? FileModel.processFullPhoto(message.photo) : null,
    video: message.video ? FileModel.processFullVideo(message.video) : null,
    document: message.document ? FileModel.processFullDocument(message.document) : null,
    voice: message.voice ? FileModel.processFullVoice(message.voice) : null,
    messageAttachments: message.messageAttachments ? processAttachments(message.messageAttachments) : [],
  }
}

function decodeBlockContentProjection(
  row: DbBlockContent | null | undefined,
  text: string | null,
  entities: MessageEntities | null,
): BlockContent | null {
  if (!row || text === null) return null

  try {
    const stored = decryptStoredBlockContent({
      encrypted: row.payloadEncrypted,
      iv: row.payloadIv,
      authTag: row.payloadTag,
    })

    const textMatches = stored.text === text
    const entitiesMatch = equalMessageEntities(stored.entities, entities)
    if (!textMatches || !entitiesMatch) {
      const mismatchKind = !textMatches && !entitiesMatch
        ? "text_and_entities"
        : textMatches
          ? "entities"
          : "text"
      log.error("block content mirror mismatch", {
        mismatchKind,
        contentSchemaVersion: row.schemaVersion,
        contentRevision: row.revision,
      })
      return null
    }

    validateBlockContent(text, stored.blockContent, "persisted")
    return stored.blockContent
  } catch (error) {
    log.error("invalid block content projection", {
      contentSchemaVersion: row.schemaVersion,
      contentRevision: row.revision,
      errorType: error instanceof Error ? error.name : "UnknownError",
    })
    return null
  }
}

function equalMessageEntities(left: MessageEntities | undefined, right: MessageEntities | null): boolean {
  const leftBytes = left ? MessageEntities.toBinary(left) : new Uint8Array()
  const rightBytes = right ? MessageEntities.toBinary(right) : new Uint8Array()
  return Buffer.from(leftBytes).equals(Buffer.from(rightBytes))
}

type InsertMessageOutput = {
  message: DbMessage & { blockContent?: BlockContent | null }
  update: UpdateSeqAndDate
  agentContextUpdate?: UpdateSeqAndDate
}

async function insertMessage(
  message: Omit<DbNewMessage, "messageId">,
  preparedBlockContent?: PreparedBlockContent,
  transaction?: Transaction,
  initialAgentContext?: { value: AgentThreadContext; encoded: Uint8Array },
): Promise<InsertMessageOutput> {
  const chatId = message.chatId

  const insert = async (tx: Transaction): Promise<InsertMessageOutput> => {
    // First lock the specific chat row
    const [chat] = await tx
      .select()
      .from(chats)
      .where(eq(chats.id, message.chatId))
      .for("update") // This locks the row
      .limit(1)

    if (!chat) {
      throw ModelError.ChatInvalid
    }

    if (initialAgentContext && chat.agentContext !== null) {
      throw ModelError.AgentContextAlreadySet
    }

    if (initialAgentContext) {
      const [existingSession] = await tx
        .select({
          botUserId: agentSessions.botUserId,
          projectRefEncrypted: agentSessions.projectRefEncrypted,
        })
        .from(agentSessions)
        .where(eq(agentSessions.chatId, chat.id))
        .limit(1)
      const selectedProjectId = initialAgentContext.value.configuration?.projectId
      if (
        existingSession &&
        (
          existingSession.botUserId !== Number(initialAgentContext.value.botUserId) ||
          (
            selectedProjectId !== undefined &&
            (
              existingSession.projectRefEncrypted === null ||
              decryptAgentRef(existingSession.projectRefEncrypted) !== selectedProjectId
            )
          )
        )
      ) {
        throw ModelError.AgentContextAlreadySet
      }
    }

    const agentContextUpdate = initialAgentContext
      ? await UpdatesModel.insertUpdate(tx, {
          update: {
            oneofKind: "chatInfo",
            chatInfo: {
              chatId: BigInt(chat.id),
              agentContext: initialAgentContext.value,
            },
          },
          bucket: UpdateBucket.Chat,
          entity: chat,
        })
      : undefined

    const nextId = ChatModel.nextMessageId(chat)
    const blockContentId = preparedBlockContent
      ? await insertPreparedBlockContent(tx, preparedBlockContent, 0)
      : null

    // Insert the new message
    const [newDbMessage] = await tx
      .insert(messages)
      .values({
        ...message,
        chatId: chatId,
        messageId: nextId,
        blockContentId,
      })
      .returning()

    if (!newDbMessage) {
      throw ModelError.Failed
    }

    // Insert update
    const update = await UpdatesModel.insertUpdate(tx, {
      update: {
        oneofKind: "newMessage",
        newMessage: {
          chatId: BigInt(chatId),
          msgId: BigInt(nextId),
        },
      },
      bucket: UpdateBucket.Chat,
      entity: agentContextUpdate ? { ...chat, updateSeq: agentContextUpdate.seq } : chat,
    })

    // Update chat's PTS and lastMsgId
    await tx
      .update(chats)
      .set({
        lastMsgId: nextId,
        messageIdCounter: nextId,
        updateSeq: update.seq,
        lastUpdateDate: update.date,
        ...(initialAgentContext ? { agentContext: Buffer.from(initialAgentContext.encoded) } : {}),
      })
      .where(eq(chats.id, chatId))

    return {
      message: {
        ...newDbMessage,
        blockContent: preparedBlockContent?.blockContent ?? null,
      },
      update,
      agentContextUpdate,
    }
  }

  return transaction ? insert(transaction) : db.transaction(insert)
}

// /** Deletes a message from a chat */
// async function deleteMessage(messageId: number, chatId: number) {
//   log.trace("deleteMessage", { messageId, chatId })

//   let deleted = await db
//     .delete(messages)
//     .where(and(eq(messages.chatId, chatId), eq(messages.messageId, messageId)))
//     .returning()

//   if (deleted.length === 0) {
//     log.trace("message not found", { messageId, chatId })
//     throw ModelError.MessageInvalid
//   }

//   await ChatModel.refreshLastMessageId(chatId)
//   log.trace("refreshed last message id after deletion")
// }

/**
 * Deletes multiple messages from a chat
 **/
async function deleteMessages(
  messageIds: bigint[],
  chatId: number,
): Promise<{
  update: UpdateSeqAndDate
  metadataChatUpdates: ChatMetadataUpdate[]
}> {
  log.trace("deleteMessages", { messageIds, chatId })

  // Use a transaction with FOR UPDATE to lock the row while we're working with it
  let { update, metadataChatUpdates } = await db.transaction(async (tx) => {
    let [chat] = await tx.select().from(chats).where(eq(chats.id, chatId)).for("update")

    if (!chat) throw ModelError.ChatInvalid

    const messageIdsNum = messageIds.map((id) => Number(id))

    // Clear first to allow for deleting
    await tx.update(chats).set({ lastMsgId: null }).where(eq(chats.id, chatId))

    const orphanedChatIds = await orphanReplyThreadsForDeletedMessages(tx, chatId, messageIdsNum)

    // Delete message
    let deleted = await tx
      .delete(messages)
      .where(
        and(
          eq(messages.chatId, chatId),
          inArray(messages.messageId, messageIdsNum),
        ),
      )
      .returning()

    if (deleted.length === 0) {
      log.trace("messages not found", { messageIds, chatId })
      throw ModelError.MessageInvalid
    }

    await deleteUnreferencedBlockContents(
      tx,
      deleted.flatMap((message) => message.blockContentId ? [message.blockContentId] : []),
    )

    let [message] = await tx
      .select({ messageId: messages.messageId })
      .from(messages)
      .where(eq(messages.chatId, chatId))
      .orderBy(desc(messages.messageId))
      .limit(1)

    const newLastMsgId = message?.messageId ?? null

    // Insert update
    const update = await UpdatesModel.insertUpdate(tx, {
      update: {
        oneofKind: "deleteMessages",
        deleteMessages: {
          chatId: BigInt(chatId),
          msgIds: messageIds,
        },
      },
      bucket: UpdateBucket.Chat,
      entity: chat,
    })

    await tx
      .update(chats)
      .set({
        // Update last message
        lastMsgId: newLastMsgId,
        // Update PTS and update date
        updateSeq: update.seq,
        lastUpdateDate: update.date,
      })
      .where(eq(chats.id, chatId))

    const metadataChatUpdates = await persistChatMetadataUpdates(tx, orphanedChatIds)

    return { update, metadataChatUpdates }
  })

  return { update, metadataChatUpdates }
}

async function orphanReplyThreadsForDeletedMessages(
  tx: Transaction,
  chatId: number,
  messageIds: number[],
): Promise<number[]> {
  const uniqueMessageIds = Array.from(new Set(messageIds))
  if (uniqueMessageIds.length === 0) {
    return []
  }

  const rows = await tx
    .update(chats)
    .set({ parentMessageId: null })
    .where(and(eq(chats.parentChatId, chatId), inArray(chats.parentMessageId, uniqueMessageIds)))
    .returning({ chatId: chats.id })

  return rows.map((row) => row.chatId)
}

type EditMessageInput = {
  messageId: number
  chatId: number
  text: string
  entities?: MessageEntities
  actions?: MessageActions
  blockContent?: PreparedBlockContent | null
  /** Bot/agent streaming edits reuse this mutation without presenting as user edits. */
  suppressEditDate?: boolean
}

async function editMessage(input: EditMessageInput): Promise<{
  message: DbMessage & { blockContent?: BlockContent | null }
  update: UpdateSeqAndDate
}> {
  let { messageId, chatId, text, entities, actions } = input

  const encryptedMessage = text ? encryptMessage(text) : null
  const binaryEntities = entities ? MessageEntities.toBinary(entities) : null
  const encryptedEntities = binaryEntities && binaryEntities.length > 0
    ? encryptMessageEntities(binaryEntities)
    : null
  const binaryActions = actions ? MessageActions.toBinary(actions) : undefined
  const encryptedActions = binaryActions && binaryActions.length > 0 ? encryptBinary(binaryActions) : undefined
  const hasLink = detectHasLink({ entities })

  let { message, update } = await db.transaction(async (tx) => {
    // First lock the specific chat row
    const [chat] = await tx
      .select()
      .from(chats)
      .where(eq(chats.id, chatId))
      .for("update") // This locks the row
      .limit(1)

    if (!chat) {
      throw ModelError.ChatInvalid
    }

    const [currentMessage] = await tx
      .select({ blockContentId: messages.blockContentId })
      .from(messages)
      .where(and(eq(messages.chatId, chatId), eq(messages.messageId, messageId)))
      .for("update")
      .limit(1)

    if (!currentMessage) {
      throw ModelError.MessageInvalid
    }

    let nextBlockContentId = currentMessage.blockContentId
    if (input.blockContent) {
      if (currentMessage.blockContentId) {
        const [currentContent] = await tx
          .select({ revision: blockContents.revision })
          .from(blockContents)
          .where(eq(blockContents.id, currentMessage.blockContentId))
          .for("update")
          .limit(1)
        if (currentContent) {
          await replacePreparedBlockContent({
            tx,
            contentId: currentMessage.blockContentId,
            currentRevision: currentContent.revision,
            prepared: input.blockContent,
          })
        } else {
          nextBlockContentId = await insertPreparedBlockContent(tx, input.blockContent, 0)
        }
      } else {
        nextBlockContentId = await insertPreparedBlockContent(tx, input.blockContent, 0)
      }
    } else if (input.blockContent === null) {
      nextBlockContentId = null
    }

    const updatePayload: Record<string, unknown> = {
      editDate: input.suppressEditDate ? null : new Date(),
      rev: sql`${messages.rev} + 1`,
      // text
      text: null,
      textEncrypted: encryptedMessage?.encrypted ?? null,
      textIv: encryptedMessage?.iv ?? null,
      textTag: encryptedMessage?.authTag ?? null,
      // entities
      entitiesEncrypted: encryptedEntities?.encrypted ?? null,
      entitiesIv: encryptedEntities?.iv ?? null,
      entitiesTag: encryptedEntities?.authTag ?? null,
      hasLink: hasLink,
      blockContentId: nextBlockContentId,
    }

    // Optional action replacement semantics:
    // - undefined => keep existing
    // - empty rows => clear
    // - non-empty rows => replace
    if (actions !== undefined) {
      if ((actions.rows?.length ?? 0) === 0) {
        updatePayload["actionsEncrypted"] = null
        updatePayload["actionsIv"] = null
        updatePayload["actionsTag"] = null
      } else {
        updatePayload["actionsEncrypted"] = encryptedActions?.encrypted ?? null
        updatePayload["actionsIv"] = encryptedActions?.iv ?? null
        updatePayload["actionsTag"] = encryptedActions?.authTag ?? null
      }
    }

    // Confirm the message mutation before allocating a durable edit update.
    // If the message was deleted concurrently, throwing inside this
    // transaction rolls back both the message-side work and the chat update
    // sequence instead of committing a ghost edit update.
    const [editedMessage] = await tx
      .update(messages)
      .set(updatePayload)
      .where(and(eq(messages.chatId, chatId), eq(messages.messageId, messageId)))
      .returning()

    if (!editedMessage) {
      log.trace("message not found", { messageId, chatId })
      throw ModelError.MessageInvalid
    }

    if (input.blockContent === null && currentMessage.blockContentId) {
      await deleteUnreferencedBlockContents(tx, [currentMessage.blockContentId])
    }

    const update = await UpdatesModel.insertUpdate(tx, {
      update: {
        oneofKind: "editMessage",
        editMessage: {
          chatId: BigInt(chatId),
          msgId: BigInt(messageId),
        },
      },
      bucket: UpdateBucket.Chat,
      entity: chat,
    })

    await tx
      .update(chats)
      .set({
        updateSeq: update.seq,
        lastUpdateDate: update.date,
      })
      .where(eq(chats.id, chatId))

    return {
      message: {
        ...editedMessage,
        blockContent:
          input.blockContent === undefined
            ? undefined
            : input.blockContent?.blockContent ?? null,
      },
      update,
    }
  })

  return { message, update }
}

async function getMessageByRandomId(randomId: bigint, fromId: number): Promise<DbMessage> {
  let result = await db.query.messages.findMany({
    where: { randomId, fromId },
  })

  // Only one message should be found
  if (result.length !== 1) {
    log.trace("this should never happen: message not found by random id", { randomId, fromId })
    throw ModelError.MessageInvalid
  }

  return result[0]!
}

async function getMessage(messageId: number, chatId: number): Promise<DbFullMessage> {
  let result = await db._query.messages.findFirst({
    where: and(eq(messages.chatId, chatId), eq(messages.messageId, messageId)),
    with: fullMessageRelations,
  })

  if (!result) {
    throw ModelError.MessageInvalid
  }

  const [message] = await processMessages([result])
  return message!
}

/**
 * Decrypts a message translation
 * @param translation - The translation to decrypt
 * @returns The decrypted translation
 */
export function processMessageTranslation(translation: DbTranslation): ProcessedMessageTranslation {
  return {
    ...translation,
    translation:
      translation.translation && translation.translationIv && translation.translationTag
        ? decrypt({
            encrypted: translation.translation,
            iv: translation.translationIv,
            authTag: translation.translationTag,
          })
        : null,

    entities: translation.entities ? MessageEntities.fromBinary(Encryption2.decryptBinary(translation.entities)) : null,
  }
}

export function processAttachments(
  attachments: (DbMessageAttachment & {
    externalTask?: DbExternalTask | null
    linkEmbed?: (DbLinkEmbed & {
      photo?: InputDbFullPhoto | null
      authorPhoto?: InputDbFullPhoto | null
      video?: InputDbFullVideo | null
      document?: InputDbFullDocument | null
    }) | null
  })[],
): ProcessedMessageAttachment[] {
  return attachments.map((attachment) => {
    const { externalTask: _externalTask, linkEmbed: _linkEmbed, ...rest } = attachment
    let processed: ProcessedMessageAttachment = { ...rest }

    // Process externalTask if present
    if (attachment.externalTask) {
      // Omit encrypted fields from the spread
      const { title, titleIv, titleTag, ...rest } = attachment.externalTask
      processed.externalTask = {
        ...rest,
        title:
          title && titleIv && titleTag
            ? decrypt({
                encrypted: title,
                iv: titleIv,
                authTag: titleTag,
              })
            : null,
      }
    }

    // Process linkEmbed (url preview) if present
    if (attachment.linkEmbed) {
      const {
        url,
        urlIv,
        urlTag,
        title: linkTitle,
        titleIv: linkTitleIv,
        titleTag: linkTitleTag,
        description,
        descriptionIv,
        descriptionTag,
        author,
        authorIv,
        authorTag,
        externalUrl,
        externalUrlIv,
        externalUrlTag,
        embedUrl,
        embedUrlIv,
        embedUrlTag,
        photo,
        authorPhoto,
        video,
        document,
        ...rest
      } = attachment.linkEmbed
      processed.linkEmbed = {
        ...rest,
        siteName: cleanStoredPreviewText(rest.siteName, previewSiteNameLength),
        url:
          url && urlIv && urlTag
            ? decrypt({
                encrypted: url,
                iv: urlIv,
                authTag: urlTag,
              })
            : null,
        title:
          linkTitle && linkTitleIv && linkTitleTag
            ? cleanStoredPreviewText(
                decrypt({
                  encrypted: linkTitle,
                  iv: linkTitleIv,
                  authTag: linkTitleTag,
                }),
                previewTitleLength,
              )
            : null,
        description:
          description && descriptionIv && descriptionTag
            ? cleanStoredPreviewDescription(
                decrypt({
                  encrypted: description,
                  iv: descriptionIv,
                  authTag: descriptionTag,
                }),
              )
            : null,
        author:
          author && authorIv && authorTag
            ? cleanStoredPreviewText(
                decrypt({
                  encrypted: author,
                  iv: authorIv,
                  authTag: authorTag,
                }),
                previewSiteNameLength,
              )
            : null,
        externalUrl:
          externalUrl && externalUrlIv && externalUrlTag
            ? decrypt({
                encrypted: externalUrl,
                iv: externalUrlIv,
                authTag: externalUrlTag,
              })
            : null,
        embedUrl:
          embedUrl && embedUrlIv && embedUrlTag
            ? decrypt({
                encrypted: embedUrl,
                iv: embedUrlIv,
                authTag: embedUrlTag,
              })
            : null,
        photo: photo ? FileModel.processFullPhoto(photo) : null,
        authorPhoto: authorPhoto ? FileModel.processFullPhoto(authorPhoto) : null,
        video: video ? FileModel.processFullVideo(video) : null,
        document: document ? FileModel.processFullDocument(document) : null,
      }
    }

    return processed
  })
}

async function getNonFullMessagesRange(chatId: number, offsetId: number, limit: number): Promise<ProcessedMessage[]> {
  let result = await db._query.messages.findMany({
    where: and(eq(messages.chatId, chatId), gt(messages.messageId, offsetId)),
    orderBy: desc(messages.messageId),
    limit: limit ?? 60,
  })

  return result.map((msg) => ({
    ...msg,
    text:
      msg.textEncrypted && msg.textIv && msg.textTag
        ? decryptMessage({
            encrypted: msg.textEncrypted,
            iv: msg.textIv,
            authTag: msg.textTag,
          })
        : // legacy fallback
          msg.text,
    entities:
      msg.entitiesEncrypted && msg.entitiesIv && msg.entitiesTag
        ? MessageEntities.fromBinary(
            decryptBinary({ encrypted: msg.entitiesEncrypted, iv: msg.entitiesIv, authTag: msg.entitiesTag }),
          )
        : null,
    actions:
      msg.actionsEncrypted && msg.actionsIv && msg.actionsTag
        ? MessageActions.fromBinary(
            decryptBinary({ encrypted: msg.actionsEncrypted, iv: msg.actionsIv, authTag: msg.actionsTag }),
          )
        : null,
    systemMessage:
      msg.systemMessageEncrypted && msg.systemMessageIv && msg.systemMessageTag
        ? decryptSystemMessagePayload({
            encrypted: msg.systemMessageEncrypted,
            iv: msg.systemMessageIv,
            authTag: msg.systemMessageTag,
          })
        : null,
    blockContent: null,
  }))
}

async function getNonFullMessagesFromNewToOld(input: {
  chatId: number
  newestMsgId: number
  limit: number
}): Promise<ProcessedMessage[]> {
  let result = await db._query.messages.findMany({
    where: and(eq(messages.chatId, input.chatId), lt(messages.messageId, input.newestMsgId)),
    orderBy: desc(messages.messageId),
    limit: input.limit,
  })

  result.reverse()

  return result.map((msg) => ({
    ...msg,
    text:
      msg.textEncrypted && msg.textIv && msg.textTag
        ? decryptMessage({
            encrypted: msg.textEncrypted,
            iv: msg.textIv,
            authTag: msg.textTag,
          })
        : // legacy fallback
          msg.text,
    entities:
      msg.entitiesEncrypted && msg.entitiesIv && msg.entitiesTag
        ? MessageEntities.fromBinary(
            decryptBinary({ encrypted: msg.entitiesEncrypted, iv: msg.entitiesIv, authTag: msg.entitiesTag }),
          )
        : null,
    actions:
      msg.actionsEncrypted && msg.actionsIv && msg.actionsTag
        ? MessageActions.fromBinary(
            decryptBinary({ encrypted: msg.actionsEncrypted, iv: msg.actionsIv, authTag: msg.actionsTag }),
          )
        : null,
    systemMessage:
      msg.systemMessageEncrypted && msg.systemMessageIv && msg.systemMessageTag
        ? decryptSystemMessagePayload({
            encrypted: msg.systemMessageEncrypted,
            iv: msg.systemMessageIv,
            authTag: msg.systemMessageTag,
          })
        : null,
    blockContent: null,
  }))
}

async function getMessagesAroundTarget(
  chatId: number,
  targetMessageId: number,
  beforeCount: number = 15,
  afterCount: number = 15,
): Promise<ProcessedMessage[]> {
  const [messagesBefore, messagesAfter] = await Promise.all([
    // Get messages before the target (older messages) - optimized query
    db._query.messages.findMany({
      where: and(eq(messages.chatId, chatId), lt(messages.messageId, targetMessageId)),
      orderBy: desc(messages.messageId),
      limit: beforeCount,
    }),
    // Get messages after the target (newer messages) - optimized query
    db._query.messages.findMany({
      where: and(eq(messages.chatId, chatId), gt(messages.messageId, targetMessageId)),
      orderBy: asc(messages.messageId),
      limit: afterCount,
    }),
  ])

  // Reverse messagesBefore to get chronological order (oldest first)
  messagesBefore.reverse()

  // Combine in chronological order
  const combinedMessages = [...messagesBefore, ...messagesAfter]

  return combinedMessages.map((msg) => ({
    ...msg,
    text:
      msg.textEncrypted && msg.textIv && msg.textTag
        ? decryptMessage({
            encrypted: msg.textEncrypted,
            iv: msg.textIv,
            authTag: msg.textTag,
          })
        : // legacy fallback
          msg.text,
    entities:
      msg.entitiesEncrypted && msg.entitiesIv && msg.entitiesTag
        ? MessageEntities.fromBinary(
            decryptBinary({ encrypted: msg.entitiesEncrypted, iv: msg.entitiesIv, authTag: msg.entitiesTag }),
          )
        : null,
    actions:
      msg.actionsEncrypted && msg.actionsIv && msg.actionsTag
        ? MessageActions.fromBinary(
            decryptBinary({ encrypted: msg.actionsEncrypted, iv: msg.actionsIv, authTag: msg.actionsTag }),
          )
        : null,
    systemMessage:
      msg.systemMessageEncrypted && msg.systemMessageIv && msg.systemMessageTag
        ? decryptSystemMessagePayload({
            encrypted: msg.systemMessageEncrypted,
            iv: msg.systemMessageIv,
            authTag: msg.systemMessageTag,
          })
        : null,
    blockContent: null,
  }))
}

/**
 * Get the sender ID for a message
 * @param input - The input object containing the chat ID and message IDs
 * @returns The sender ID or null if the message is not found
 */
async function getSenderIdForMessage({
  chatId,
  messageId,
}: {
  chatId: number
  messageId: number
}): Promise<number | undefined> {
  const message = await db.query.messages.findFirst({
    where: {
      chatId,
      messageId,
    },
    columns: {
      fromId: true,
    },
  })

  return message?.fromId ?? undefined
}

async function getMessagesByIds(
  chatId: number,
  messageIds: bigint[],
  options?: { tx?: Transaction },
): Promise<DbFullMessage[]> {
  if (messageIds.length === 0) {
    return []
  }

  const query = options?.tx?._query ?? db._query
  const result = await query.messages.findMany({
    where: and(
      eq(messages.chatId, chatId),
      inArray(
        messages.messageId,
        messageIds.map((id) => Number(id)),
      ),
    ),
    with: fullMessageRelations,
  })

  return processMessages(result)
}
