import { describe, expect, it } from "bun:test"
import { Schema } from "effect"
import { db } from "@in/server/db"
import { chats, messages, users, waitlist } from "@in/server/db/schema"
import { setupTestLifecycle } from "../__tests__/setup"
import { getAppMetrics, getDailyActivity, getRecentOverviewActivity } from "./adminMetricsOperationsLive.effect"
import { AdminAppMetrics } from "./adminSchemas.effect"

setupTestLifecycle()

const snapshot = new Date("2026-03-01T12:00:00.000Z")
const midnight = new Date("2026-03-01T00:00:00.000Z")
const yesterday = new Date("2026-02-28T23:59:59.999Z")

describe("admin calendar activity", () => {
  it("uses UTC midnight, zero-fills days, counts distinct humans and excludes future/system/bot/deleted activity", async () => {
    const people = await db
      .insert(users)
      .values([
        { email: "yesterday@metrics.test", date: yesterday },
        { email: "today@metrics.test", date: midnight, pendingSetup: true },
        { email: "bot@metrics.test", date: midnight, bot: true },
        { email: "deleted@metrics.test", date: midnight, deleted: true },
        { email: "future@metrics.test", date: snapshot },
        { email: "system-only@metrics.test", date: new Date("2025-01-01T00:00:00Z") },
      ])
      .returning()
    const [chat] = await db.insert(chats).values({ type: "thread", date: midnight }).returning()
    await db.insert(messages).values([
      { chatId: chat!.id, messageId: 1, fromId: people[0]!.id, date: yesterday },
      { chatId: chat!.id, messageId: 2, fromId: people[1]!.id, date: midnight },
      { chatId: chat!.id, messageId: 3, fromId: people[1]!.id, date: new Date("2026-03-01T01:00:00Z") },
      { chatId: chat!.id, messageId: 4, fromId: people[2]!.id, date: midnight },
      { chatId: chat!.id, messageId: 5, fromId: people[3]!.id, date: midnight },
      { chatId: chat!.id, messageId: 6, fromId: people[4]!.id, date: snapshot },
      {
        chatId: chat!.id,
        messageId: 7,
        fromId: people[5]!.id,
        date: midnight,
        systemMessageEncrypted: Buffer.from("structural"),
      },
    ])
    const metrics = await getAppMetrics(snapshot)
    expect(() => Schema.decodeUnknownSync(AdminAppMetrics)(metrics)).not.toThrow()
    expect(metrics.dailyActivity).toHaveLength(97)
    expect(metrics.dailyActivity.at(-1)).toEqual({
      date: midnight.toISOString(),
      activeUsers: 1,
      messages: 2,
      newUsers: 1,
      threads: 1,
    })
    expect(metrics.dailyActivity.at(-2)).toMatchObject({
      date: "2026-02-28T00:00:00.000Z",
      activeUsers: 1,
      messages: 1,
      newUsers: 1,
    })
    expect(metrics.dailyActivity.at(-3)).toMatchObject({ activeUsers: 0, messages: 0, newUsers: 0, threads: 0 })
    expect(metrics).toMatchObject({
      dau: 1,
      messagesToday: 2,
      activeUsersLast7d: 2,
      wau: 0,
      reportingTimeZone: "UTC",
      asOf: snapshot.toISOString(),
    })
    expect(metrics.weeklyActivity.at(-1)).toMatchObject({ activeUsers: 2, messages: 3, newUsers: 2 })
    const atMidnight = await getDailyActivity(midnight)
    expect(atMidnight.at(-1)).toMatchObject({ activeUsers: 0, messages: 0, newUsers: 0, threads: 0 })
    expect(atMidnight.at(-2)).toMatchObject({ activeUsers: 1, messages: 1, newUsers: 1 })
  })

  it("keeps overview signup/waitlist counts and lists in the same calendar-day window", async () => {
    await db.insert(users).values([
      { email: "old@metrics.test", date: yesterday },
      { email: "new@metrics.test", date: midnight },
      { email: "future@metrics.test", date: snapshot },
      { email: "bot@metrics.test", date: midnight, bot: true },
    ])
    await db.insert(waitlist).values([
      { email: "old@metrics.test", date: yesterday },
      { email: "new@metrics.test", date: midnight },
      { email: "future@metrics.test", date: snapshot },
    ])
    const recent = await getRecentOverviewActivity("https://admin.example.test", snapshot)
    expect(recent.newUsersLastDay).toBe(1)
    expect(recent.newWaitlistLastDay).toBe(1)
    expect(recent.recentUsers.map((user) => user.email)).toEqual(["new@metrics.test"])
    expect(recent.recentWaitlist.map((entry) => entry.email)).toEqual(["new@metrics.test"])
    const atMidnight = await getRecentOverviewActivity("https://admin.example.test", midnight)
    expect(atMidnight.newUsersLastDay).toBe(0)
    expect(atMidnight.newWaitlistLastDay).toBe(0)
  })
})
