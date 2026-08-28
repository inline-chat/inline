import { describe, expect, test } from "bun:test"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { searchUsersHandler } from "@in/server/realtime/handlers/users.search"
import type { HandlerContext } from "@in/server/realtime/types"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"

function context(userId: number): HandlerContext {
  return {
    userId,
    sessionId: 1,
    connectionId: "search-users-test",
    sendRaw: () => {},
    sendRpcReply: () => {},
  }
}

describe("searchUsersHandler", () => {
  setupTestLifecycle()

  test("returns bounded public username matches and excludes the caller", async () => {
    const viewer = await testUtils.createUser("rpc-search-viewer@example.com")
    await db.insert(users).values([
      { email: "rpc-search-one@example.com", username: "privacyone", firstName: "One", phoneNumber: "+12025550101" },
      { email: "rpc-search-two@example.com", username: "privacytwo", firstName: "Two", phoneNumber: "+12025550102" },
    ])

    const result = await searchUsersHandler({ query: "privacy", limit: 1 }, context(viewer.id))
    expect(result.users).toHaveLength(1)
    expect(result.users[0]?.min).toBe(true)
    expect(result.users[0]?.email).toBeUndefined()
    expect(result.users[0]?.phoneNumber).toBeUndefined()
    expect(result.users[0]?.pendingSetup).toBeUndefined()

    const self = await searchUsersHandler({ query: "rpc-search-viewer", limit: 20 }, context(viewer.id))
    expect(self.users.map((user) => user.id)).not.toContain(BigInt(viewer.id))
  })

  test("does not remotely search email or phone input", async () => {
    const viewer = await testUtils.createUser("rpc-search-private-input@example.com")
    expect((await searchUsersHandler({ query: "person@example.com", limit: 20 }, context(viewer.id))).users).toEqual([])
    expect((await searchUsersHandler({ query: "+12025550123", limit: 20 }, context(viewer.id))).users).toEqual([])
  })

  test("does not expose pending invited identities", async () => {
    const viewer = await testUtils.createUser("rpc-search-pending-viewer@example.com")
    await db.insert(users).values({
      email: "rpc-search-pending@example.com",
      username: "pending-hidden-user",
      pendingSetup: true,
    })

    const result = await searchUsersHandler({ query: "pending-hidden", limit: 20 }, context(viewer.id))
    expect(result.users).toEqual([])
  })

  test("does not return users who disabled global search visibility", async () => {
    const viewer = await testUtils.createUser("rpc-search-private-viewer@example.com")
    await db.insert(users).values({
      email: "rpc-search-private-user@example.com",
      username: "globally-hidden-user",
      pendingSetup: false,
      appearInGlobalSearch: false,
    })

    const result = await searchUsersHandler({ query: "globally-hidden", limit: 20 }, context(viewer.id))
    expect(result.users).toEqual([])
  })

  test("autocompletes owned bots while keeping other bots exact-only", async () => {
    const viewer = await testUtils.createUser("rpc-search-bot-viewer@example.com")
    await db.insert(users).values([
      {
        email: "rpc-search-owned-bot@example.com",
        firstName: "Release Helper",
        username: "releasehelperbot",
        bot: true,
        botCreatorId: viewer.id,
      },
      {
        email: "rpc-search-other-bot@example.com",
        firstName: "Other Release Helper",
        username: "otherreleasehelperbot",
        bot: true,
      },
      {
        email: "rpc-search-release-human@example.com",
        firstName: "Release Human",
        username: "releasehuman",
      },
    ])

    const byUsername = await searchUsersHandler({ query: "releasehelp", limit: 20 }, context(viewer.id))
    expect(byUsername.users.map((user) => user.username)).toContain("releasehelperbot")
    expect(byUsername.users.map((user) => user.username)).not.toContain("otherreleasehelperbot")

    const byName = await searchUsersHandler({ query: "Release Helper", limit: 20 }, context(viewer.id))
    expect(byName.users.map((user) => user.username)).toContain("releasehelperbot")
    expect(byName.users.map((user) => user.username)).not.toContain("otherreleasehelperbot")

    const limited = await searchUsersHandler({ query: "@releasehelp", limit: 1 }, context(viewer.id))
    expect(limited.users.map((user) => user.username)).toEqual(["releasehelperbot"])

    const exactOther = await searchUsersHandler({ query: "@otherreleasehelperbot", limit: 20 }, context(viewer.id))
    expect(exactOther.users.map((user) => user.username)).toContain("otherreleasehelperbot")
  })

  test("treats PostgreSQL wildcard characters as literal username text", async () => {
    const viewer = await testUtils.createUser("rpc-search-literal-viewer@example.com")
    await db.insert(users).values([
      { email: "rpc-search-underscore@example.com", username: "literal_under" },
      { email: "rpc-search-letter@example.com", username: "literalXunder" },
      { email: "rpc-search-percent@example.com", username: "literal%percent" },
    ])

    const wildcardOnly = await searchUsersHandler({ query: "__", limit: 20 }, context(viewer.id))
    expect(wildcardOnly.users).toEqual([])

    const underscore = await searchUsersHandler({ query: "literal_", limit: 20 }, context(viewer.id))
    expect(underscore.users.map((user) => user.username)).toEqual(["literal_under"])

    const percent = await searchUsersHandler({ query: "literal%", limit: 20 }, context(viewer.id))
    expect(percent.users.map((user) => user.username)).toEqual(["literal%percent"])
  })
})
