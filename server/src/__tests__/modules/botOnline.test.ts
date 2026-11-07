import { afterAll, afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import {
  BOT_HTTP_ACTIVE_WINDOW_MS,
  markBotOnline,
  stopBotOnlineSweeper,
  sweepLapsedBotOnline,
} from "@in/server/modules/bots/online"
import { connectionDirectory, type ConnectionRegistration } from "@in/server/modules/internalMessaging/directory"
import { eq } from "drizzle-orm"

describe("bot online status", () => {
  setupTestLifecycle()
  afterAll(() => stopBotOnlineSweeper())

  let botId = 0
  let personId = 0
  let connections: ConnectionRegistration[] = []
  let list: ReturnType<typeof spyOn>

  const row = async (id: number) => {
    const [user] = await db.select({ online: users.online, lastOnline: users.lastOnline }).from(users).where(eq(users.id, id))
    return user!
  }

  beforeEach(async () => {
    const [owner, bot, person] = await Promise.all(["owner", "bot", "person"].map((name) =>
      testUtils.createUser(`bot-online-${name}-${crypto.randomUUID()}@example.com`)))
    botId = bot!.id
    personId = person!.id
    await db.update(users).set({ bot: true, botCreatorId: owner!.id }).where(eq(users.id, botId))
    connections = []
    list = spyOn(connectionDirectory, "list").mockImplementation(async () => ({
      status: "available",
      complete: true,
      connections,
    }))
  })

  afterEach(() => list.mockRestore())

  test("activity turns a bot online once and refreshes last seen", async () => {
    const first = new Date(Date.now() - 1_000)
    expect(await markBotOnline(botId, first)).toBe(true)
    expect(await row(botId)).toEqual({ online: true, lastOnline: first })

    const second = new Date()
    expect(await markBotOnline(botId, second)).toBe(false)
    expect(await row(botId)).toEqual({ online: true, lastOnline: second })
  })

  test("people are never marked online by bot activity", async () => {
    expect(await markBotOnline(personId)).toBe(false)
    expect((await row(personId)).online).toBe(false)
  })

  test("a bot goes offline after its API activity lapses, keeping when it was last seen", async () => {
    const lastSeen = new Date(Date.now() - BOT_HTTP_ACTIVE_WINDOW_MS - 60_000)
    await markBotOnline(botId, lastSeen)

    expect(await sweepLapsedBotOnline()).toBe(1)
    expect(await row(botId)).toEqual({ online: false, lastOnline: lastSeen })
    expect(await sweepLapsedBotOnline()).toBe(0)
  })

  test("recent activity keeps a bot online", async () => {
    await markBotOnline(botId, new Date(Date.now() - 60_000))
    expect(await sweepLapsedBotOnline()).toBe(0)
    expect((await row(botId)).online).toBe(true)
  })

  test("a connected bot stays online and its last seen moves forward", async () => {
    const opened = new Date(Date.now() - BOT_HTTP_ACTIVE_WINDOW_MS - 60_000)
    await markBotOnline(botId, opened)
    connections = [{
      bootId: "boot",
      connectionId: "c1",
      userId: botId,
      sessionId: 1,
      clientType: "sdk",
      isBot: true,
      expiresAt: Date.now() + 45_000,
    }]

    expect(await sweepLapsedBotOnline()).toBe(0)
    const after = await row(botId)
    expect(after.online).toBe(true)
    expect(after.lastOnline!.getTime()).toBeGreaterThan(opened.getTime())
  })

  test("an unknown connection directory never turns a bot offline", async () => {
    list.mockImplementation(async () => ({ status: "unavailable" }))
    await markBotOnline(botId, new Date(Date.now() - BOT_HTTP_ACTIVE_WINDOW_MS - 60_000))
    expect(await sweepLapsedBotOnline()).toBe(0)
    expect((await row(botId)).online).toBe(true)
  })
})
