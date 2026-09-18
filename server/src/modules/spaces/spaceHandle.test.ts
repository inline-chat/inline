import { describe, expect, test } from "bun:test"
import { db } from "@in/server/db"
import { reservedUsernames, spaces, users } from "@in/server/db/schema"
import { createBot } from "@in/server/functions/createBot"
import { handler as createSpace } from "@in/server/methods/createSpace"
import { handler as updateProfile } from "@in/server/methods/updateProfile"
import { checkUsernameAvailable } from "@in/server/methods/checkUsername"
import { changeUsernameHandler, checkUsernameHandler } from "@in/server/realtime/handlers/user.account"
import { UsernameAvailability } from "@inline-chat/protocol/core"
import { eq } from "drizzle-orm"
import { defaultTestContext, setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"

const legacyContext = (userId: number) => ({ currentUserId: userId, currentSessionId: 1, ip: undefined })
const functionContext = (userId: number) => ({
  currentUserId: userId,
  currentSessionId: defaultTestContext.sessionId,
})
const realtimeContext = (userId: number) => ({
  userId,
  sessionId: defaultTestContext.sessionId,
  connectionId: "public-handle-test",
  sendRaw: () => {},
  sendRpcReply: () => {},
})

describe("public handle namespace", () => {
  setupTestLifecycle()

  test("Realtime preserves casing, sanitizes before claiming, and never clears invalid input", async () => {
    const owner = await testUtils.createUser("sanitize-owner@example.com")
    const other = await testUtils.createUser("sanitize-other@example.com")
    const candidate = "@@Example.Studio@example.com"
    const checked = await checkUsernameHandler({ username: candidate }, realtimeContext(owner.id))
    expect(checked.username).toBe("Example_Studio")
    expect(checked.availability).toBe(UsernameAvailability.USERNAME_AVAILABLE)
    const saved = await changeUsernameHandler({ username: candidate }, realtimeContext(owner.id))
    expect(saved.user?.username).toBe("Example_Studio")
    expect((await checkUsernameHandler({ username: "example-studio" }, realtimeContext(other.id))).availability)
      .toBe(UsernameAvailability.USERNAME_TAKEN)
    await expect(changeUsernameHandler({ username: "example studio" }, realtimeContext(other.id))).rejects.toThrow()
    for (const username of ["@@@", "💥", "a".repeat(65)]) {
      expect((await checkUsernameHandler({ username }, realtimeContext(owner.id))).availability)
        .toBe(UsernameAvailability.USERNAME_INVALID)
      await expect(changeUsernameHandler({ username }, realtimeContext(owner.id))).rejects.toThrow()
    }
    expect((await db.select().from(users).where(eq(users.id, owner.id)))[0]?.username).toBe("Example_Studio")
    const changedCase = await changeUsernameHandler({ username: "EXAMPLE_Studio" }, realtimeContext(owner.id))
    expect(changedCase.user?.username).toBe("EXAMPLE_Studio")
    await changeUsernameHandler({ username: "" }, realtimeContext(owner.id))
    expect((await db.select().from(users).where(eq(users.id, owner.id)))[0]?.username).toBeNull()
  })

  test("checks sanitized usernames against spaces and reservations", async () => {
    const user = await testUtils.createUser("sanitize-namespace@example.com")
    await createSpace({ name: "Space", handle: "Shared_Name" }, legacyContext(user.id))
    await db.insert(reservedUsernames).values({ username: "future_name" })
    expect(await checkUsernameAvailable("Shared Name", {})).toBe(false)
    expect(await checkUsernameAvailable("Future-Name", {})).toBe(false)
    expect((await checkUsernameHandler({ username: "Future.Name" }, realtimeContext(user.id))).availability)
      .toBe(UsernameAvailability.USERNAME_RESERVED)
    await expect(changeUsernameHandler({ username: "Shared.Name" }, realtimeContext(user.id))).rejects.toThrow()
  })

  test("prevents a space from claiming a user username", async () => {
    const user = await testUtils.createUser("namespace-user@example.com")
    await updateProfile({ username: "sharedname" }, legacyContext(user.id))

    await expect(
      createSpace({ name: "Conflicting Space", handle: "SharedName" }, legacyContext(user.id)),
    ).rejects.toMatchObject({ type: "USERNAME_TAKEN" })
  })

  test("reports a space handle as taken to legacy and Realtime username paths", async () => {
    const owner = await testUtils.createUser("namespace-owner@example.com")
    const user = await testUtils.createUser("namespace-claimant@example.com")
    await createSpace({ name: "Shared Space", handle: "sharedspace" }, legacyContext(owner.id))

    expect(await checkUsernameAvailable("@SharedSpace", { userId: user.id })).toBe(false)
    expect((await checkUsernameHandler({ username: "sharedspace" }, realtimeContext(user.id))).availability).toBe(
      UsernameAvailability.USERNAME_TAKEN,
    )
    await expect(changeUsernameHandler({ username: "sharedspace" }, realtimeContext(user.id))).rejects.toThrow()
    await expect(updateProfile({ username: "sharedspace" }, legacyContext(user.id))).rejects.toMatchObject({
      type: "USERNAME_TAKEN",
    })
  })

  test("prevents bot usernames from claiming a space handle", async () => {
    const owner = await testUtils.createUser("namespace-bot-owner@example.com")
    await createSpace({ name: "Bot Space", handle: "sharedbot" }, legacyContext(owner.id))

    await expect(
      createBot({ name: "Shared Bot", username: "SharedBot" }, functionContext(owner.id)),
    ).rejects.toThrow()
  })

  test("blocks Admin-reserved terms across the public handle namespace", async () => {
    const user = await testUtils.createUser("namespace-reserved-user@example.com")
    await db.insert(reservedUsernames).values({ username: "futurebot" })

    expect(await checkUsernameAvailable("@FutureBot", { userId: user.id })).toBe(false)
    expect((await checkUsernameHandler({ username: "futurebot" }, realtimeContext(user.id))).availability).toBe(
      UsernameAvailability.USERNAME_RESERVED,
    )
    await expect(updateProfile({ username: "futurebot" }, legacyContext(user.id))).rejects.toMatchObject({
      type: "USERNAME_TAKEN",
    })
    await expect(
      createSpace({ name: "Reserved Space", handle: "futurebot" }, legacyContext(user.id)),
    ).rejects.toMatchObject({ type: "USERNAME_TAKEN" })
    await expect(
      createBot({ name: "Reserved Bot", username: "FutureBot" }, functionContext(user.id)),
    ).rejects.toThrow()
  })

  test("keeps an existing owner current when its term is reserved later", async () => {
    const user = await testUtils.createUser("namespace-reserved-owner@example.com")
    await updateProfile({ username: "grandfathered" }, legacyContext(user.id))
    await db.insert(reservedUsernames).values({ username: "grandfathered" })

    expect(await checkUsernameAvailable("grandfathered", { userId: user.id })).toBe(true)
    expect((await checkUsernameHandler({ username: "GRANDFATHERED" }, realtimeContext(user.id))).availability).toBe(
      UsernameAvailability.USERNAME_CURRENT,
    )
  })

  test("serializes concurrent user and space claims to one winner", async () => {
    const spaceOwner = await testUtils.createUser("namespace-race-owner@example.com")
    const user = await testUtils.createUser("namespace-race-user@example.com")

    const claims = await Promise.allSettled([
      createSpace({ name: "Race Space", handle: "racehandle" }, legacyContext(spaceOwner.id)),
      updateProfile({ username: "RACEHANDLE" }, legacyContext(user.id)),
    ])
    expect(claims.filter((claim) => claim.status === "fulfilled")).toHaveLength(1)
    expect(claims.filter((claim) => claim.status === "rejected")).toHaveLength(1)

    const [storedUser] = await db.select({ username: users.username }).from(users).where(eq(users.id, user.id))
    const storedSpaces = await db.select({ id: spaces.id }).from(spaces).where(eq(spaces.handle, "racehandle"))
    expect(Number(storedUser?.username?.toLowerCase() === "racehandle") + Number(storedSpaces.length === 1)).toBe(1)
  })
})
