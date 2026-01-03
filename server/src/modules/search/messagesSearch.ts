import { db } from "@in/server/db"
import { messages } from "@in/server/db/schema"
import { documents } from "@in/server/db/schema/media"
import { decryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { Log } from "@in/server/utils/log"
import { and, desc, eq, isNull, lt, not, or } from "drizzle-orm"

const log = new Log("modules/search/messages")

const DEFAULT_BATCH_SIZE = 1000

type SearchRow = {
  messageId: number
  text: string | null
  textEncrypted: Buffer | null
  textIv: Buffer | null
  textTag: Buffer | null
  documentFileName: Buffer | null
  documentFileNameIv: Buffer | null
  documentFileNameTag: Buffer | null
}

type SearchMessagesInput = {
  chatId: number
  keywordGroups: string[][]
  maxResults: number
  batchSize?: number
  beforeMessageId?: number
  mediaFilter?: MessageMediaFilter
}

export const MessageSearchModule = {
  searchMessagesInChat,
}

export type MessageMediaFilter = "photos" | "videos" | "photo_video" | "documents"

async function searchMessagesInChat(input: SearchMessagesInput): Promise<bigint[]> {
  if (input.maxResults <= 0 || input.keywordGroups.length === 0) {
    return []
  }

  const batchSize = input.batchSize && input.batchSize > 0 ? input.batchSize : DEFAULT_BATCH_SIZE
  const matchedMessageIds: bigint[] = []
  let cursor: number | undefined = input.beforeMessageId

  while (matchedMessageIds.length < input.maxResults) {
    let batch = await fetchSearchBatch(input.chatId, cursor, batchSize, input.mediaFilter)

    if (batch.length === 0) {
      break
    }

    for (const row of batch) {
      if (matchedMessageIds.length >= input.maxResults) {
        break
      }

      const searchText = getSearchText(row)
      if (!searchText) {
        continue
      }

      if (matchesQueryGroups(searchText, input.keywordGroups)) {
        matchedMessageIds.push(BigInt(row.messageId))
      }
    }

    cursor = batch[batch.length - 1]?.messageId
    batch = []
  }

  return matchedMessageIds
}

async function fetchSearchBatch(
  chatId: number,
  beforeMessageId: number | undefined,
  limit: number,
  mediaFilter: MessageMediaFilter | undefined,
): Promise<SearchRow[]> {
  const baseWhereClause = beforeMessageId
    ? and(eq(messages.chatId, chatId), lt(messages.messageId, beforeMessageId))
    : eq(messages.chatId, chatId)
  const mediaClause = buildMediaFilterClause(mediaFilter)
  const whereClause = mediaClause ? and(baseWhereClause, mediaClause) : baseWhereClause

  return db
    .select({
      messageId: messages.messageId,
      text: messages.text,
      textEncrypted: messages.textEncrypted,
      textIv: messages.textIv,
      textTag: messages.textTag,
      documentFileName: documents.fileName,
      documentFileNameIv: documents.fileNameIv,
      documentFileNameTag: documents.fileNameTag,
    })
    .from(messages)
    .leftJoin(documents, eq(messages.documentId, documents.id))
    .where(whereClause)
    .orderBy(desc(messages.messageId))
    .limit(limit)
}

function buildMediaFilterClause(filter: MessageMediaFilter | undefined) {
  switch (filter) {
    case "photos":
      return not(isNull(messages.photoId))
    case "videos":
      return not(isNull(messages.videoId))
    case "photo_video":
      return or(not(isNull(messages.photoId)), not(isNull(messages.videoId)))
    case "documents":
      return not(isNull(messages.documentId))
    default:
      return undefined
  }
}

function getMessageText(row: SearchRow): string | null {
  if (row.textEncrypted && row.textIv && row.textTag) {
    try {
      return decryptMessage({
        encrypted: row.textEncrypted,
        iv: row.textIv,
        authTag: row.textTag,
      })
    } catch (error) {
      log.warn("Failed to decrypt message text during search", error)
      return null
    }
  }

  return row.text ?? null
}

function getDocumentFileName(row: SearchRow): string | null {
  if (row.documentFileName && row.documentFileNameIv && row.documentFileNameTag) {
    try {
      return decrypt({
        encrypted: row.documentFileName,
        iv: row.documentFileNameIv,
        authTag: row.documentFileNameTag,
      })
    } catch (error) {
      log.warn("Failed to decrypt document file name during search", error)
      return null
    }
  }

  return null
}

function getSearchText(row: SearchRow): string | null {
  const text = getMessageText(row)
  const fileName = getDocumentFileName(row)

  if (!text && !fileName) {
    return null
  }

  if (text && fileName) {
    return `${text} ${fileName}`
  }

  return text ?? fileName
}

function matchesQueryGroups(text: string, keywordGroups: string[][]): boolean {
  const haystack = text.toLowerCase()
  return keywordGroups.some((keywords) => keywords.every((keyword) => haystack.includes(keyword)))
}
