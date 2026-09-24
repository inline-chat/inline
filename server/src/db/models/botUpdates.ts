import type {
  BotMessageTrigger,
  BotUpdate,
  BotUpdateKey,
  DeleteWebhookParams,
  GetUpdatesParams,
  SetWebhookParams,
  WebhookInfo,
} from "@inline-chat/bot-api-types"
import { randomInt, randomUUID } from "crypto"
import { and, asc, desc, eq, gt, inArray, isNotNull, isNull, lte, or, sql } from "drizzle-orm"
import { db } from "@in/server/db"
import {
  botMessageRoutes,
  botUpdates,
  botUpdateStreams,
  chats,
  type DbBotUpdate,
  type DbBotUpdateStream,
} from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { isServerShuttingDown } from "@in/server/lifecycle/shutdownState"
import { botUpdateWaiters } from "./botUpdateWaiters"

export const BOT_UPDATE_QUEUE_LIMITS = {
  ttlMs: 24 * 60 * 60 * 1_000,
  maxPendingUpdates: 100_000,
  maxPendingPayloadBytes: 1 << 27,
  maxUpdatePayloadBytes: 65_536 * 8,
  maxPollResponseBytes: 1 << 22,
} as const

const pollLeaseMs = 55_000
// Recheck the durable queue when another Machine writes or a local wake is missed.
const pollFallbackMs = 2_000
const deliveryLeaseMs = 30_000
const cleanupBatchSize = 1_000
const log = new Log("db.models.botUpdates")
const defaultUpdates: BotUpdateKey[] = [
  "message",
  "edited_message",
  "message_action",
  "bot_participation",
]
const allUpdates: BotUpdateKey[] = [...defaultUpdates, "message_reaction"]

const uniqueUpdates = (value: BotUpdateKey[] | undefined, previous?: string[]): BotUpdateKey[] => {
  const source = value === undefined ? previous ?? defaultUpdates : value.length === 0 ? defaultUpdates : value
  return Array.from(new Set(source.filter((key): key is BotUpdateKey => allUpdates.includes(key as BotUpdateKey))))
}

const initialUpdateId = () => randomInt(1_000_000, 1_000_000_000)
const encryptJson = (value: string) => Encryption2.encrypt(Buffer.from(value, "utf8"))
const decryptUpdate = (value: Buffer): BotUpdate =>
  JSON.parse(Encryption2.decryptToString(value)) as BotUpdate

type PollClaim = {
  token: string
  generation: number
}

export type WebhookDeliveryClaim = {
  stream: DbBotUpdateStream
  updateRowId: number
  update: BotUpdate
  claimToken: string
  claimGeneration: number
  attemptCount: number
}

type BotUpdatePayload = BotUpdate extends infer Update
  ? Update extends { update_id: number }
    ? Omit<Update, "update_id">
    : never
  : never

async function ensureStream(botUserId: number): Promise<DbBotUpdateStream> {
  const [stream] = await db
    .insert(botUpdateStreams)
    .values({ botUserId, nextUpdateId: initialUpdateId(), allowedUpdates: defaultUpdates })
    .onConflictDoNothing()
    .returning()
  if (stream) return stream
  const [existing] = await db.select().from(botUpdateStreams).where(eq(botUpdateStreams.botUserId, botUserId)).limit(1)
  if (!existing) throw new Error("Failed to initialize bot update stream")
  return existing
}

async function queue(input: {
  botUserId: number
  updateType: BotUpdateKey
  payload: BotUpdatePayload
  sourceEventId?: string
}): Promise<BotUpdate | undefined> {
  const outcome = await db.transaction(async (tx) => {
    const [stream] = await tx
      .select()
      .from(botUpdateStreams)
      .where(eq(botUpdateStreams.botUserId, input.botUserId))
      .for("update")
      .limit(1)
    if (!stream || !uniqueUpdates(undefined, stream.allowedUpdates).includes(input.updateType)) return undefined

    if (input.sourceEventId) {
      const [existing] = await tx
        .select({ id: botUpdates.id })
        .from(botUpdates)
        .where(and(eq(botUpdates.botUserId, input.botUserId), eq(botUpdates.sourceEventId, input.sourceEventId)))
        .limit(1)
      if (existing) return undefined
    }

    const update = { update_id: stream.nextUpdateId, ...input.payload } as BotUpdate
    const serialized = JSON.stringify(update)
    const payloadByteCount = Buffer.byteLength(serialized)
    let pendingUpdateCount = stream.pendingUpdateCount
    let pendingPayloadBytes = stream.pendingPayloadBytes
    let queueFull =
      pendingUpdateCount >= BOT_UPDATE_QUEUE_LIMITS.maxPendingUpdates ||
      pendingPayloadBytes > BOT_UPDATE_QUEUE_LIMITS.maxPendingPayloadBytes - payloadByteCount
    if (payloadByteCount <= BOT_UPDATE_QUEUE_LIMITS.maxUpdatePayloadBytes && queueFull) {
      const now = new Date()
      const expired = await tx
        .select({ id: botUpdates.id, payloadByteCount: botUpdates.payloadByteCount })
        .from(botUpdates)
        .where(and(
          eq(botUpdates.botUserId, input.botUserId),
          gt(botUpdates.updateId, stream.acknowledgedUpdateId),
          lte(botUpdates.expiresAt, now),
        ))
        .orderBy(asc(botUpdates.expiresAt))
        .limit(cleanupBatchSize)
      if (expired.length > 0) {
        await tx.delete(botUpdates).where(inArray(botUpdates.id, expired.map((row) => row.id)))
        const expiredPayloadBytes = expired.reduce((total, row) => total + row.payloadByteCount, 0)
        pendingUpdateCount = Math.max(0, pendingUpdateCount - expired.length)
        pendingPayloadBytes = Math.max(0, pendingPayloadBytes - expiredPayloadBytes)
        await tx
          .update(botUpdateStreams)
          .set({
            pendingUpdateCount,
            pendingPayloadBytes,
            droppedUpdateCount: sql`${botUpdateStreams.droppedUpdateCount} + ${expired.length}`,
            updatedAt: now,
          })
          .where(eq(botUpdateStreams.botUserId, input.botUserId))
        queueFull =
          pendingUpdateCount >= BOT_UPDATE_QUEUE_LIMITS.maxPendingUpdates ||
          pendingPayloadBytes > BOT_UPDATE_QUEUE_LIMITS.maxPendingPayloadBytes - payloadByteCount
      }
    }
    if (payloadByteCount > BOT_UPDATE_QUEUE_LIMITS.maxUpdatePayloadBytes || queueFull) {
      await tx
        .update(botUpdateStreams)
        .set({
          droppedUpdateCount: sql`${botUpdateStreams.droppedUpdateCount} + 1`,
          updatedAt: new Date(),
        })
        .where(eq(botUpdateStreams.botUserId, input.botUserId))
      return {
        dropped: true as const,
        reason: payloadByteCount > BOT_UPDATE_QUEUE_LIMITS.maxUpdatePayloadBytes ? "payload_too_large" : "queue_full",
        payloadByteCount,
        pendingUpdateCount,
        pendingPayloadBytes,
      }
    }

    const inserted = await tx
      .insert(botUpdates)
      .values({
        botUserId: input.botUserId,
        updateId: stream.nextUpdateId,
        updateType: input.updateType,
        payloadEncrypted: encryptJson(serialized),
        payloadByteCount,
        sourceEventId: input.sourceEventId,
        nextAttemptAt: new Date(),
        expiresAt: new Date(Date.now() + BOT_UPDATE_QUEUE_LIMITS.ttlMs),
      })
      .onConflictDoNothing()
      .returning({ id: botUpdates.id })
    if (inserted.length === 0) return undefined
    await tx
      .update(botUpdateStreams)
      .set({
        nextUpdateId: stream.nextUpdateId + 1,
        pendingUpdateCount: pendingUpdateCount + 1,
        pendingPayloadBytes: pendingPayloadBytes + payloadByteCount,
        updatedAt: new Date(),
      })
      .where(eq(botUpdateStreams.botUserId, input.botUserId))
    return update
  })

  if (outcome && "dropped" in outcome) {
    log.warn("Dropped Bot update at queue safety boundary", {
      botUserId: input.botUserId,
      updateType: input.updateType,
      reason: outcome.reason,
      payloadByteCount: outcome.payloadByteCount,
      pendingUpdateCount: outcome.pendingUpdateCount,
      pendingPayloadBytes: outcome.pendingPayloadBytes,
    })
    return undefined
  }
  if (outcome) botUpdateWaiters.wake(input.botUserId)
  return outcome
}

async function configurePoll(
  botUserId: number,
  claim: PollClaim,
  input: Pick<GetUpdatesParams, "allowed_updates" | "message_trigger">,
): Promise<DbBotUpdateStream> {
  if (input.allowed_updates === undefined && input.message_trigger === undefined) {
    return requireCurrentPoll(db, botUserId, claim)
  }
  const [updated] = await db
    .update(botUpdateStreams)
    .set({
      ...(input.allowed_updates === undefined ? {} : { allowedUpdates: uniqueUpdates(input.allowed_updates) }),
      ...(input.message_trigger === undefined ? {} : { messageTrigger: input.message_trigger }),
      updatedAt: new Date(),
    })
    .where(and(
      eq(botUpdateStreams.botUserId, botUserId),
      eq(botUpdateStreams.pollLeaseToken, claim.token),
      eq(botUpdateStreams.configGeneration, claim.generation),
      isNull(botUpdateStreams.webhookUrl),
    ))
    .returning()
  if (!updated) throw new InlineError(InlineError.ApiError.POLL_CONFLICT)
  return updated
}

const subtractCounter = (column: typeof botUpdateStreams.pendingUpdateCount | typeof botUpdateStreams.pendingPayloadBytes, value: number) =>
  sql`greatest(0, ${column} - ${value})`

async function requireCurrentPoll(
  query: Pick<typeof db, "select"> | Pick<Transaction, "select">,
  botUserId: number,
  claim: PollClaim,
): Promise<DbBotUpdateStream> {
  const [stream] = await query
    .select()
    .from(botUpdateStreams)
    .where(and(
      eq(botUpdateStreams.botUserId, botUserId),
      eq(botUpdateStreams.pollLeaseToken, claim.token),
      eq(botUpdateStreams.configGeneration, claim.generation),
      isNull(botUpdateStreams.webhookUrl),
    ))
    .limit(1)
  if (!stream) throw new InlineError(InlineError.ApiError.POLL_CONFLICT)
  return stream
}

async function acknowledgeThrough(
  tx: Transaction,
  stream: DbBotUpdateStream,
  updateId: number,
): Promise<DbBotUpdateStream> {
  const acknowledged = Math.min(stream.nextUpdateId - 1, updateId)
  if (acknowledged <= stream.acknowledgedUpdateId) return stream
  const rows = await tx
    .select({ payloadByteCount: botUpdates.payloadByteCount })
    .from(botUpdates)
    .where(and(
      eq(botUpdates.botUserId, stream.botUserId),
      gt(botUpdates.updateId, stream.acknowledgedUpdateId),
      lte(botUpdates.updateId, acknowledged),
    ))
  const payloadBytes = rows.reduce((total, row) => total + row.payloadByteCount, 0)
  const [updated] = await tx
    .update(botUpdateStreams)
    .set({
      acknowledgedUpdateId: acknowledged,
      pendingUpdateCount: subtractCounter(botUpdateStreams.pendingUpdateCount, rows.length),
      pendingPayloadBytes: subtractCounter(botUpdateStreams.pendingPayloadBytes, payloadBytes),
      updatedAt: new Date(),
    })
    .where(eq(botUpdateStreams.botUserId, stream.botUserId))
    .returning()
  if (!updated) throw new Error("Failed to acknowledge Bot updates")
  return updated
}

async function acknowledge(botUserId: number, offset: number, claim: PollClaim): Promise<void> {
  await db.transaction(async (tx) => {
    const [current] = await tx
      .select()
      .from(botUpdateStreams)
      .where(and(
        eq(botUpdateStreams.botUserId, botUserId),
        eq(botUpdateStreams.pollLeaseToken, claim.token),
        eq(botUpdateStreams.configGeneration, claim.generation),
        isNull(botUpdateStreams.webhookUrl),
      ))
      .for("update")
      .limit(1)
    if (!current) throw new InlineError(InlineError.ApiError.POLL_CONFLICT)
    if (offset >= 0) {
      await acknowledgeThrough(tx, current, offset - 1)
      return
    }

    const keep = Math.min(BOT_UPDATE_QUEUE_LIMITS.maxPendingUpdates, Math.abs(offset))
    const newest = await tx
      .select({ updateId: botUpdates.updateId })
      .from(botUpdates)
      .where(and(
        eq(botUpdates.botUserId, botUserId),
        gt(botUpdates.updateId, current.acknowledgedUpdateId),
        gt(botUpdates.expiresAt, new Date()),
      ))
      .orderBy(desc(botUpdates.updateId))
      .limit(keep)
    const oldestKept = newest.at(-1)?.updateId
    await acknowledgeThrough(tx, current, oldestKept === undefined ? current.nextUpdateId - 1 : oldestKept - 1)
  })
}

export const botUpdateChatId = (update: BotUpdate): number | undefined => {
  if ("message" in update) return update.message.chat.chat_id
  if ("edited_message" in update) return update.edited_message.chat.chat_id
  if ("message_reaction" in update) return update.message_reaction.chat.chat_id
  if ("message_action" in update) return update.message_action.chat.chat_id
  if ("bot_participation" in update) return update.bot_participation.chat.chat_id
  return undefined
}

async function canBotAccessUpdate(botUserId: number, update: BotUpdate): Promise<boolean> {
  const chatId = botUpdateChatId(update)
  if (chatId === undefined) return false
  const [chat] = await db.select().from(chats).where(eq(chats.id, chatId)).limit(1)
  if (!chat) return false
  try {
    await AccessGuards.ensureChatAccess(chat, botUserId)
    return true
  } catch {
    return false
  }
}

async function accessibleUpdateRows(
  botUserId: number,
  rows: Array<{ row: DbBotUpdate; update: BotUpdate }>,
): Promise<{ accessible: Array<{ row: DbBotUpdate; update: BotUpdate }>; inaccessible: DbBotUpdate[] }> {
  const chatIds = Array.from(new Set(rows.flatMap(({ update }) => {
    const chatId = botUpdateChatId(update)
    return chatId === undefined ? [] : [chatId]
  })))
  const chatRows = chatIds.length === 0
    ? []
    : await db.select().from(chats).where(inArray(chats.id, chatIds))
  const accessibleChatIds = new Set<number>()
  await Promise.all(chatRows.map(async (chat) => {
    try {
      await AccessGuards.ensureChatAccess(chat, botUserId)
      accessibleChatIds.add(chat.id)
    } catch {
      // Queued payloads are discarded when access has been revoked.
    }
  }))
  const accessible: Array<{ row: DbBotUpdate; update: BotUpdate }> = []
  const inaccessible: DbBotUpdate[] = []
  for (const item of rows) {
    const chatId = botUpdateChatId(item.update)
    if (chatId !== undefined && accessibleChatIds.has(chatId)) accessible.push(item)
    else inaccessible.push(item.row)
  }
  return { accessible, inaccessible }
}

async function discardPendingRows(botUserId: number, rows: DbBotUpdate[]): Promise<number> {
  if (rows.length === 0) return 0
  return db.transaction(async (tx) => {
    const [stream] = await tx
      .select()
      .from(botUpdateStreams)
      .where(eq(botUpdateStreams.botUserId, botUserId))
      .for("update")
      .limit(1)
    if (!stream) return 0
    const deleted = await tx
      .delete(botUpdates)
      .where(and(
        eq(botUpdates.botUserId, botUserId),
        gt(botUpdates.updateId, stream.acknowledgedUpdateId),
        inArray(botUpdates.id, rows.map((row) => row.id)),
      ))
      .returning({ payloadByteCount: botUpdates.payloadByteCount })
    if (deleted.length === 0) return 0
    const payloadBytes = deleted.reduce((total, row) => total + row.payloadByteCount, 0)
    await tx
      .update(botUpdateStreams)
      .set({
        pendingUpdateCount: subtractCounter(botUpdateStreams.pendingUpdateCount, deleted.length),
        pendingPayloadBytes: subtractCounter(botUpdateStreams.pendingPayloadBytes, payloadBytes),
        droppedUpdateCount: sql`${botUpdateStreams.droppedUpdateCount} + ${deleted.length}`,
        updatedAt: new Date(),
      })
      .where(eq(botUpdateStreams.botUserId, botUserId))
    return deleted.length
  })
}

export const takeUpdatesWithinResponseLimit = (
  updates: BotUpdate[],
  limit = BOT_UPDATE_QUEUE_LIMITS.maxPollResponseBytes,
): BotUpdate[] => {
  const selected: BotUpdate[] = []
  let bytes = 2
  for (const update of updates) {
    const updateBytes = Buffer.byteLength(JSON.stringify(update)) + (selected.length === 0 ? 0 : 1)
    if (bytes + updateBytes > limit) break
    selected.push(update)
    bytes += updateBytes
  }
  return selected
}

async function readPending(botUserId: number, limit: number, claim: PollClaim): Promise<BotUpdate[]> {
  const stream = await requireCurrentPoll(db, botUserId, claim)
  const candidates: Array<{ row: DbBotUpdate; update: BotUpdate }> = []
  const corrupted: DbBotUpdate[] = []
  let cursor = stream.acknowledgedUpdateId
  let scanned = 0
  while (candidates.length < limit && scanned < cleanupBatchSize) {
    const batchLimit = Math.min(100, cleanupBatchSize - scanned)
    const rows = await db
      .select()
      .from(botUpdates)
      .where(and(
        eq(botUpdates.botUserId, botUserId),
        gt(botUpdates.updateId, cursor),
        gt(botUpdates.expiresAt, new Date()),
      ))
      .orderBy(asc(botUpdates.updateId))
      .limit(batchLimit)
    if (rows.length === 0) break
    scanned += rows.length
    cursor = rows[rows.length - 1]!.updateId
    for (const row of rows) {
      try {
        candidates.push({ row, update: decryptUpdate(row.payloadEncrypted) })
      } catch {
        corrupted.push(row)
      }
    }
    if (rows.length < batchLimit) break
  }

  const { accessible, inaccessible } = await accessibleUpdateRows(botUserId, candidates)
  const discarded = await discardPendingRows(botUserId, [...corrupted, ...inaccessible])
  if (discarded > 0) {
    log.warn("Discarded inaccessible or unreadable Bot updates", { botUserId, count: discarded })
  }
  await requireCurrentPoll(db, botUserId, claim)
  return takeUpdatesWithinResponseLimit(accessible.slice(0, limit).map(({ update }) => update))
}

async function claimWebhookDeliveries(limit: number): Promise<WebhookDeliveryClaim[]> {
  const now = new Date()
  return db.transaction(async (tx) => {
    const candidates = await tx
      .select({ stream: botUpdateStreams, row: botUpdates })
      .from(botUpdates)
      .innerJoin(botUpdateStreams, eq(botUpdateStreams.botUserId, botUpdates.botUserId))
      .where(and(
        isNotNull(botUpdateStreams.webhookUrl),
        gt(botUpdates.updateId, botUpdateStreams.acknowledgedUpdateId),
        gt(botUpdates.expiresAt, now),
        lte(botUpdates.nextAttemptAt, now),
        or(
          isNull(botUpdates.claimToken),
          lte(botUpdates.claimExpiresAt, now),
          sql`${botUpdates.claimGeneration} is distinct from ${botUpdateStreams.configGeneration}`,
        ),
      ))
      .orderBy(asc(botUpdates.nextAttemptAt), asc(botUpdates.updateId))
      .limit(limit)
      .for("update", { skipLocked: true })

    const claimed: WebhookDeliveryClaim[] = []
    for (const candidate of candidates) {
      let update: BotUpdate
      try {
        update = decryptUpdate(candidate.row.payloadEncrypted)
      } catch {
        await tx.delete(botUpdates).where(eq(botUpdates.id, candidate.row.id))
        await tx
          .update(botUpdateStreams)
          .set({
            pendingUpdateCount: subtractCounter(botUpdateStreams.pendingUpdateCount, 1),
            pendingPayloadBytes: subtractCounter(botUpdateStreams.pendingPayloadBytes, candidate.row.payloadByteCount),
            droppedUpdateCount: sql`${botUpdateStreams.droppedUpdateCount} + 1`,
            updatedAt: now,
          })
          .where(eq(botUpdateStreams.botUserId, candidate.row.botUserId))
        log.warn("Discarded unreadable Bot webhook update", {
          botUserId: candidate.row.botUserId,
          updateId: candidate.row.updateId,
        })
        continue
      }
      const claimToken = randomUUID()
      await tx
        .update(botUpdates)
        .set({
          claimToken,
          claimGeneration: candidate.stream.configGeneration,
          claimExpiresAt: new Date(now.getTime() + deliveryLeaseMs),
        })
        .where(eq(botUpdates.id, candidate.row.id))
      claimed.push({
        stream: candidate.stream,
        updateRowId: candidate.row.id,
        update,
        claimToken,
        claimGeneration: candidate.stream.configGeneration,
        attemptCount: candidate.row.attemptCount,
      })
    }
    return claimed
  })
}

async function finishWebhookDelivery(
  claim: WebhookDeliveryClaim,
  options: { dropped: boolean },
): Promise<boolean> {
  return db.transaction(async (tx) => {
    const [stream] = await tx
      .select()
      .from(botUpdateStreams)
      .where(and(
        eq(botUpdateStreams.botUserId, claim.stream.botUserId),
        eq(botUpdateStreams.configGeneration, claim.claimGeneration),
      ))
      .for("update")
      .limit(1)
    if (!stream) return false
    const [deleted] = await tx
      .delete(botUpdates)
      .where(and(
        eq(botUpdates.id, claim.updateRowId),
        eq(botUpdates.botUserId, claim.stream.botUserId),
        eq(botUpdates.claimToken, claim.claimToken),
        eq(botUpdates.claimGeneration, claim.claimGeneration),
      ))
      .returning({ payloadByteCount: botUpdates.payloadByteCount })
    if (!deleted) return false
    await tx
      .update(botUpdateStreams)
      .set({
        pendingUpdateCount: subtractCounter(botUpdateStreams.pendingUpdateCount, 1),
        pendingPayloadBytes: subtractCounter(botUpdateStreams.pendingPayloadBytes, deleted.payloadByteCount),
        droppedUpdateCount: options.dropped
          ? sql`${botUpdateStreams.droppedUpdateCount} + 1`
          : stream.droppedUpdateCount,
        lastErrorAt: options.dropped ? stream.lastErrorAt : null,
        lastErrorMessage: options.dropped ? stream.lastErrorMessage : null,
        updatedAt: new Date(),
      })
      .where(eq(botUpdateStreams.botUserId, claim.stream.botUserId))
    return true
  })
}

const markWebhookDelivered = (claim: WebhookDeliveryClaim): Promise<boolean> =>
  finishWebhookDelivery(claim, { dropped: false })

const discardWebhookDelivery = (claim: WebhookDeliveryClaim): Promise<boolean> =>
  finishWebhookDelivery(claim, { dropped: true })

async function markWebhookFailed(input: {
  claim: WebhookDeliveryClaim
  error: string
  retryAt: Date
}): Promise<boolean> {
  return db.transaction(async (tx) => {
    const [stream] = await tx
      .select({ botUserId: botUpdateStreams.botUserId })
      .from(botUpdateStreams)
      .where(and(
        eq(botUpdateStreams.botUserId, input.claim.stream.botUserId),
        eq(botUpdateStreams.configGeneration, input.claim.claimGeneration),
      ))
      .for("update")
      .limit(1)
    if (!stream) return false
    const [updated] = await tx
      .update(botUpdates)
      .set({
        attemptCount: sql`${botUpdates.attemptCount} + 1`,
        nextAttemptAt: input.retryAt,
        claimToken: null,
        claimGeneration: null,
        claimExpiresAt: null,
      })
      .where(and(
        eq(botUpdates.id, input.claim.updateRowId),
        eq(botUpdates.claimToken, input.claim.claimToken),
        eq(botUpdates.claimGeneration, input.claim.claimGeneration),
      ))
      .returning({ id: botUpdates.id })
    if (!updated) return false
    await tx
      .update(botUpdateStreams)
      .set({
        lastErrorAt: new Date(),
        lastErrorMessage: input.error.slice(0, 1_000),
        updatedAt: new Date(),
      })
      .where(eq(botUpdateStreams.botUserId, input.claim.stream.botUserId))
    return true
  })
}

const decryptWebhookSecret = (stream: DbBotUpdateStream): string | undefined =>
  stream.webhookSecretEncrypted
    ? Encryption2.decryptToString(stream.webhookSecretEncrypted)
    : undefined

async function acquirePoll(botUserId: number, timeoutSeconds: number): Promise<PollClaim> {
  await ensureStream(botUserId)
  const now = new Date()
  const token = randomUUID()
  const [leased] = await db
    .update(botUpdateStreams)
    .set({ pollLeaseToken: token, pollLeaseExpiresAt: new Date(now.getTime() + Math.max(pollLeaseMs, timeoutSeconds * 1_000 + 5_000)) })
    .where(and(
      eq(botUpdateStreams.botUserId, botUserId),
      isNull(botUpdateStreams.webhookUrl),
    ))
    .returning({ token: botUpdateStreams.pollLeaseToken, generation: botUpdateStreams.configGeneration })
  if (leased?.token) {
    botUpdateWaiters.wake(botUserId)
    return { token: leased.token, generation: leased.generation }
  }
  const current = await ensureStream(botUserId)
  if (current.webhookUrl) throw new InlineError(InlineError.ApiError.WEBHOOK_ACTIVE)
  throw new InlineError(InlineError.ApiError.POLL_CONFLICT)
}

async function releasePoll(botUserId: number, token: string): Promise<void> {
  await db
    .update(botUpdateStreams)
    .set({ pollLeaseToken: null, pollLeaseExpiresAt: null })
    .where(and(eq(botUpdateStreams.botUserId, botUserId), eq(botUpdateStreams.pollLeaseToken, token)))
}

async function getUpdates(botUserId: number, input: GetUpdatesParams, signal?: AbortSignal): Promise<BotUpdate[]> {
  const timeout = input.timeout ?? 0
  const claim = await acquirePoll(botUserId, timeout)
  try {
    await configurePoll(botUserId, claim, input)
    const offset = input.offset === undefined ? undefined : Number(input.offset)
    if (offset !== undefined) await acknowledge(botUserId, offset, claim)
    const deadline = Date.now() + timeout * 1_000
    while (true) {
      signal?.throwIfAborted()
      // Subscribe before reading so an update committed during the read cannot be missed.
      const waiter = botUpdateWaiters.subscribe(botUserId, signal)
      try {
        const updates = await readPending(botUserId, input.limit ?? 100, claim)
        signal?.throwIfAborted()
        if (updates.length > 0 || Date.now() >= deadline || isServerShuttingDown()) return updates
        await waiter.wait(Math.min(pollFallbackMs, Math.max(1, deadline - Date.now())))
      } finally {
        waiter.close()
      }
    }
  } finally {
    await releasePoll(botUserId, claim.token)
  }
}

async function setWebhook(botUserId: number, input: SetWebhookParams): Promise<true> {
  if (input.url === "") return deleteWebhook(botUserId, input)
  await ensureStream(botUserId)
  await db.transaction(async (tx) => {
    const [stream] = await tx
      .select()
      .from(botUpdateStreams)
      .where(eq(botUpdateStreams.botUserId, botUserId))
      .for("update")
      .limit(1)
    if (!stream) throw new Error("Failed to configure Bot webhook")
    await tx
      .update(botUpdateStreams)
      .set({
        webhookUrl: input.url,
        webhookSecretEncrypted: input.secret_token ? Encryption2.encrypt(Buffer.from(input.secret_token, "utf8")) : null,
        pollLeaseToken: null,
        pollLeaseExpiresAt: null,
        configGeneration: stream.configGeneration + 1,
        allowedUpdates: uniqueUpdates(input.allowed_updates, stream.allowedUpdates),
        messageTrigger: input.message_trigger ?? stream.messageTrigger,
        acknowledgedUpdateId: input.drop_pending_updates ? stream.nextUpdateId - 1 : stream.acknowledgedUpdateId,
        pendingUpdateCount: input.drop_pending_updates ? 0 : stream.pendingUpdateCount,
        pendingPayloadBytes: input.drop_pending_updates ? 0 : stream.pendingPayloadBytes,
        attemptCount: 0,
        nextAttemptAt: null,
        deliveryLockedAt: null,
        lastErrorAt: null,
        lastErrorMessage: null,
        updatedAt: new Date(),
      })
      .where(eq(botUpdateStreams.botUserId, botUserId))
  })
  botUpdateWaiters.wake(botUserId)
  return true
}

async function deleteWebhook(
  botUserId: number,
  input: DeleteWebhookParams & Partial<Pick<SetWebhookParams, "allowed_updates" | "message_trigger">> = {},
): Promise<true> {
  await ensureStream(botUserId)
  await db.transaction(async (tx) => {
    const [stream] = await tx
      .select()
      .from(botUpdateStreams)
      .where(eq(botUpdateStreams.botUserId, botUserId))
      .for("update")
      .limit(1)
    if (!stream) throw new Error("Failed to delete Bot webhook")
    await tx
      .update(botUpdateStreams)
      .set({
        webhookUrl: null,
        webhookSecretEncrypted: null,
        pollLeaseToken: null,
        pollLeaseExpiresAt: null,
        configGeneration: stream.configGeneration + 1,
        allowedUpdates: uniqueUpdates(input.allowed_updates, stream.allowedUpdates),
        messageTrigger: input.message_trigger ?? stream.messageTrigger,
        acknowledgedUpdateId: input.drop_pending_updates ? stream.nextUpdateId - 1 : stream.acknowledgedUpdateId,
        pendingUpdateCount: input.drop_pending_updates ? 0 : stream.pendingUpdateCount,
        pendingPayloadBytes: input.drop_pending_updates ? 0 : stream.pendingPayloadBytes,
        deliveryLockedAt: null,
        attemptCount: 0,
        nextAttemptAt: null,
        lastErrorAt: null,
        lastErrorMessage: null,
        updatedAt: new Date(),
      })
      .where(eq(botUpdateStreams.botUserId, botUserId))
  })
  botUpdateWaiters.wake(botUserId)
  return true
}

async function cleanupBotUpdateRowsForBot(botUserId: number, limit: number): Promise<number> {
  return db.transaction(async (tx) => {
    const [stream] = await tx
      .select()
      .from(botUpdateStreams)
      .where(eq(botUpdateStreams.botUserId, botUserId))
      .for("update")
      .limit(1)
    if (!stream) return 0
    const now = new Date()
    const rows = await tx
      .select()
      .from(botUpdates)
      .where(and(
        eq(botUpdates.botUserId, botUserId),
        or(lte(botUpdates.updateId, stream.acknowledgedUpdateId), lte(botUpdates.expiresAt, now)),
      ))
      .orderBy(asc(botUpdates.updateId))
      .limit(limit)
      .for("update", { skipLocked: true })
    if (rows.length === 0) return 0
    const expiredPending = rows.filter(
      (row) => row.updateId > stream.acknowledgedUpdateId && row.expiresAt <= now,
    )
    await tx.delete(botUpdates).where(inArray(botUpdates.id, rows.map((row) => row.id)))
    if (expiredPending.length > 0) {
      const payloadBytes = expiredPending.reduce((total, row) => total + row.payloadByteCount, 0)
      await tx
        .update(botUpdateStreams)
        .set({
          pendingUpdateCount: subtractCounter(botUpdateStreams.pendingUpdateCount, expiredPending.length),
          pendingPayloadBytes: subtractCounter(botUpdateStreams.pendingPayloadBytes, payloadBytes),
          droppedUpdateCount: sql`${botUpdateStreams.droppedUpdateCount} + ${expiredPending.length}`,
          updatedAt: now,
        })
        .where(eq(botUpdateStreams.botUserId, botUserId))
    }
    return rows.length
  })
}

async function cleanupBotUpdateRows(limit = cleanupBatchSize, botUserId?: number): Promise<number> {
  if (botUserId !== undefined) return cleanupBotUpdateRowsForBot(botUserId, limit)
  const now = new Date()
  const candidates = await db
    .selectDistinct({ botUserId: botUpdates.botUserId })
    .from(botUpdates)
    .innerJoin(botUpdateStreams, eq(botUpdateStreams.botUserId, botUpdates.botUserId))
    .where(or(
      lte(botUpdates.expiresAt, now),
      lte(botUpdates.updateId, botUpdateStreams.acknowledgedUpdateId),
    ))
    .limit(Math.min(25, limit))
  let removed = 0
  for (const candidate of candidates) {
    if (removed >= limit) break
    removed += await cleanupBotUpdateRowsForBot(candidate.botUserId, limit - removed)
  }
  return removed
}

async function cleanupBotMessageRoutes(limit = cleanupBatchSize): Promise<number> {
  const removed = await db.execute<{ botUserId: number }>(sql`
    with expired as (
      select ctid
      from bot_message_routes
      where expires_at <= now()
      order by expires_at
      limit ${limit}
      for update skip locked
    )
    delete from bot_message_routes route
    using expired
    where route.ctid = expired.ctid
    returning route.bot_user_id as "botUserId"
  `)
  return removed.length
}

async function getWebhookInfo(botUserId: number): Promise<WebhookInfo> {
  await cleanupBotUpdateRows(cleanupBatchSize, botUserId)
  const stream = await ensureStream(botUserId)
  return {
    url: stream.webhookUrl ?? "",
    pending_update_count: stream.pendingUpdateCount,
    allowed_updates: uniqueUpdates(undefined, stream.allowedUpdates),
    message_trigger: stream.messageTrigger as BotMessageTrigger,
    last_error_date: stream.lastErrorAt ? Math.floor(stream.lastErrorAt.getTime() / 1_000) : undefined,
    last_error_message: stream.lastErrorMessage ?? undefined,
    dropped_update_count: stream.droppedUpdateCount,
  }
}

async function getStreamsForBotUserIds(botUserIds: number[]): Promise<DbBotUpdateStream[]> {
  const ids = Array.from(new Set(botUserIds.filter((id) => Number.isSafeInteger(id) && id > 0)))
  if (ids.length === 0) return []
  return db.select().from(botUpdateStreams).where(inArray(botUpdateStreams.botUserId, ids))
}

async function recordMessageRoute(input: {
  botUserId: number
  chatId: number
  messageId: number
  activationReason: string
}): Promise<void> {
  await db.insert(botMessageRoutes).values({
    ...input,
    expiresAt: new Date(Date.now() + BOT_UPDATE_QUEUE_LIMITS.ttlMs),
  }).onConflictDoUpdate({
    target: [botMessageRoutes.botUserId, botMessageRoutes.chatId, botMessageRoutes.messageId],
    set: { activationReason: input.activationReason, expiresAt: new Date(Date.now() + BOT_UPDATE_QUEUE_LIMITS.ttlMs) },
  })
}

async function getMessageRoutes(chatId: number, messageIds: number[]) {
  if (messageIds.length === 0) return []
  return db.select().from(botMessageRoutes).where(and(
    eq(botMessageRoutes.chatId, chatId),
    inArray(botMessageRoutes.messageId, messageIds),
    gt(botMessageRoutes.expiresAt, new Date()),
  ))
}

async function deleteMessageRoutes(chatId: number, messageIds: number[]): Promise<void> {
  if (messageIds.length === 0) return
  await db.delete(botMessageRoutes).where(and(
    eq(botMessageRoutes.chatId, chatId),
    inArray(botMessageRoutes.messageId, messageIds),
  ))
}

export const BotUpdatesModel = {
  acknowledge,
  canBotAccessUpdate,
  cleanupBotMessageRoutes,
  cleanupBotUpdateRows,
  decryptUpdate,
  deleteWebhook,
  deleteMessageRoutes,
  discardWebhookDelivery,
  ensureStream,
  getUpdates,
  getStreamsForBotUserIds,
  getMessageRoutes,
  getWebhookInfo,
  claimWebhookDeliveries,
  decryptWebhookSecret,
  markWebhookDelivered,
  markWebhookFailed,
  queue,
  recordMessageRoute,
  setWebhook,
}
