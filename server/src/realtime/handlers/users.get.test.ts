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
