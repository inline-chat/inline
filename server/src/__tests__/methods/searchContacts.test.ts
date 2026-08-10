import { describe, expect, test } from "bun:test"
import { db } from "../../db"
import { users } from "../../db/schema"
import { handler } from "../../methods/searchContacts"
import { setupTestLifecycle, testUtils } from "../setup"

describe("searchContacts", () => {
  setupTestLifecycle()

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

    const byName = await handler({ q: "Helper Bot", limit: 20 }, { currentUserId: viewer.id })
    expect(byName.users.map((user) => user.username)).toContain("helperbot")
    expect(byName.users.map((user) => user.username)).not.toContain("otherhelperbot")

    const exact = await handler({ q: "@helperbot", limit: 20 }, { currentUserId: viewer.id })
    expect(exact.users.map((user) => user.username)).toContain("helperbot")
    expect(exact.users.map((user) => user.username)).not.toContain("otherhelperbot")
  })
})
