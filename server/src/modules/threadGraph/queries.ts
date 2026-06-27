import { db } from "@in/server/db"
import { chats, threadGraphLinks, type DbChat, type DbThreadGraphLink } from "@in/server/db/schema"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { and, desc, eq, inArray, isNull, lt } from "drizzle-orm"

const DEFAULT_LIMIT = 50
const MAX_LIMIT = 100
const MIN_BATCH_SIZE = 20
const FETCH_MULTIPLIER = 3
const MAX_SCAN = 500

type GraphDirection = "backlinks" | "outlinks"

export type ThreadGraphLinkListInput = {
  chatId: number
  currentUserId: number
  limit?: number
  beforeId?: bigint
}

export type ThreadGraphLinkListResult = {
  links: DbThreadGraphLink[]
  relatedChats: DbChat[]
  nextBeforeId: bigint | null
}

export async function getBacklinks(input: ThreadGraphLinkListInput): Promise<ThreadGraphLinkListResult> {
  return listThreadGraphLinks(input, "backlinks")
}

export async function getOutlinks(input: ThreadGraphLinkListInput): Promise<ThreadGraphLinkListResult> {
  return listThreadGraphLinks(input, "outlinks")
}

async function listThreadGraphLinks(
  input: ThreadGraphLinkListInput,
  direction: GraphDirection,
): Promise<ThreadGraphLinkListResult> {
  const limit = normalizeLimit(input.limit)
  const rootChat = await getChat(input.chatId)
  if (!rootChat) {
    throw RealtimeRpcError.ChatIdInvalid()
  }

  await AccessGuards.ensureChatAccess(rootChat, input.currentUserId)

  const links: DbThreadGraphLink[] = []
  const relatedChats = new Map<number, DbChat>()
  const access = new Map<number, boolean>()
  let beforeId = input.beforeId
  let scanned = 0
  let lastScannedId: bigint | null = null
  let exhausted = false

  while (links.length < limit && scanned < MAX_SCAN) {
    const batch = await fetchLinkBatch({
      chatId: input.chatId,
      direction,
      beforeId,
      limit: nextBatchLimit(limit, scanned),
    })

    if (batch.length === 0) {
      exhausted = true
      break
    }

    scanned += batch.length
    lastScannedId = batch[batch.length - 1]?.id ?? lastScannedId
    beforeId = lastScannedId ?? beforeId

    const chats = await getChats(endpointChatIds(batch, direction))
    for (const row of batch) {
      const otherChatId = endpointChatId(row, direction)
      const endpointChat = otherChatId === rootChat.id ? rootChat : chats.get(otherChatId)
      if (!endpointChat) {
        continue
      }

      if (!(await canAccessChat(endpointChat, input.currentUserId, access))) {
        continue
      }

      links.push(row)
      relatedChats.set(endpointChat.id, endpointChat)

      if (links.length >= limit) {
        return {
          links,
          relatedChats: Array.from(relatedChats.values()),
          nextBeforeId: row.id,
        }
      }
    }

    if (batch.length < nextBatchLimit(limit, scanned - batch.length)) {
      exhausted = true
      break
    }
  }

  return {
    links,
    relatedChats: Array.from(relatedChats.values()),
    nextBeforeId: exhausted ? null : lastScannedId,
  }
}

async function fetchLinkBatch(input: {
  chatId: number
  direction: GraphDirection
  beforeId?: bigint
  limit: number
}): Promise<DbThreadGraphLink[]> {
  const endpointColumn = input.direction === "backlinks" ? threadGraphLinks.toChatId : threadGraphLinks.fromChatId
  const filters = [eq(endpointColumn, input.chatId), isNull(threadGraphLinks.deletedAt)]

  if (input.beforeId !== undefined) {
    filters.push(lt(threadGraphLinks.id, input.beforeId))
  }

  return db
    .select()
    .from(threadGraphLinks)
    .where(and(...filters))
    .orderBy(desc(threadGraphLinks.id))
    .limit(input.limit)
}

async function getChat(chatId: number): Promise<DbChat | null> {
  const [chat] = await db.select().from(chats).where(eq(chats.id, chatId)).limit(1)
  return chat ?? null
}

async function getChats(chatIds: number[]): Promise<Map<number, DbChat>> {
  const uniqueIds = Array.from(new Set(chatIds))
  if (uniqueIds.length === 0) {
    return new Map()
  }

  const rows = await db.select().from(chats).where(inArray(chats.id, uniqueIds))
  return new Map(rows.map((chat) => [chat.id, chat]))
}

async function canAccessChat(chat: DbChat, userId: number, cache: Map<number, boolean>): Promise<boolean> {
  const cached = cache.get(chat.id)
  if (cached !== undefined) {
    return cached
  }

  try {
    await AccessGuards.ensureChatAccess(chat, userId)
    cache.set(chat.id, true)
    return true
  } catch (error) {
    if (!RealtimeRpcError.is(error)) {
      throw error
    }

    cache.set(chat.id, false)
    return false
  }
}

function endpointChatIds(rows: DbThreadGraphLink[], direction: GraphDirection): number[] {
  return rows.map((row) => endpointChatId(row, direction))
}

function endpointChatId(row: DbThreadGraphLink, direction: GraphDirection): number {
  return direction === "backlinks" ? row.fromChatId : row.toChatId
}

function normalizeLimit(limit: number | undefined): number {
  if (limit === undefined) {
    return DEFAULT_LIMIT
  }

  if (!Number.isFinite(limit)) {
    return DEFAULT_LIMIT
  }

  return Math.max(1, Math.min(Math.trunc(limit), MAX_LIMIT))
}

function nextBatchLimit(limit: number, scanned: number): number {
  const desired = Math.max(MIN_BATCH_SIZE, limit * FETCH_MULTIPLIER)
  return Math.min(desired, MAX_SCAN - scanned)
}
