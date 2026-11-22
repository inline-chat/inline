import { db } from "@in/server/db"
import {
  chatSearchKeys,
  messageSearchBackfill,
  documents,
  messages,
  messageSearchDocuments,
} from "@in/server/db/schema"
import { and, asc, eq, gt, sql } from "drizzle-orm"
import { decryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { GridTranscriptMessageKind } from "@inline-chat/protocol/core"
import { decryptSystemMessagePayload, type SystemMessage } from "@in/server/modules/systemMessages/payload"
import { Log } from "@in/server/utils/log"
import { searchFailureClass } from "./cloudFailure"
import { ensureChatSearchKey, openChatSearchKey } from "./cloudCrypto"
import { CLOUD_TOKENIZER_VERSION, cloudDocumentTags } from "./cloudTokens"

const log = new Log("cloudSearch.index")
export const CLOUD_INDEX_TAG_LIMIT = 4096
// Current message writes are limited to 400 kB. Give historical rows a separate bounded path.
export const MAX_SEARCH_SOURCE_BYTES = 8 * 1024 * 1024
export const searchSourceBytes = sql`(coalesce(octet_length(m.text_encrypted), octet_length(m.text), 0)::bigint
  + coalesce(octet_length(doc.file_name), 0) + coalesce(octet_length(m.system_message_encrypted), 0))`

export function cloudSearchEnabled(): boolean {
  const value = process.env["CLOUD_MESSAGE_SEARCH_ENABLED"] ?? "true"
  if (value !== "true" && value !== "false") throw new Error("Invalid cloud search configuration")
  return value === "true"
}

// Serialize the historical cursor across workers. The insert and checkpoint commit together.
export async function bootstrapSearchDocuments(limit = 500): Promise<boolean> {
  return db.transaction(async (tx) => {
    // Serialize capture transitions with this checkpoint, including the empty-history case.
    await tx.execute(sql`lock table messages in access share mode`)
    const [capture] = await tx.execute<{ enabled: boolean }>(sql`select inline_search_capture_enabled() as enabled`)
    if (!capture?.enabled) return false
    await tx.insert(messageSearchBackfill).values({ profile: CLOUD_TOKENIZER_VERSION }).onConflictDoNothing()
    const [state] = await tx
      .select()
      .from(messageSearchBackfill)
      .where(eq(messageSearchBackfill.profile, CLOUD_TOKENIZER_VERSION))
      .for("update")
    if (state!.complete) return true
    const rows = await tx
      .select({ id: messages.globalId, chatId: messages.chatId, rev: messages.rev })
      .from(messages)
      .where(gt(messages.globalId, state!.afterGlobalId))
      .orderBy(asc(messages.globalId))
      .limit(limit)
      .for("key share")
    if (rows.length) {
      await tx
        .insert(messageSearchDocuments)
        .values(
          rows.map((row) => ({
            messageGlobalId: row.id,
            chatId: row.chatId,
            messageRev: row.rev,
            historical: true,
          })),
        )
        .onConflictDoUpdate({
          target: messageSearchDocuments.messageGlobalId,
          set: {
            ready: false,
            claimUntil: null,
            overflow: false,
            tags: [],
            tokenizerVersion: null,
            historical: true,
            failedAttempts: 0,
            workVersion: sql`nextval('message_search_work_version')`,
          },
          where: and(
            eq(messageSearchDocuments.ready, true),
            sql`${messageSearchDocuments.tokenizerVersion} is distinct from ${CLOUD_TOKENIZER_VERSION}`,
          ),
        })
    }
    const complete = rows.length < limit
    await tx
      .update(messageSearchBackfill)
      .set({ complete, afterGlobalId: rows.at(-1)?.id ?? state!.afterGlobalId })
      .where(eq(messageSearchBackfill.profile, CLOUD_TOKENIZER_VERSION))
    return complete
  })
}

// An earlier worker can publish its profile after the historical scan passes a row.
export async function requeueObsoleteSearchDocuments(limit = 100): Promise<number> {
  const older = sql`tokenizer_version < ${CLOUD_TOKENIZER_VERSION}`
  const newer = sql`tokenizer_version > ${CLOUD_TOKENIZER_VERSION}`
  let total = 0
  for (const condition of [older, newer]) {
    const changed = await db.execute(sql`with obsolete as (
      select message_global_id from message_search_documents where ready and ${condition}
      order by tokenizer_version, chat_id limit ${limit} for update skip locked
    ) update message_search_documents sd set ready = false, overflow = false, tags = '{}',
      claim_until = null, historical = true, failed_attempts = 0, tokenizer_version = null, work_version = nextval('message_search_work_version')
    from obsolete where sd.message_global_id = obsolete.message_global_id returning sd.message_global_id`)
    total += changed.length
  }
  return total
}

/** Public for deterministic race tests; the hook never participates in production. */
export async function runCloudSearchIndexBatch(
  input: {
    limit?: number
    historicalOnly?: boolean
    /** Leave historical rows to the paced history batch. */
    liveOnly?: boolean
    beforePublish?: (messageGlobalId: bigint) => Promise<void>
  } = {},
) {
  const claimed = await db.execute<{ id: string; chatId: number; work: string; oversized: boolean }>(sql`
    with picked as (
      select message_global_id from message_search_documents where not ready
        and (claim_until is null or claim_until <= now())
        and failed_attempts < 5
        ${input.historicalOnly ? sql`and historical` : input.liveOnly ? sql`and not historical` : sql``}
      order by historical, message_global_id limit ${Math.max(1, Math.min(input.limit ?? 16, 100))} for update skip locked
    ), leased as (
    update message_search_documents sd set claim_until = now() + interval '1 minute', work_version = nextval('message_search_work_version')
    from picked where sd.message_global_id = picked.message_global_id
    returning sd.message_global_id, sd.chat_id, sd.work_version, sd.historical)
    select l.message_global_id::text as id, l.chat_id as "chatId", l.work_version::text as work,
      ${searchSourceBytes} > ${MAX_SEARCH_SOURCE_BYTES} as oversized from leased l
      join messages m on m.global_id=l.message_global_id left join documents doc on doc.id=m.document_id
    order by l.historical, l.message_global_id`)
  const pending = claimed.map((row) => ({
    globalId: BigInt(row.id),
    chatId: row.chatId,
    work: BigInt(row.work),
    oversized: row.oversized,
  }))

  let indexed = 0,
    failed = 0,
    superseded = 0
  for (const pendingRow of pending) {
    let stage: "source-size" | "key" | "read" | "tokenize" | "publish" = "source-size"
    try {
      if (pendingRow.oversized) {
        throw new Error("Search source too large")
      }
      stage = "key"
      await ensureChatSearchKey(pendingRow.chatId)
      stage = "read"
      // All source fields and the work fence come from this single statement snapshot.
      const [row] = await db
        .select({
          message: {
            chatId: messages.chatId,
            rev: messages.rev,
            text: messages.text,
            textEncrypted: messages.textEncrypted,
            textIv: messages.textIv,
            textTag: messages.textTag,
            systemMessageEncrypted: messages.systemMessageEncrypted,
            systemMessageIv: messages.systemMessageIv,
            systemMessageTag: messages.systemMessageTag,
          },

          workVersion: messageSearchDocuments.workVersion,
          keyEnvelope: chatSearchKeys.keyEnvelope,
          fileName: documents.fileName,
          fileNameIv: documents.fileNameIv,
          fileNameTag: documents.fileNameTag,
        })
        .from(messageSearchDocuments)
        .innerJoin(messages, eq(messages.globalId, messageSearchDocuments.messageGlobalId))
        .innerJoin(chatSearchKeys, eq(chatSearchKeys.chatId, messages.chatId))
        .leftJoin(documents, eq(documents.id, messages.documentId))
        .where(
          and(
            eq(messageSearchDocuments.messageGlobalId, pendingRow.globalId),
            eq(messageSearchDocuments.workVersion, pendingRow.work),
            eq(messageSearchDocuments.ready, false),
          ),
        )
        .limit(1)
      if (!row) {
        superseded++
        continue
      }
      stage = "key"
      const key = openChatSearchKey(row.message.chatId, row.keyEnvelope)
      let tags: string[]
      let overflow = false
      try {
        stage = "tokenize"
        const fields = cloudSearchMessageHasText(row.message)
          ? {
              text: readSearchMessageText(row.message),
              fileName: readSearchFileName(row),
            }
          : { text: null, fileName: null }
        const bounded = cloudDocumentTags(row.message.chatId, key, fields, CLOUD_INDEX_TAG_LIMIT)
        overflow = bounded === null
        tags = bounded ?? []
      } finally {
        key.fill(0)
      }
      stage = "publish"
      await input.beforePublish?.(pendingRow.globalId)
      // Message/filename changes advance this version in their own transaction.
      // Never replace pending work or resurrect a deleted document after stale computation.
      const published = await db
        .update(messageSearchDocuments)
        .set({
          messageRev: row.message.rev,
          tokenizerVersion: CLOUD_TOKENIZER_VERSION,
          failedAttempts: 0,
          ready: true,
          claimUntil: null,
          overflow,
          tags,
        })
        .where(
          and(
            eq(messageSearchDocuments.messageGlobalId, pendingRow.globalId),
            eq(messageSearchDocuments.workVersion, row.workVersion),
            eq(messageSearchDocuments.ready, false),
          ),
        )
        .returning({ id: messageSearchDocuments.messageGlobalId })
      if (published.length > 0) indexed++
      else superseded++
    } catch (error) {
      // An edit resets this counter, releases the lease and gives the row a new fence.
      const failure = searchFailureClass(error)
      const [recorded] = await db.execute<{ attempts: number }>(sql`
        update message_search_documents set
          failed_attempts = ${pendingRow.oversized ? sql`5` : sql`failed_attempts + 1`},
          claim_until = case when failed_attempts >= 4 or ${pendingRow.oversized} then null
            else now() + interval '30 seconds' * power(2, failed_attempts) end
        where message_global_id = ${pendingRow.globalId} and work_version = ${pendingRow.work}
        returning failed_attempts as attempts`)
      if (recorded) {
        log.warn("Search indexing failed", { stage, failure, attempts: recorded.attempts })
        failed++
      } else superseded++
    }
  }
  return {
    examined: pending.length,
    indexed,
    failed,
    superseded,
  }
}

/** Structural events have no lexical content; admitted transcript turns are ordinary searchable speech. */
export function cloudSearchableSystemMessage(payload: SystemMessage | null | undefined): boolean {
  return (
    !payload ||
    (payload.event.oneofKind === "gridTranscript" &&
      payload.event.gridTranscript.kind === GridTranscriptMessageKind.GRID_TRANSCRIPT_TURN)
  )
}

export function cloudSearchMessageHasText(row: {
  systemMessageEncrypted: Buffer | null
  systemMessageIv: Buffer | null
  systemMessageTag: Buffer | null
}): boolean {
  if (!row.systemMessageEncrypted && !row.systemMessageIv && !row.systemMessageTag) return true
  if (!row.systemMessageEncrypted || !row.systemMessageIv || !row.systemMessageTag) {
    throw new Error("Invalid encrypted search event")
  }
  return cloudSearchableSystemMessage(
    decryptSystemMessagePayload({
      encrypted: row.systemMessageEncrypted,
      iv: row.systemMessageIv,
      authTag: row.systemMessageTag,
    }),
  )
}

export function readSearchMessageText(row: {
  text: string | null
  textEncrypted: Buffer | null
  textIv: Buffer | null
  textTag: Buffer | null
}): string | null {
  if (row.textEncrypted || row.textIv || row.textTag) {
    if (!row.textEncrypted || !row.textIv || !row.textTag) throw new Error("Invalid encrypted search document")
    return decryptMessage({ encrypted: row.textEncrypted, iv: row.textIv, authTag: row.textTag })
  }
  return row.text
}

export function readSearchFileName(row: {
  fileName: Buffer | null
  fileNameIv: Buffer | null
  fileNameTag: Buffer | null
}): string | null {
  if (!row.fileName && !row.fileNameIv && !row.fileNameTag) return null
  if (!row.fileName || !row.fileNameIv || !row.fileNameTag) throw new Error("Invalid encrypted search filename")
  return decrypt({ encrypted: row.fileName, iv: row.fileNameIv, authTag: row.fileNameTag })
}
