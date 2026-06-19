import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "../../db"
import { users } from "../../db/schema"
import { handler } from "../../methods/updateProfile"
import type { HandlerContext } from "../../controllers/helpers"
import { setupTestLifecycle, testUtils } from "../setup"
import { InlineError } from "../../types/errors"

describe("updateProfile", () => {
  setupTestLifecycle()

  const makeContext = (userId: number): HandlerContext => ({
    currentUserId: userId,
    currentSessionId: 0,
    ip: "127.0.0.1",
  })

  test("strips leading @ from username", async () => {
    const user = await testUtils.createUser("profile@example.com")

    const result = await handler({ username: "@profilehandle" }, makeContext(user.id))

    expect(result.user.username).toBe("profilehandle")

    const [storedUser] = await db.select().from(users).where(eq(users.id, user.id))
    expect(storedUser?.username).toBe("profilehandle")
  })

  test("ignores undefined optional name fields on username updates", async () => {
    const user = await testUtils.createUser("optional-name-profile@example.com")

    const result = await handler(
      { firstName: undefined, lastName: undefined, username: "optionalhandle" },
      makeContext(user.id),
    )

    expect(result.user.username).toBe("optionalhandle")

    const [storedUser] = await db.select().from(users).where(eq(users.id, user.id))
    expect(storedUser?.username).toBe("optionalhandle")
  })

  test("surfaces taken username errors", async () => {
    const existing = await testUtils.createUser("existing-profile@example.com")
    const user = await testUtils.createUser("new-profile@example.com")
    await db.update(users).set({ username: "taken" }).where(eq(users.id, existing.id))

    await expect(handler({ username: "taken" }, makeContext(user.id))).rejects.toMatchObject({
      type: InlineError.ApiError.USERNAME_TAKEN[0],
      code: InlineError.ApiError.USERNAME_TAKEN[1],
      description: InlineError.ApiError.USERNAME_TAKEN[2],
    })
  })

  test("rejects reserved usernames", async () => {
    const user = await testUtils.createUser("reserved-profile@example.com")

    await expect(handler({ username: "@InlineBot" }, makeContext(user.id))).rejects.toMatchObject({
      type: InlineError.ApiError.USERNAME_TAKEN[0],
      code: InlineError.ApiError.USERNAME_TAKEN[1],
      description: InlineError.ApiError.USERNAME_TAKEN[2],
    })
  })

  test("surfaces invalid username errors", async () => {
    const user = await testUtils.createUser("invalid-profile@example.com")

    await expect(handler({ username: "a" }, makeContext(user.id))).rejects.toMatchObject({
      type: InlineError.ApiError.USERNAME_INVALID[0],
      code: InlineError.ApiError.USERNAME_INVALID[1],
      description: InlineError.ApiError.USERNAME_INVALID[2],
    })
  })

  test("trims names and clears blank last name", async () => {
    const user = await testUtils.createUser("name-profile@example.com")
    await db.update(users).set({ firstName: "Old", lastName: "Name" }).where(eq(users.id, user.id))

    const result = await handler({ firstName: " Ada ", lastName: "   " }, makeContext(user.id))

    expect(result.user.firstName).toBe("Ada")

    const [storedUser] = await db.select().from(users).where(eq(users.id, user.id))
    expect(storedUser?.firstName).toBe("Ada")
    expect(storedUser?.lastName).toBeNull()
  })

  test("trims and clears bio", async () => {
    const user = await testUtils.createUser("bio-profile@example.com")
    await db.update(users).set({ bio: "Old bio" }).where(eq(users.id, user.id))

    const result = await handler({ bio: " Building Inline " }, makeContext(user.id))

    expect(result.user.bio).toBe("Building Inline")

    const [storedUser] = await db.select().from(users).where(eq(users.id, user.id))
    expect(storedUser?.bio).toBe("Building Inline")

    const clearedResult = await handler({ bio: "   " }, makeContext(user.id))
    expect(clearedResult.user.bio).toBeNull()

    const [clearedUser] = await db.select().from(users).where(eq(users.id, user.id))
    expect(clearedUser?.bio).toBeNull()
  })

  test("ignores blank optional username fields on name updates", async () => {
    const user = await testUtils.createUser("blank-username-profile@example.com")
    await db.update(users).set({ username: "existinghandle" }).where(eq(users.id, user.id))

    const result = await handler({ firstName: "Mo", username: "" }, makeContext(user.id))

    expect(result.user.firstName).toBe("Mo")
    expect(result.user.username).toBe("existinghandle")

    const [storedUser] = await db.select().from(users).where(eq(users.id, user.id))
    expect(storedUser?.firstName).toBe("Mo")
    expect(storedUser?.username).toBe("existinghandle")
  })

  test("persists one-character names", async () => {
    const user = await testUtils.createUser("short-name-profile@example.com")
    const firstName = "M"
    const lastName = "Q"

    const result = await handler({ firstName, lastName }, makeContext(user.id))

    expect(result.user.firstName).toBe(firstName)
    expect(result.user.lastName).toBe(lastName)

    const [storedUser] = await db.select().from(users).where(eq(users.id, user.id))
    expect(storedUser?.firstName).toBe(firstName)
    expect(storedUser?.lastName).toBe(lastName)
  })

  test("persists valid hyphenated timezones", async () => {
    const user = await testUtils.createUser("valid-timezone-profile@example.com")

    const result = await handler({ timeZone: "America/Port-au-Prince" }, makeContext(user.id))

    expect(result.user.timeZone).toBe("America/Port-au-Prince")

    const [storedUser] = await db.select().from(users).where(eq(users.id, user.id))
    expect(storedUser?.timeZone).toBe("America/Port-au-Prince")
  })

  test("surfaces invalid timezone errors", async () => {
    const user = await testUtils.createUser("invalid-timezone-profile@example.com")

    await expect(handler({ timeZone: "America/UPPERCASE" }, makeContext(user.id))).rejects.toMatchObject({
      type: InlineError.ApiError.TIMEZONE_INVALID[0],
      code: InlineError.ApiError.TIMEZONE_INVALID[1],
      description: InlineError.ApiError.TIMEZONE_INVALID[2],
    })
  })
})
