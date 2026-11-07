import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { chats, dialogs, users } from "@in/server/db/schema"
import { getUsersHandler } from "@in/server/realtime/handlers/users.get"
import type { HandlerContext } from "@in/server/realtime/types"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"

function context(userId: number): HandlerContext {
  return { userId, sessionId: 1, connectionId: "get-users-test", sendRaw: () => {}, sendRpcReply: () => {} }
}

describe("getUsersHandler", () => {
  setupTestLifecycle()

  test("hydrates an unrelated person's fresh public identity without creating a chat or dialog", async () => {
    const viewer = await testUtils.createUser("lookup-viewer@example.com")
    const person = await testUtils.createUser("lookup-person@example.com")
    await db.update(users).set({
      firstName: "Renamed", username: "freshusername", phoneNumber: "+12025550101", bio: "Private bio",
      timeZone: "Europe/Paris", online: true, appearInGlobalSearch: false,
    }).where(eq(users.id, person.id))
    const result = await getUsersHandler({ userIds: [BigInt(person.id)] }, context(viewer.id))
    expect(result.users).toHaveLength(1)
    const profile = result.users[0]
    expect(profile?.firstName).toBe("Renamed")
    expect(profile?.username).toBe("freshusername")
    expect(profile?.min).toBe(true)
    for (const field of ["email", "phoneNumber", "bio", "status", "timeZone", "pendingSetup"] as const) {
      expect(profile?.[field]).toBeUndefined()
    }
    expect(await db.select().from(chats)).toEqual([])
    expect(await db.select().from(dialogs)).toEqual([])
  })

  test("omits missing, deleted and pending identities; keeps legacy users and exact bot IDs", async () => {
    const viewer = await testUtils.createUser("lookup-state-viewer@example.com")
    const [deleted, pending, bot, legacy] = await db.insert(users).values([
      { email: "lookup-deleted@example.com", deleted: true },
      { email: "lookup-pending@example.com", pendingSetup: true },
      { email: "lookup-bot@example.com", bot: true, firstName: "Helper" },
      { email: "lookup-legacy@example.com", pendingSetup: null, firstName: "Legacy" },
    ]).returning()
    if (!deleted || !pending || !bot || !legacy) throw new Error("Missing test users")
    const result = await getUsersHandler({ userIds: [BigInt(deleted.id), BigInt(pending.id), 9007199254740991n, BigInt(bot.id), BigInt(legacy.id)] }, context(viewer.id))
    expect(result.users.map((user) => user.id)).toEqual([BigInt(bot.id), BigInt(legacy.id)])
    expect(result.users[0]?.bot).toBe(true)
  })

  test("shows a bot's online status only to its owner and people with a DM with it", async () => {
    const owner = await testUtils.createUser("lookup-bot-owner@example.com")
    const friend = await testUtils.createUser("lookup-bot-friend@example.com")
    const stranger = await testUtils.createUser("lookup-bot-stranger@example.com")
    const [bot] = await db.insert(users).values({
      email: "lookup-online-bot@example.com", bot: true, botCreatorId: owner.id, online: true, firstName: "Agent",
    }).returning()
    if (!bot) throw new Error("Missing bot")
    const [chat] = await db.insert(chats).values({
      type: "private", minUserId: Math.min(friend.id, bot.id), maxUserId: Math.max(friend.id, bot.id),
    }).returning()
    if (!chat) throw new Error("Missing chat")
    await db.insert(dialogs).values({ chatId: chat.id, userId: friend.id, peerUserId: bot.id })

    const status = async (viewerId: number) =>
      (await getUsersHandler({ userIds: [BigInt(bot.id), BigInt(stranger.id)] }, context(viewerId))).users
        .map((user) => user.status?.online)
    expect(await status(owner.id)).toEqual([1, undefined])
    expect(await status(friend.id)).toEqual([1, undefined])
    // A known ID alone never reveals when someone's agent is running.
    expect(await status(stranger.id)).toEqual([undefined, undefined])
  })

  test("deduplicates and preserves requested order", async () => {
    const first = await testUtils.createUser("lookup-first@example.com")
    const second = await testUtils.createUser("lookup-second@example.com")
    const result = await getUsersHandler({ userIds: [BigInt(second.id), BigInt(first.id), BigInt(second.id)] }, context(first.id))
    expect(result.users.map((user) => user.id)).toEqual([BigInt(second.id), BigInt(first.id)])
    expect((await getUsersHandler({ userIds: [] }, context(first.id))).users).toEqual([])
  })

  test("rejects invalid, imprecise and oversized input before lookup", async () => {
    const viewer = await testUtils.createUser("lookup-invalid@example.com")
    for (const userIds of [[0n], [-1n], [9007199254740992n], Array(51).fill(BigInt(viewer.id))]) {
      await expect(getUsersHandler({ userIds }, context(viewer.id))).rejects.toMatchObject({ codeName: "BAD_REQUEST" })
    }
  })

  test("limits repeated profile requests per caller", async () => {
    const viewer = await testUtils.createUser("lookup-rate@example.com")
    for (let count = 0; count < 60; count++) {
      await getUsersHandler({ userIds: [BigInt(viewer.id)] }, context(viewer.id))
    }
    await expect(getUsersHandler({ userIds: [BigInt(viewer.id)] }, context(viewer.id))).rejects.toMatchObject({ codeName: "RATE_LIMIT" })
  })
})
