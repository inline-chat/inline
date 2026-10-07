import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { buildMediaFilterClause } from "@in/server/db/models/messages"
import { messages } from "@in/server/db/schema"
import { MessageEntities } from "@inline-chat/protocol/core"
import { detectHasLink } from "@in/server/modules/message/linkDetection"
import { decryptBinary } from "@in/server/modules/encryption/encryption"
import { documents } from "@in/server/db/schema/media"
import { decryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { and, desc, eq, lt, sql } from "drizzle-orm"

const DEFAULT_BATCH_SIZE = 1000

type SearchRow = {
  messageId: number
  hasLink: boolean | null
  hasPreview: boolean
  entitiesEncrypted: Buffer | null
  entitiesIv: Buffer | null
  entitiesTag: Buffer | null
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
  tx?: Transaction
}

export const MessageSearchModule = {
  searchMessagesInChat,
}

export type MessageMediaFilter = "photos" | "videos" | "photo_video" | "documents" | "links" | "voice_memos"

async function searchMessagesInChat(input: SearchMessagesInput): Promise<bigint[]> {
  if (input.maxResults <= 0 || (input.keywordGroups.length === 0 && input.mediaFilter !== "links")) {
    return []
  }

  const batchSize = input.batchSize && input.batchSize > 0 ? input.batchSize : DEFAULT_BATCH_SIZE
  const matchedMessageIds: bigint[] = []
  let cursor: number | undefined = input.beforeMessageId

  while (matchedMessageIds.length < input.maxResults) {
    let batch = await fetchSearchBatch(
      input.chatId,
      cursor,
      batchSize,
      input.mediaFilter,
      input.tx,
      input.keywordGroups.length > 0,
    )

    if (batch.length === 0) {
      break
    }

    for (const row of batch) {
      if (matchedMessageIds.length >= input.maxResults) {
        break
      }

      if (
        input.mediaFilter === "links" &&
        !row.hasPreview &&
        !(
          row.hasLink ??
          detectHasLink({
            entities:
              row.entitiesEncrypted && row.entitiesIv && row.entitiesTag
                ? MessageEntities.fromBinary(
                    decryptBinary({
                      encrypted: row.entitiesEncrypted,
                      iv: row.entitiesIv,
                      authTag: row.entitiesTag,
                    }),
                  )
                : undefined,
          })
        )
      )
        continue
      if (input.keywordGroups.length === 0) {
        matchedMessageIds.push(BigInt(row.messageId))
        continue
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
  tx?: Transaction,
  needsText = true,
): Promise<SearchRow[]> {
  const baseWhereClause = beforeMessageId
    ? and(eq(messages.chatId, chatId), lt(messages.messageId, beforeMessageId))
    : eq(messages.chatId, chatId)
  const mediaClause = buildMediaFilterClause(mediaFilter)
  const whereClause = mediaClause ? and(baseWhereClause, mediaClause) : baseWhereClause

  return (tx ?? db)
    .select({
      messageId: messages.messageId,
      hasLink: messages.hasLink,
      hasPreview: sql<boolean>`EXISTS (SELECT 1 FROM message_attachments AS preview_attachment WHERE preview_attachment.message_id = ${messages.globalId} AND preview_attachment.url_preview_id IS NOT NULL)`,
      entitiesEncrypted: messages.entitiesEncrypted,
      entitiesIv: messages.entitiesIv,
      entitiesTag: messages.entitiesTag,
      text: needsText ? messages.text : sql<string | null>`NULL`,
      textEncrypted: needsText ? messages.textEncrypted : sql<Buffer | null>`NULL`,
      textIv: needsText ? messages.textIv : sql<Buffer | null>`NULL`,
      textTag: needsText ? messages.textTag : sql<Buffer | null>`NULL`,
      documentFileName: needsText ? documents.fileName : sql<Buffer | null>`NULL`,
      documentFileNameIv: needsText ? documents.fileNameIv : sql<Buffer | null>`NULL`,
      documentFileNameTag: needsText ? documents.fileNameTag : sql<Buffer | null>`NULL`,
    })
    .from(messages)
    .leftJoin(documents, eq(messages.documentId, documents.id))
    .where(whereClause)
    .orderBy(desc(messages.messageId))
    .limit(limit)
}

function getMessageText(row: SearchRow): string | null {
  if (row.textEncrypted && row.textIv && row.textTag) {
    return decryptMessage({ encrypted: row.textEncrypted, iv: row.textIv, authTag: row.textTag })
  }
  return row.text ?? null
}

function getDocumentFileName(row: SearchRow): string | null {
  if (row.documentFileName && row.documentFileNameIv && row.documentFileNameTag) {
    return decrypt({
      encrypted: row.documentFileName,
      iv: row.documentFileNameIv,
      authTag: row.documentFileNameTag,
    })
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
