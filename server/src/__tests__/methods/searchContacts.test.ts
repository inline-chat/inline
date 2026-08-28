import { describe, expect, test } from "bun:test"
import { db } from "../../db"
import { users } from "../../db/schema"
import { handler } from "../../methods/searchContacts"
import { InlineError } from "../../types/errors"
import { setupTestLifecycle, testUtils } from "../setup"

describe("searchContacts", () => {
  setupTestLifecycle()

  test("does not remotely search short, email, or phone input", async () => {
    const viewer = await testUtils.createUser("search-private-input-viewer@example.com")

    expect((await handler({ q: "a", limit: 20 }, { currentUserId: viewer.id })).users).toEqual([])
    expect((await handler({ q: "@a", limit: 20 }, { currentUserId: viewer.id })).users).toEqual([])
    expect((await handler({ q: "@@helper", limit: 20 }, { currentUserId: viewer.id })).users).toEqual([])
    expect((await handler({ q: "person@example.com", limit: 20 }, { currentUserId: viewer.id })).users).toEqual([])
    expect((await handler({ q: "+12025550123", limit: 20 }, { currentUserId: viewer.id })).users).toEqual([])
  })

  test("autocompletes owned bots while hiding other bots on partial matches", async () => {
    const viewer = await testUtils.createUser("search-viewer@example.com")

    await db.insert(users).values([
      {
        email: "search-human@example.com",
        firstName: "Helper Human",
        username: "helperhuman",
        bot: false,
      },
      {
        email: "search-bot@example.com",
        firstName: "Helper Bot",
        username: "helperbot",
        bot: true,
        botCreatorId: viewer.id,
      },
      {
        email: "search-other-bot@example.com",
        firstName: "Other Helper Bot",
        username: "otherhelperbot",
        bot: true,
      },
    ])

    const partial = await handler({ q: "helper", limit: 20 }, { currentUserId: viewer.id })
    expect(partial.users.map((user) => user.username)).toContain("helperhuman")
    expect(partial.users.map((user) => user.username)).toContain("helperbot")
    expect(partial.users.map((user) => user.username)).not.toContain("otherhelperbot")

    const limited = await handler({ q: "helper", limit: 1 }, { currentUserId: viewer.id })
    expect(limited.users.map((user) => user.username)).toEqual(["helperbot"])

    const limitedWithAtSign = await handler({ q: "@helper", limit: 1 }, { currentUserId: viewer.id })
    expect(limitedWithAtSign.users.map((user) => user.username)).toEqual(["helperbot"])

    const byName = await handler({ q: "Helper Bot", limit: 20 }, { currentUserId: viewer.id })
    expect(byName.users.map((user) => user.username)).toContain("helperbot")
    expect(byName.users.map((user) => user.username)).not.toContain("otherhelperbot")

    const exact = await handler({ q: "@helperbot", limit: 20 }, { currentUserId: viewer.id })
    expect(exact.users.map((user) => user.username)).toContain("helperbot")
    expect(exact.users.map((user) => user.username)).not.toContain("otherhelperbot")
  })

  test("caps requested limits and rate-limits eligible searches", async () => {
    const viewer = await testUtils.createUser("search-bounds-viewer@example.com")
    await db.insert(users).values(
      Array.from({ length: 25 }, (_, index) => ({
        email: `search-cap-${index}@example.com`,
        firstName: `Cap Person ${index}`,
        username: `capuser${index}`,
        bot: false,
      })),
    )

    expect((await handler({ q: "capuser", limit: 999 }, { currentUserId: viewer.id })).users).toHaveLength(20)
    expect((await handler({ q: "capuser", limit: 0 }, { currentUserId: viewer.id })).users).toHaveLength(1)

    for (let request = 2; request < 60; request += 1) {
      await handler({ q: "no-match", limit: 20 }, { currentUserId: viewer.id })
    }

    try {
      await handler({ q: "no-match", limit: 20 }, { currentUserId: viewer.id })
      throw new Error("expected search rate limit")
    } catch (error) {
      expect(error).toBeInstanceOf(InlineError)
      expect((error as InlineError).type).toBe("FLOOD")
    }
  })
})
