import { describe, expect, it } from "bun:test"
import { app } from "../../legacyServer"
import { db } from "@in/server/db"
import { chats, messages, superadminSessions, superadminUsers, users } from "@in/server/db/schema"
import { generateToken } from "@in/server/utils/auth"
import { setupTestLifecycle } from "../setup"

const ADMIN_ORIGIN = "http://localhost:5174"

const startOfUtcDay = () => {
  const date = new Date()
  date.setUTCHours(0, 0, 0, 0)
  return date
}

const dateForDay = (daysAgo: number) => {
  return new Date(startOfUtcDay().getTime() - daysAgo * 24 * 60 * 60 * 1000 + 1)
}

const buildAdminRequest = (path: string, cookie: string) => {
  return new Request(`http://localhost${path}`, {
    headers: {
      Cookie: cookie,
      origin: ADMIN_ORIGIN,
      "user-agent": "admin-metrics-test",
    },
  })
}

const createAdminCookie = async () => {
  const [user] = await db
    .insert(users)
    .values({ email: "metrics-admin@example.com", date: dateForDay(30) })
    .returning()
  if (!user?.email) throw new Error("Failed to create metrics admin")

  await db.insert(superadminUsers).values({
    email: user.email,
    userId: user.id,
    passwordHash: "configured",
    passwordSetAt: new Date(),
    totpEnabledAt: new Date(),
  })

  const { token, tokenHash } = await generateToken(user.id)
  const now = new Date()
  await db.insert(superadminSessions).values({
    userId: user.id,
    tokenHash,
    lastSeenAt: now,
    expiresAt: new Date(now.getTime() + 24 * 60 * 60 * 1000),
    idleExpiresAt: new Date(now.getTime() + 24 * 60 * 60 * 1000),
  })

  return `inline_admin_session=${token}`
}

describe("Admin activity metrics", () => {
  setupTestLifecycle()

  it("returns 14 UTC daily buckets and the requested active-user audiences", async () => {
    const cookie = await createAdminCookie()
    const [todayUser, weekUser, oldUser, deletedUser, botUser] = await db
      .insert(users)
      .values([
        { email: "today@example.com", date: dateForDay(0) },
        { email: "week@example.com", date: dateForDay(2) },
        { email: "old@example.com", date: dateForDay(20) },
        { email: "deleted@example.com", date: dateForDay(0), deleted: true },
        { email: "bot@example.com", date: dateForDay(0), bot: true },
      ])
      .returning()

    expect(todayUser).toBeDefined()
    expect(weekUser).toBeDefined()
    expect(oldUser).toBeDefined()
    expect(deletedUser).toBeDefined()
    expect(botUser).toBeDefined()
    if (!todayUser || !weekUser || !oldUser || !deletedUser || !botUser) {
      throw new Error("Failed to create metric users")
    }

    const [chat] = await db
      .insert(chats)
      .values({ type: "thread", title: "Metrics test", publicThread: true, createdBy: todayUser.id })
      .returning()
    if (!chat) throw new Error("Failed to create metrics chat")

    await db.insert(messages).values([
      { chatId: chat.id, messageId: 1, fromId: todayUser.id, date: dateForDay(0) },
      { chatId: chat.id, messageId: 2, fromId: todayUser.id, date: dateForDay(1) },
      { chatId: chat.id, messageId: 3, fromId: todayUser.id, date: dateForDay(2) },
      { chatId: chat.id, messageId: 4, fromId: weekUser.id, date: dateForDay(1) },
      { chatId: chat.id, messageId: 5, fromId: weekUser.id, date: dateForDay(3) },
      { chatId: chat.id, messageId: 6, fromId: weekUser.id, date: dateForDay(5) },
      { chatId: chat.id, messageId: 7, fromId: oldUser.id, date: dateForDay(0) },
      { chatId: chat.id, messageId: 8, fromId: deletedUser.id, date: dateForDay(0) },
      { chatId: chat.id, messageId: 9, fromId: botUser.id, date: dateForDay(0) },
    ])

    const overviewResponse = await app.handle(buildAdminRequest("/admin/metrics/overview", cookie))
    expect(overviewResponse.status).toBe(200)
    const overview = await overviewResponse.json()
    expect(overview).toMatchObject({ ok: true, metrics: { dau: 2, wau: 2 } })

    const dailyActivity = overview.metrics.dailyActivity as Array<{
      date: string
      activeUsers: number
      newUsers: number
    }>
    expect(dailyActivity).toHaveLength(14)
    expect(dailyActivity.at(-1)).toMatchObject({
      date: startOfUtcDay().toISOString(),
      activeUsers: 2,
      newUsers: 1,
    })
    expect(dailyActivity.at(-3)).toMatchObject({ activeUsers: 1, newUsers: 1 })

    const todayResponse = await app.handle(
      buildAdminRequest("/admin/metrics/active-users?period=today", cookie),
    )
    expect(todayResponse.status).toBe(200)
    const today = await todayResponse.json()
    expect(today).toMatchObject({ ok: true, period: "today", limit: 200 })
    expect(today.users.map((user: { email: string }) => user.email).sort()).toEqual([
      "old@example.com",
      "today@example.com",
    ])

    const weekResponse = await app.handle(buildAdminRequest("/admin/metrics/active-users?period=week", cookie))
    expect(weekResponse.status).toBe(200)
    const week = await weekResponse.json()
    expect(week).toMatchObject({ ok: true, period: "week", limit: 200 })
    expect(week.users.map((user: { email: string }) => user.email).sort()).toEqual([
      "today@example.com",
      "week@example.com",
    ])
    expect(week.users.every((user: { activeDays: number }) => user.activeDays >= 3)).toBe(true)
  })
})
