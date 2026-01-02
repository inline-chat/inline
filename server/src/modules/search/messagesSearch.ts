import { db } from "@in/server/db"
import { messages } from "@in/server/db/schema"
import { documents } from "@in/server/db/schema/media"
import { decryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { Log } from "@in/server/utils/log"
import { and, desc, eq, lt } from "drizzle-orm"

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
  keywords: string[]
  maxResults: number
  batchSize?: number
}

export const MessageSearchModule = {
  searchMessagesInChat,
}

async function searchMessagesInChat(input: SearchMessagesInput): Promise<bigint[]> {
  if (input.maxResults <= 0 || input.keywords.length === 0) {
    return []
  }

  const batchSize = input.batchSize && input.batchSize > 0 ? input.batchSize : DEFAULT_BATCH_SIZE
  const matchedMessageIds: bigint[] = []
  let cursor: number | undefined = undefined

  while (matchedMessageIds.length < input.maxResults) {
    let batch = await fetchSearchBatch(input.chatId, cursor, batchSize)

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

      if (matchesKeywords(searchText, input.keywords)) {
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
): Promise<SearchRow[]> {
  const whereClause = beforeMessageId
    ? and(eq(messages.chatId, chatId), lt(messages.messageId, beforeMessageId))
    : eq(messages.chatId, chatId)

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

function matchesKeywords(text: string, keywords: string[]): boolean {
  const haystack = text.toLowerCase()
  return keywords.every((keyword) => haystack.includes(keyword))
}
