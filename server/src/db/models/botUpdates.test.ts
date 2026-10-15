import { beforeEach, describe, expect, test } from "bun:test"
import type { BotUpdate } from "@inline-chat/bot-api-types"
import { and, eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { botUpdates, botUpdateStreams, chatParticipants } from "@in/server/db/schema"
import { markServerShuttingDown, resetServerShutdownStateForTests } from "@in/server/lifecycle/shutdownState"
import { botUpdateWaiters } from "./botUpdateWaiters"
import { makeBotWebhookTransport, runBotWebhookDeliveryOnce } from "@in/server/modules/botUpdates/delivery"
import {
  BOT_UPDATE_QUEUE_LIMITS,
  BotUpdatesModel,
  botUpdateChatId,
  takeUpdatesWithinResponseLimit,
} from "./botUpdates"

describe("BotUpdatesModel", () => {
  setupTestLifecycle()

  let botUserId: number
  let chatId: number

  beforeEach(async () => {
    const bot = await testUtils.createUser(`bot-updates-${crypto.randomUUID()}@example.com`)
    const chat = await testUtils.createChat(null, "Bot queue", "thread", false, bot.id)
    if (!chat) throw new Error("Failed to create Bot queue test chat")
    await testUtils.addParticipant(chat.id, bot.id)
    botUserId = bot.id
    chatId = chat.id
    await BotUpdatesModel.ensureStream(botUserId)
  })

  test("enforces Telegram-aligned per-update and per-stream safety limits", async () => {
    const first = await queueParticipation(botUserId, chatId, "first")
    expect(first).toBeDefined()

    let stream = await streamFor(botUserId)
    expect(stream.pendingUpdateCount).toBe(1)
    expect(stream.pendingPayloadBytes).toBeGreaterThan(0)

    await db
      .update(botUpdateStreams)
      .set({ pendingUpdateCount: BOT_UPDATE_QUEUE_LIMITS.maxPendingUpdates })
      .where(eq(botUpdateStreams.botUserId, botUserId))
    expect(await queueParticipation(botUserId, chatId, "full")).toBeUndefined()

    stream = await streamFor(botUserId)
    expect(stream.droppedUpdateCount).toBe(1)
    await db
      .update(botUpdates)
      .set({ expiresAt: new Date(Date.now() - 1_000) })
      .where(and(eq(botUpdates.botUserId, botUserId), eq(botUpdates.updateId, first!.update_id)))
    expect(await queueParticipation(botUserId, chatId, "after-expiry")).toBeDefined()

    stream = await streamFor(botUserId)
    expect(stream.pendingUpdateCount).toBe(BOT_UPDATE_QUEUE_LIMITS.maxPendingUpdates)
    expect(stream.droppedUpdateCount).toBe(2)
    const nextUpdateId = stream.nextUpdateId
    const pendingPayloadBytes = stream.pendingPayloadBytes

    await db
      .update(botUpdateStreams)
      .set({
        pendingUpdateCount: 1,
        pendingPayloadBytes: BOT_UPDATE_QUEUE_LIMITS.maxPendingPayloadBytes,
      })
      .where(eq(botUpdateStreams.botUserId, botUserId))
    expect(await queueParticipation(botUserId, chatId, "byte-full")).toBeUndefined()

    await db
      .update(botUpdateStreams)
      .set({ pendingPayloadBytes })
      .where(eq(botUpdateStreams.botUserId, botUserId))
    expect(await queueAction(botUserId, chatId, "x".repeat(BOT_UPDATE_QUEUE_LIMITS.maxUpdatePayloadBytes))).toBeUndefined()

    stream = await streamFor(botUserId)
    expect(stream.droppedUpdateCount).toBe(4)
    expect(stream.nextUpdateId).toBe(nextUpdateId)
  })

  test("keeps a negative-offset tail and clears it only when explicitly requested", async () => {
    const first = await queueParticipation(botUserId, chatId, "first")
    const second = await queueParticipation(botUserId, chatId, "second")
    const third = await queueParticipation(botUserId, chatId, "third")

    const tail = await BotUpdatesModel.getUpdates(botUserId, { offset: -1, timeout: 0 })
    expect(tail.map((update) => update.update_id)).toEqual([third!.update_id])
    let stream = await streamFor(botUserId)
    expect(stream.acknowledgedUpdateId).toBe(second!.update_id)
    expect(stream.pendingUpdateCount).toBe(1)

    await BotUpdatesModel.setWebhook(botUserId, {
      url: "https://example.com/drop-tail",
      drop_pending_updates: true,
    })
    stream = await streamFor(botUserId)
    expect(stream.acknowledgedUpdateId).toBe(third!.update_id)
    expect(stream.pendingUpdateCount).toBe(0)
    expect(stream.pendingPayloadBytes).toBe(0)
    expect(first!.update_id).toBeLessThan(second!.update_id)
  })

  test("lets later webhook updates complete while an earlier update is retrying", async () => {
    await BotUpdatesModel.setWebhook(botUserId, { url: "https://example.com/first" })
    await queueParticipation(botUserId, chatId, "first")
    await queueParticipation(botUserId, chatId, "second")

    const queuedRows = await db.select().from(botUpdates).where(eq(botUpdates.botUserId, botUserId))
    expect(queuedRows).toHaveLength(2)
    expect(queuedRows.every((row) => row.nextAttemptAt <= new Date())).toBeTrue()
    const claims = await BotUpdatesModel.claimWebhookDeliveries(2)
    expect(claims).toHaveLength(2)
    await BotUpdatesModel.markWebhookFailed({
      claim: claims[0]!,
      error: "temporary",
      retryAt: new Date(Date.now() + 60_000),
    })
    expect(await BotUpdatesModel.markWebhookDelivered(claims[1]!)).toBeTrue()

    await queueParticipation(botUserId, chatId, "third")
    const [later] = await BotUpdatesModel.claimWebhookDeliveries(1)
    expect(later?.update.update_id).toBeGreaterThan(claims[1]!.update.update_id)
    expect((await streamFor(botUserId)).pendingUpdateCount).toBe(2)
  })

  test("fences a stale webhook acknowledgement after replacement", async () => {
    await BotUpdatesModel.setWebhook(botUserId, { url: "https://example.com/first" })
    const update = await queueParticipation(botUserId, chatId, "replace")
    const [stale] = await BotUpdatesModel.claimWebhookDeliveries(1)
    expect(stale?.update.update_id).toBe(update?.update_id)
    expect(await BotUpdatesModel.isCurrentWebhookClaim(stale!)).toBeTrue()

    await BotUpdatesModel.setWebhook(botUserId, { url: "https://example.com/replacement" })
    expect(await BotUpdatesModel.isCurrentWebhookClaim(stale!)).toBeFalse()
    expect(await BotUpdatesModel.markWebhookDelivered(stale!)).toBeFalse()

    const [replacement] = await BotUpdatesModel.claimWebhookDeliveries(1)
    expect(replacement?.update.update_id).toBe(update?.update_id)
    expect(replacement?.claimGeneration).toBeGreaterThan(stale!.claimGeneration)
  })

  test("reclaims a webhook update after an abandoned delivery lease expires", async () => {
    await BotUpdatesModel.setWebhook(botUserId, { url: "https://example.com/recover" })
    const update = await queueParticipation(botUserId, chatId, "recover")
    const [abandoned] = await BotUpdatesModel.claimWebhookDeliveries(1)
    expect(abandoned?.update.update_id).toBe(update?.update_id)
    await db
      .update(botUpdates)
      .set({ claimExpiresAt: new Date(Date.now() - 1_000) })
      .where(eq(botUpdates.id, abandoned!.updateRowId))

    const [recovered] = await BotUpdatesModel.claimWebhookDeliveries(1)
    expect(recovered?.update.update_id).toBe(update?.update_id)
    expect(recovered?.claimToken).not.toBe(abandoned?.claimToken)
    expect(await BotUpdatesModel.isCurrentWebhookClaim(abandoned!)).toBeFalse()
    expect(await BotUpdatesModel.isCurrentWebhookClaim(recovered!)).toBeTrue()
  })

  for (const change of ["replaced", "deleted", "expired lease", "reclaimed", "expired update", "access removed"] as const) {
    test(`does not open a webhook POST when ${change} during DNS resolution`, async () => {
      await BotUpdatesModel.setWebhook(botUserId, { url: "https://receiver.test/old", secret_token: "old-secret" })
      const update = await queueParticipation(botUserId, chatId, "paused DNS")
      const resolving = Promise.withResolvers<void>()
      const releaseDns = Promise.withResolvers<void>()
      let posts = 0
      const delivery = runBotWebhookDeliveryOnce(1, makeBotWebhookTransport({
        resolve: async (rawUrl) => {
          resolving.resolve()
          await releaseDns.promise
          return { url: new URL(rawUrl), address: "8.8.8.8", family: 4 }
        },
        request: () => {
          posts++
          throw new Error("A stale webhook must not open a connection")
        },
      }))
      try {
        await resolving.promise
        const [row] = await db.select().from(botUpdates).where(eq(botUpdates.botUserId, botUserId))
        if (!row?.claimToken) throw new Error("Expected an active webhook claim before DNS")
        if (change === "replaced") {
          await BotUpdatesModel.setWebhook(botUserId, { url: "https://receiver.test/new", secret_token: "new-secret" })
        } else if (change === "deleted") {
          await BotUpdatesModel.deleteWebhook(botUserId)
        } else if (change === "expired lease" || change === "reclaimed") {
          await db.update(botUpdates).set({ claimExpiresAt: new Date(Date.now() - 1_000) }).where(eq(botUpdates.id, row.id))
          if (change === "reclaimed") {
            const [replacement] = await BotUpdatesModel.claimWebhookDeliveries(1)
            expect(replacement?.claimToken).not.toBe(row.claimToken)
          }
        } else if (change === "expired update") {
          await db.update(botUpdates).set({ expiresAt: new Date(Date.now() - 1_000) }).where(eq(botUpdates.id, row.id))
        } else {
          await db.delete(chatParticipants).where(and(eq(chatParticipants.chatId, chatId), eq(chatParticipants.userId, botUserId)))
        }
        releaseDns.resolve()
        expect(await delivery).toBe(1)
        expect(posts).toBe(0)
        const pending = await db.select().from(botUpdates).where(eq(botUpdates.botUserId, botUserId))
        if (change === "access removed") {
          expect(pending).toHaveLength(0)
          expect((await streamFor(botUserId)).droppedUpdateCount).toBe(1)
        } else {
          expect(pending).toHaveLength(1)
          expect(pending[0]?.updateId).toBe(update?.update_id)
          expect(pending[0]?.attemptCount).toBe(0)
          expect((await streamFor(botUserId)).pendingUpdateCount).toBe(1)
        }
      } finally {
        releaseDns.resolve()
        await delivery
      }
    })
  }

  test("delivers a current claim and fences its ACK if the webhook changes after connection", async () => {
    await BotUpdatesModel.setWebhook(botUserId, { url: "https://receiver.test/old", secret_token: "old-secret" })
    const update = await queueParticipation(botUserId, chatId, "in flight")
    const posts: { url: string; updateId?: string; secret?: string }[] = []
    expect(await runBotWebhookDeliveryOnce(1, async (input) => {
      if (!await input.beforeConnect()) return undefined
      posts.push({ url: input.rawUrl, updateId: input.headers["x-inline-update-id"], secret: input.headers["x-inline-bot-api-secret-token"] })
      await BotUpdatesModel.setWebhook(botUserId, { url: "https://receiver.test/new", secret_token: "new-secret" })
      return { status: 200 }
    })).toBe(1)
    expect(posts).toEqual([{ url: "https://receiver.test/old", updateId: String(update?.update_id), secret: "old-secret" }])
    expect((await streamFor(botUserId)).pendingUpdateCount).toBe(1)
    expect(await runBotWebhookDeliveryOnce(1, async (input) => {
      if (!await input.beforeConnect()) return undefined
      posts.push({ url: input.rawUrl, updateId: input.headers["x-inline-update-id"], secret: input.headers["x-inline-bot-api-secret-token"] })
      return { status: 200 }
    })).toBe(1)
    expect(posts.at(-1)).toEqual({ url: "https://receiver.test/new", updateId: String(update?.update_id), secret: "new-secret" })
    expect((await streamFor(botUserId)).pendingUpdateCount).toBe(0)
  })

  test("lets a replacement poll proceed and cancels the older long poll", async () => {
    const older = BotUpdatesModel.getUpdates(botUserId, { timeout: 5 })
    const olderFailure = older.catch((error: unknown) => error)
    await waitForPollLease(botUserId)

    expect(await BotUpdatesModel.getUpdates(botUserId, { timeout: 0 })).toEqual([])
    expect(await olderFailure).toMatchObject({ type: "POLL_CONFLICT", code: 409 })
  })

  test("wakes a long poll when an update commits", async () => {
    const poll = BotUpdatesModel.getUpdates(botUserId, { timeout: 5 })
    await waitForPollLease(botUserId)

    const started = Date.now()
    const queued = await queueParticipation(botUserId, chatId, "wake")
    const updates = await poll
    expect(updates.map((update) => update.update_id)).toEqual([queued!.update_id])
    expect(Date.now() - started).toBeLessThan(1_500)
  })

  test("returns an empty poll at its requested deadline", async () => {
    const started = Date.now()
    expect(await BotUpdatesModel.getUpdates(botUserId, { timeout: 1 })).toEqual([])
    expect(Date.now() - started).toBeGreaterThanOrEqual(900)
  })

  test("ends a long poll when a webhook replaces it", async () => {
    const poll = BotUpdatesModel.getUpdates(botUserId, { timeout: 5 })
    const pollFailure = poll.catch((error: unknown) => error)
    await waitForPollLease(botUserId)

    await BotUpdatesModel.setWebhook(botUserId, { url: "https://example.com/poll-replacement" })
    expect(await pollFailure).toMatchObject({ type: "POLL_CONFLICT", code: 409 })
  })

  test("releases the poll lease when the client aborts", async () => {
    const controller = new AbortController()
    const poll = BotUpdatesModel.getUpdates(botUserId, { timeout: 5 }, controller.signal)
    await waitForPollLease(botUserId)

    controller.abort()
    await expect(poll).rejects.toMatchObject({ name: "AbortError" })
    expect((await streamFor(botUserId)).pollLeaseToken).toBeNull()
  })

  test("returns an empty poll promptly during shutdown", async () => {
    const poll = BotUpdatesModel.getUpdates(botUserId, { timeout: 5 })
    await waitForPollLease(botUserId)

    try {
      markServerShuttingDown()
      botUpdateWaiters.wakeAll()
      expect(await poll).toEqual([])
      expect((await streamFor(botUserId)).pollLeaseToken).toBeNull()
    } finally {
      resetServerShutdownStateForTests()
    }
  })

  test("drops inaccessible and expired rows without blocking polling", async () => {
    const inaccessible = await queueParticipation(botUserId, chatId, "inaccessible")
    await db
      .delete(chatParticipants)
      .where(and(eq(chatParticipants.chatId, chatId), eq(chatParticipants.userId, botUserId)))

    expect(await BotUpdatesModel.getUpdates(botUserId, { timeout: 0 })).toEqual([])
    expect((await streamFor(botUserId)).droppedUpdateCount).toBe(1)

    await testUtils.addParticipant(chatId, botUserId)
    const expired = await queueParticipation(botUserId, chatId, "expired")
    await db
      .update(botUpdates)
      .set({ expiresAt: new Date(Date.now() - 1_000) })
      .where(and(eq(botUpdates.botUserId, botUserId), eq(botUpdates.updateId, expired!.update_id)))
    await BotUpdatesModel.cleanupBotUpdateRows(1_000, botUserId)

    const stream = await streamFor(botUserId)
    expect(stream.pendingUpdateCount).toBe(0)
    expect(stream.droppedUpdateCount).toBe(2)
    expect(inaccessible?.update_id).toBeLessThan(expired!.update_id)
  })

  test("bounds polling responses without requiring contiguous update ids", () => {
    const updates = [1, 3, 8].map((updateId) => participationUpdate(updateId, chatId, "x".repeat(80)))
    expect(botUpdateChatId(updates[0]!)).toBe(chatId)
    expect(takeUpdatesWithinResponseLimit(updates, 250).map((update) => update.update_id)).toEqual([1])
  })
})

type BotParticipationUpdate = Extract<BotUpdate, { bot_participation: unknown }>

const participationUpdate = (updateId: number, chatId: number, title: string): BotParticipationUpdate => ({
  update_id: updateId,
  bot_participation: {
    chat: { chat_id: chatId, type: "thread", title },
    date: Math.floor(Date.now() / 1_000),
    status: "added",
  },
})

const queueParticipation = (botUserId: number, chatId: number, title: string) =>
  BotUpdatesModel.queue({
    botUserId,
    updateType: "bot_participation",
    payload: { bot_participation: participationUpdate(0, chatId, title).bot_participation },
  })

const queueAction = (botUserId: number, chatId: number, callbackData: string) =>
  BotUpdatesModel.queue({
    botUserId,
    updateType: "message_action",
    payload: {
      activation_reason: "action",
      message_action: {
        interaction_id: 1,
        chat: { chat_id: chatId, type: "thread" },
        message_id: 1,
        actor: { id: botUserId, is_bot: false },
        date: Math.floor(Date.now() / 1_000),
        action: { action_id: "large", callback_data: callbackData },
      },
    },
  })

const streamFor = async (botUserId: number) => {
  const [stream] = await db
    .select()
    .from(botUpdateStreams)
    .where(eq(botUpdateStreams.botUserId, botUserId))
    .limit(1)
  if (!stream) throw new Error("Missing Bot update stream")
  return stream
}

const waitForPollLease = async (botUserId: number): Promise<void> => {
  const deadline = Date.now() + 3_000
  while (Date.now() < deadline) {
    if ((await streamFor(botUserId)).pollLeaseToken) return
    await Bun.sleep(10)
  }
  throw new Error("Bot poll did not acquire a lease")
}
