import type {
  BotMessageTrigger,
  BotUpdate,
  BotUpdateKey,
  DeleteWebhookParams,
  GetUpdatesParams,
  SetWebhookParams,
  WebhookInfo,
} from "@inline-chat/bot-api-types"
import { randomBytes, randomInt } from "crypto"
import { and, asc, count, eq, gt, inArray, isNotNull, isNull, lte, or, sql } from "drizzle-orm"
import { db } from "@in/server/db"
import { botMessageRoutes, botUpdates, botUpdateStreams, type DbBotUpdateStream } from "@in/server/db/schema"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { InlineError } from "@in/server/types/errors"

const updateTtlMs = 24 * 60 * 60 * 1_000
const pollLeaseMs = 55_000
const deliveryLeaseMs = 30_000
const defaultUpdates: BotUpdateKey[] = [
  "message",
  "edited_message",
  "deleted_messages",
  "message_action",
  "bot_participation",
]
const allUpdates: BotUpdateKey[] = [...defaultUpdates, "message_reaction"]

const uniqueUpdates = (value: BotUpdateKey[] | undefined, previous?: string[]): BotUpdateKey[] => {
  const source = value === undefined ? previous ?? defaultUpdates : value.length === 0 ? defaultUpdates : value
  return Array.from(new Set(source.filter((key): key is BotUpdateKey => allUpdates.includes(key as BotUpdateKey))))
}

const initialUpdateId = () => randomInt(1_000_000, 1_000_000_000)
const encryptJson = (value: unknown) => Encryption2.encrypt(Buffer.from(JSON.stringify(value), "utf8"))
const decryptUpdate = (value: Buffer): BotUpdate =>
  JSON.parse(Encryption2.decryptToString(value)) as BotUpdate

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
  return db.transaction(async (tx) => {
    const [stream] = await tx
      .select()
      .from(botUpdateStreams)
      .where(eq(botUpdateStreams.botUserId, input.botUserId))
      .for("update")
      .limit(1)
    if (!stream || !uniqueUpdates(undefined, stream.allowedUpdates).includes(input.updateType)) return undefined

    const update = { update_id: stream.nextUpdateId, ...input.payload } as BotUpdate
    const inserted = await tx
      .insert(botUpdates)
      .values({
        botUserId: input.botUserId,
        updateId: stream.nextUpdateId,
        updateType: input.updateType,
        payloadEncrypted: encryptJson(update),
        sourceEventId: input.sourceEventId,
        expiresAt: new Date(Date.now() + updateTtlMs),
      })
      .onConflictDoNothing()
      .returning({ id: botUpdates.id })
    if (inserted.length === 0) return undefined
    await tx
      .update(botUpdateStreams)
      .set({ nextUpdateId: stream.nextUpdateId + 1, updatedAt: new Date() })
      .where(eq(botUpdateStreams.botUserId, input.botUserId))
    return update
  })
}

async function configureStream(
  botUserId: number,
  input: Pick<GetUpdatesParams, "allowed_updates" | "message_trigger">,
): Promise<DbBotUpdateStream> {
  const current = await ensureStream(botUserId)
  if (input.allowed_updates === undefined && input.message_trigger === undefined) return current
  const [updated] = await db
    .update(botUpdateStreams)
    .set({
      allowedUpdates: uniqueUpdates(input.allowed_updates, current.allowedUpdates),
      messageTrigger: input.message_trigger ?? current.messageTrigger,
      updatedAt: new Date(),
    })
    .where(eq(botUpdateStreams.botUserId, botUserId))
    .returning()
  if (!updated) throw new Error("Failed to configure bot update stream")
  return updated
}

async function acknowledge(botUserId: number, offset: number): Promise<void> {
  const stream = await ensureStream(botUserId)
  const lastIssued = stream.nextUpdateId - 1
  const acknowledged = Math.min(lastIssued, offset - 1)
  if (acknowledged <= stream.acknowledgedUpdateId) return
  await db
    .update(botUpdateStreams)
    .set({ acknowledgedUpdateId: acknowledged, updatedAt: new Date() })
    .where(eq(botUpdateStreams.botUserId, botUserId))
}

async function readPending(botUserId: number, limit: number): Promise<BotUpdate[]> {
  await expirePending(botUserId)
  const stream = await ensureStream(botUserId)
  const rows = await db
    .select({ payload: botUpdates.payloadEncrypted })
    .from(botUpdates)
    .where(
      and(
        eq(botUpdates.botUserId, botUserId),
        gt(botUpdates.updateId, stream.acknowledgedUpdateId),
        gt(botUpdates.expiresAt, new Date()),
      ),
    )
    .orderBy(asc(botUpdates.updateId))
    .limit(limit)
  return rows.map((row) => decryptUpdate(row.payload))
}

async function expirePending(botUserId: number): Promise<void> {
  const stream = await ensureStream(botUserId)
  const expired = await db.select({ updateId: botUpdates.updateId }).from(botUpdates).where(and(
    eq(botUpdates.botUserId, botUserId),
    gt(botUpdates.updateId, stream.acknowledgedUpdateId),
    lte(botUpdates.expiresAt, new Date()),
  )).orderBy(asc(botUpdates.updateId)).limit(1_000)
  if (expired.length === 0) return
  await db.update(botUpdateStreams).set({
    acknowledgedUpdateId: expired[expired.length - 1]!.updateId,
    droppedUpdateCount: sql`${botUpdateStreams.droppedUpdateCount} + ${expired.length}`,
    updatedAt: new Date(),
  }).where(eq(botUpdateStreams.botUserId, botUserId))
}

async function claimWebhookDeliveries(limit: number): Promise<Array<{
  stream: DbBotUpdateStream
  update: BotUpdate
}>> {
  const now = new Date()
  const stale = new Date(now.getTime() - deliveryLeaseMs)
  const candidates = await db
    .select()
    .from(botUpdateStreams)
    .where(and(
      isNotNull(botUpdateStreams.webhookUrl),
      or(isNull(botUpdateStreams.nextAttemptAt), lte(botUpdateStreams.nextAttemptAt, now)),
      or(isNull(botUpdateStreams.deliveryLockedAt), lte(botUpdateStreams.deliveryLockedAt, stale)),
    ))
    .limit(limit)
  const claimed: Array<{ stream: DbBotUpdateStream; update: BotUpdate }> = []
  for (const candidate of candidates) {
    const [locked] = await db.update(botUpdateStreams).set({ deliveryLockedAt: now }).where(and(
      eq(botUpdateStreams.botUserId, candidate.botUserId),
      or(isNull(botUpdateStreams.deliveryLockedAt), lte(botUpdateStreams.deliveryLockedAt, stale)),
    )).returning()
    if (!locked) continue
    const [update] = await readPending(candidate.botUserId, 1)
    if (!update) {
      await db.update(botUpdateStreams).set({ deliveryLockedAt: null }).where(eq(botUpdateStreams.botUserId, candidate.botUserId))
      continue
    }
    claimed.push({ stream: locked, update })
  }
  return claimed
}

async function markWebhookDelivered(botUserId: number, updateId: number): Promise<void> {
  await db.update(botUpdateStreams).set({
    acknowledgedUpdateId: updateId,
    attemptCount: 0,
    nextAttemptAt: null,
    deliveryLockedAt: null,
    lastErrorAt: null,
    lastErrorMessage: null,
    updatedAt: new Date(),
  }).where(eq(botUpdateStreams.botUserId, botUserId))
}

async function markWebhookFailed(input: {
  botUserId: number
  error: string
  retryAt: Date
}): Promise<void> {
  await db.update(botUpdateStreams).set({
    attemptCount: sql`${botUpdateStreams.attemptCount} + 1`,
    nextAttemptAt: input.retryAt,
    deliveryLockedAt: null,
    lastErrorAt: new Date(),
    lastErrorMessage: input.error.slice(0, 1_000),
    updatedAt: new Date(),
  }).where(eq(botUpdateStreams.botUserId, input.botUserId))
}

const decryptWebhookSecret = (stream: DbBotUpdateStream): string | undefined =>
  stream.webhookSecretEncrypted
    ? Encryption2.decryptToString(stream.webhookSecretEncrypted)
    : undefined

async function acquirePoll(botUserId: number, timeoutSeconds: number): Promise<string> {
  const stream = await ensureStream(botUserId)
  if (stream.webhookUrl) throw new InlineError(InlineError.ApiError.WEBHOOK_ACTIVE)
  const now = new Date()
  const token = randomBytes(20).toString("hex")
  const [leased] = await db
    .update(botUpdateStreams)
    .set({ pollLeaseToken: token, pollLeaseExpiresAt: new Date(now.getTime() + Math.max(pollLeaseMs, timeoutSeconds * 1_000 + 5_000)) })
    .where(
      and(
        eq(botUpdateStreams.botUserId, botUserId),
        or(isNull(botUpdateStreams.pollLeaseExpiresAt), lte(botUpdateStreams.pollLeaseExpiresAt, now)),
      ),
    )
    .returning({ token: botUpdateStreams.pollLeaseToken })
  if (!leased) throw new InlineError(InlineError.ApiError.POLL_CONFLICT)
  return token
}

async function releasePoll(botUserId: number, token: string): Promise<void> {
  await db
    .update(botUpdateStreams)
    .set({ pollLeaseToken: null, pollLeaseExpiresAt: null })
    .where(and(eq(botUpdateStreams.botUserId, botUserId), eq(botUpdateStreams.pollLeaseToken, token)))
}

async function getUpdates(botUserId: number, input: GetUpdatesParams): Promise<BotUpdate[]> {
  const timeout = input.timeout ?? 0
  const token = await acquirePoll(botUserId, timeout)
  try {
    await configureStream(botUserId, input)
    const offset = input.offset === undefined ? undefined : Number(input.offset)
    if (offset !== undefined) await acknowledge(botUserId, offset)
    const deadline = Date.now() + timeout * 1_000
    let updates = await readPending(botUserId, input.limit ?? 100)
    while (updates.length === 0 && Date.now() < deadline) {
      await Bun.sleep(Math.min(250, Math.max(1, deadline - Date.now())))
      updates = await readPending(botUserId, input.limit ?? 100)
    }
    return updates
  } finally {
    await releasePoll(botUserId, token)
  }
}

async function dropPending(botUserId: number): Promise<void> {
  const stream = await ensureStream(botUserId)
  await db
    .update(botUpdateStreams)
    .set({ acknowledgedUpdateId: stream.nextUpdateId - 1, updatedAt: new Date() })
    .where(eq(botUpdateStreams.botUserId, botUserId))
}

async function setWebhook(botUserId: number, input: SetWebhookParams): Promise<true> {
  const current = await configureStream(botUserId, input)
  if (input.url === "") return deleteWebhook(botUserId, input)
  await db
    .update(botUpdateStreams)
    .set({
      webhookUrl: input.url,
      webhookSecretEncrypted: input.secret_token ? Encryption2.encrypt(Buffer.from(input.secret_token, "utf8")) : null,
      pollLeaseToken: null,
      pollLeaseExpiresAt: null,
      allowedUpdates: uniqueUpdates(input.allowed_updates, current.allowedUpdates),
      messageTrigger: input.message_trigger ?? current.messageTrigger,
      attemptCount: 0,
      nextAttemptAt: null,
      lastErrorAt: null,
      lastErrorMessage: null,
      updatedAt: new Date(),
    })
    .where(eq(botUpdateStreams.botUserId, botUserId))
  if (input.drop_pending_updates) await dropPending(botUserId)
  return true
}

async function deleteWebhook(botUserId: number, input: DeleteWebhookParams = {}): Promise<true> {
  await ensureStream(botUserId)
  await db
    .update(botUpdateStreams)
    .set({
      webhookUrl: null,
      webhookSecretEncrypted: null,
      deliveryLockedAt: null,
      attemptCount: 0,
      nextAttemptAt: null,
      updatedAt: new Date(),
    })
    .where(eq(botUpdateStreams.botUserId, botUserId))
  if (input.drop_pending_updates) await dropPending(botUserId)
  return true
}

async function pendingCount(stream: DbBotUpdateStream): Promise<number> {
  await expirePending(stream.botUserId)
  const current = await ensureStream(stream.botUserId)
  const [row] = await db
    .select({ value: count() })
    .from(botUpdates)
    .where(
      and(
        eq(botUpdates.botUserId, stream.botUserId),
        gt(botUpdates.updateId, current.acknowledgedUpdateId),
        gt(botUpdates.expiresAt, new Date()),
      ),
    )
  return Number(row?.value ?? 0)
}

async function getWebhookInfo(botUserId: number): Promise<WebhookInfo> {
  await expirePending(botUserId)
  const stream = await ensureStream(botUserId)
  return {
    url: stream.webhookUrl ?? "",
    pending_update_count: await pendingCount(stream),
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
    expiresAt: new Date(Date.now() + updateTtlMs),
  }).onConflictDoUpdate({
    target: [botMessageRoutes.botUserId, botMessageRoutes.chatId, botMessageRoutes.messageId],
    set: { activationReason: input.activationReason, expiresAt: new Date(Date.now() + updateTtlMs) },
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

export const BotUpdatesModel = {
  acknowledge,
  decryptUpdate,
  deleteWebhook,
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
  readPending,
  setWebhook,
}
