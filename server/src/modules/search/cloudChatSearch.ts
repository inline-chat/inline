import { and, desc, eq, gt, lt, or, sql, type SQL } from "drizzle-orm"
import { db } from "@in/server/db"
import { buildMediaFilterClause, type MessageMediaFilter } from "@in/server/db/models/messages"
import { chatSearchKeys, messageSearchDocuments, messages } from "@in/server/db/schema"
import { documents } from "@in/server/db/schema/media"
import type { Transaction } from "@in/server/db/types"
import { readSearchFileName, readSearchMessageText } from "./cloudIndex"
import { openChatSearchKey } from "./cloudCrypto"
import { CLOUD_TOKENIZER_VERSION, cloudQueryTags, matchExcerpts, parseCloudQuery, type ParsedCloudQuery } from "./cloudTokens"

type ChatIndexInput = {
  chatId: number
  /** In-chat search groups: any group matches when all its words do. */
  keywordGroups: string[][]
  maxResults: number
  beforeMessageId?: number
  /** Only messages with a larger ID: the viewer's cleared history ends at this ID. */
  afterMessageId?: number
  mediaFilter?: MessageMediaFilter
  tx?: Transaction
}

type Plan = { groups: { query: ParsedCloudQuery; clause: SQL }[]; verify: boolean }

const VERIFY_BATCH = 200

/**
 * In-chat text search from the encrypted word index, newest first. It matches
 * whole words and phrases, like global search. Returns null when the index
 * can't answer for this chat, so the caller scans instead: capture is off,
 * some history isn't indexed, the links filter, or a query the tokenizer
 * rejects.
 */
async function searchMessages(input: ChatIndexInput): Promise<bigint[] | null> {
  const tx = input.tx ?? db
  const plan = await prepare(tx, input)
  if (!plan) return null
  if (!plan.groups.length || input.maxResults <= 0) return []

  const found: bigint[] = []
  let before = input.beforeMessageId
  const batch = plan.verify ? VERIFY_BATCH : input.maxResults
  while (found.length < input.maxResults) {
    const rows = await candidates(tx, input, plan, before, batch)
    for (const row of rows) {
      if (found.length >= input.maxResults) break
      if (!plan.verify || verified(plan, row)) found.push(BigInt(row.messageId))
    }
    if (rows.length < batch) break
    before = rows.at(-1)!.messageId
  }
  return found
}

/** Every match in the chat, from the index. Null when the caller should scan. */
async function countMessages(input: Omit<ChatIndexInput, "maxResults" | "beforeMessageId">): Promise<number | null> {
  const tx = input.tx ?? db
  const plan = await prepare(tx, input)
  if (!plan) return null
  if (!plan.groups.length) return 0
  if (!plan.verify) {
    const [row] = await tx
      .select({ count: sql<number>`count(*)::int` })
      .from(messageSearchDocuments)
      .innerJoin(messages, eq(messages.globalId, messageSearchDocuments.messageGlobalId))
      .where(where(input, plan, undefined))
    return row?.count ?? 0
  }
  let count = 0
  let before: number | undefined
  for (;;) {
    const rows = await candidates(tx, input, plan, before, VERIFY_BATCH)
    for (const row of rows) if (verified(plan, row)) count++
    if (rows.length < VERIFY_BATCH) return count
    before = rows.at(-1)!.messageId
  }
}

export const CloudChatSearch = { searchMessages, countMessages }

async function prepare(
  tx: Transaction | typeof db,
  input: Pick<ChatIndexInput, "chatId" | "keywordGroups" | "mediaFilter">,
): Promise<Plan | null> {
  // Links need link detection over the whole history, which the index doesn't hold.
  if (input.mediaFilter === "links" || !input.keywordGroups.length) return null
  let queries: ParsedCloudQuery[]
  try {
    queries = input.keywordGroups.map((keywords) => parseCloudQuery(keywords.join(" ")))
  } catch {
    // Symbols only, more than eight words, an open quote or `*`: the scan still handles them.
    return null
  }
  if (!(await fullyIndexed(tx, input.chatId))) return null
  const [key] = await tx
    .select({ envelope: chatSearchKeys.keyEnvelope })
    .from(chatSearchKeys)
    .where(eq(chatSearchKeys.chatId, input.chatId))
    .limit(1)
  // Every message is indexed and none needed a key, so none has searchable text.
  if (!key) return { groups: [], verify: false }
  const secret = openChatSearchKey(input.chatId, key.envelope)
  try {
    return {
      groups: queries.map((query) => ({
        query,
        clause: and(
          ...cloudQueryTags(input.chatId, secret, query).map(
            (options) => sql`${messageSearchDocuments.tags} && ${"{" + options.join(",") + "}"}::uuid[]`,
          ),
        )!,
      })),
      // A word's tag is exact. A phrase also needs its words consecutive in one field.
      verify: queries.some((query) => query.some((term) => term.length > 1)),
    }
  } finally {
    secret.fill(0)
  }
}

/**
 * Capture is on, the history scan is complete, and every message in the chat
 * has a current document. Pending, failed and older- or newer-profile rows
 * mean the index can miss a match.
 */
async function fullyIndexed(tx: Transaction | typeof db, chatId: number): Promise<boolean> {
  const [row] = await tx.execute<{ covered: boolean }>(sql`
    select inline_search_capture_enabled()
      and coalesce((select complete from message_search_backfill where profile = ${CLOUD_TOKENIZER_VERSION}), false)
      and not exists(select 1 from message_search_documents where chat_id = ${chatId} and not ready)
      and not exists(select 1 from message_search_documents where ready and tokenizer_version < ${CLOUD_TOKENIZER_VERSION} and chat_id = ${chatId})
      and not exists(select 1 from message_search_documents where ready and tokenizer_version > ${CLOUD_TOKENIZER_VERSION} and chat_id = ${chatId})
      as covered`)
  return row?.covered === true
}

function where(
  input: Pick<ChatIndexInput, "chatId" | "afterMessageId" | "mediaFilter">,
  plan: Plan,
  before: number | undefined,
) {
  return and(
    eq(messageSearchDocuments.chatId, input.chatId),
    eq(messages.chatId, input.chatId),
    eq(messageSearchDocuments.ready, true),
    eq(messageSearchDocuments.tokenizerVersion, CLOUD_TOKENIZER_VERSION),
    sql`${messageSearchDocuments.messageRev} = ${messages.rev}`,
    before ? lt(messages.messageId, before) : undefined,
    input.afterMessageId ? gt(messages.messageId, input.afterMessageId) : undefined,
    buildMediaFilterClause(input.mediaFilter),
    or(...plan.groups.map((group) => group.clause)),
  )
}

async function candidates(
  tx: Transaction | typeof db,
  input: ChatIndexInput | Omit<ChatIndexInput, "maxResults" | "beforeMessageId">,
  plan: Plan,
  before: number | undefined,
  limit: number,
) {
  return tx
    .select({
      messageId: messages.messageId,
      text: plan.verify ? messages.text : sql<string | null>`NULL`,
      textEncrypted: plan.verify ? messages.textEncrypted : sql<Buffer | null>`NULL`,
      textIv: plan.verify ? messages.textIv : sql<Buffer | null>`NULL`,
      textTag: plan.verify ? messages.textTag : sql<Buffer | null>`NULL`,
      fileName: plan.verify ? documents.fileName : sql<Buffer | null>`NULL`,
      fileNameIv: plan.verify ? documents.fileNameIv : sql<Buffer | null>`NULL`,
      fileNameTag: plan.verify ? documents.fileNameTag : sql<Buffer | null>`NULL`,
    })
    .from(messageSearchDocuments)
    .innerJoin(messages, eq(messages.globalId, messageSearchDocuments.messageGlobalId))
    .leftJoin(documents, eq(documents.id, messages.documentId))
    .where(where(input, plan, before))
    .orderBy(desc(messages.messageId))
    .limit(limit)
}

function verified(plan: Plan, row: Awaited<ReturnType<typeof candidates>>[number]): boolean {
  const fields = { text: readSearchMessageText(row), fileName: readSearchFileName(row) }
  return plan.groups.some((group) => matchExcerpts(group.query, fields) !== undefined)
}
