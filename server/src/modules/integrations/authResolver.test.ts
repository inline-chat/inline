import { describe, expect, test } from "bun:test"
import {
  accessTokenFromPayload,
  resolveIntegrationAuthCandidatesWithDeps,
  resolveIntegrationAuthWithDeps,
  spaceOnlyIntegrationAuthPolicy,
  userThenSpaceIntegrationAuthPolicy,
  type IntegrationAuthResolverDeps,
  type IntegrationAuthRow,
} from "./authResolver"

const spaceRow = row({ id: 1, spaceId: 10, userId: 8 })
const userRow = row({ id: 2, spaceId: null, userId: 7 })

describe("integration auth resolver", () => {
  test("prefers the user connection and falls back to the space connection", async () => {
    const preferred = await resolveIntegrationAuthWithDeps(
      { provider: "notion", currentUserId: 7, spaceId: 10 },
      deps({ userIntegration: userRow, spaceIntegration: spaceRow }),
      userThenSpaceIntegrationAuthPolicy,
    )
    expect(preferred).toMatchObject({
      integrationId: 2,
      accessToken: "user-token",
      owner: { type: "user", userId: 7 },
    })

    const fallback = await resolveIntegrationAuthWithDeps(
      { provider: "notion", currentUserId: 7, spaceId: 10 },
      deps({ userIntegration: null, spaceIntegration: spaceRow }),
      userThenSpaceIntegrationAuthPolicy,
    )
    expect(fallback).toMatchObject({
      integrationId: 1,
      accessToken: "space-token",
      owner: { type: "space", spaceId: 10 },
    })
  })

  test("returns personal and space candidates in policy order", async () => {
    const candidates = await resolveIntegrationAuthCandidatesWithDeps(
      { provider: "notion", currentUserId: 7, spaceId: 10 },
      deps({ userIntegration: userRow, spaceIntegration: spaceRow }),
      userThenSpaceIntegrationAuthPolicy,
    )

    expect(candidates.map((candidate) => candidate.integrationId)).toEqual([2, 1])
  })

  test("preserves a space-only policy for existing consumers", async () => {
    const auth = await resolveIntegrationAuthWithDeps(
      { provider: "notion", currentUserId: 7, spaceId: 10 },
      deps({ userIntegration: userRow, spaceIntegration: spaceRow }),
      spaceOnlyIntegrationAuthPolicy,
    )
    expect(auth?.integrationId).toBe(1)
  })

  test("uses only an unscoped user connection outside a space", async () => {
    let spaceLookups = 0
    const auth = await resolveIntegrationAuthWithDeps(
      { provider: "notion", currentUserId: 7, spaceId: null },
      {
        ...deps({ userIntegration: userRow, spaceIntegration: spaceRow }),
        async findSpaceIntegration() {
          spaceLookups += 1
          return spaceRow
        },
      },
      userThenSpaceIntegrationAuthPolicy,
    )
    expect(auth?.integrationId).toBe(2)
    expect(spaceLookups).toBe(0)
  })

  test("falls back when the preferred connection has invalid credentials", async () => {
    const invalidUser = { ...userRow, accessTokenEncrypted: null }
    const auth = await resolveIntegrationAuthWithDeps(
      { provider: "notion", currentUserId: 7, spaceId: 10 },
      deps({ userIntegration: invalidUser, spaceIntegration: spaceRow }),
      userThenSpaceIntegrationAuthPolicy,
    )
    expect(auth?.integrationId).toBe(1)
  })

  test("never accepts another user's personal connection", async () => {
    const otherUsersRow = row({ id: 3, spaceId: null, userId: 99 })
    const auth = await resolveIntegrationAuthWithDeps(
      { provider: "notion", currentUserId: 7, spaceId: 10 },
      deps({ userIntegration: otherUsersRow, spaceIntegration: spaceRow }),
      userThenSpaceIntegrationAuthPolicy,
    )
    expect(auth?.integrationId).toBe(1)
    expect(auth?.owner).toEqual({ type: "space", spaceId: 10 })
  })

  test("parses direct and arctic token payloads", () => {
    expect(accessTokenFromPayload({ access_token: "direct" })).toBe("direct")
    expect(accessTokenFromPayload({ data: { access_token: "nested" } })).toBe("nested")
    expect(accessTokenFromPayload({ data: {} })).toBeNull()
  })
})

function deps(input: {
  userIntegration: IntegrationAuthRow | null
  spaceIntegration: IntegrationAuthRow | null
}): IntegrationAuthResolverDeps {
  return {
    async findUserIntegration() {
      return input.userIntegration
    },
    async findSpaceIntegration() {
      return input.spaceIntegration
    },
    decryptToken(value) {
      return {
        data: {
          access_token: value.id === 1 ? "space-token" : "user-token",
        },
      }
    },
  }
}

function row(input: {
  id: number
  userId: number | null
  spaceId: number | null
}): IntegrationAuthRow {
  return {
    ...input,
    provider: "notion",
    date: new Date("2026-01-01T00:00:00Z"),
    accessTokenEncrypted: Buffer.from("encrypted"),
    accessTokenIv: Buffer.from("iv"),
    accessTokenTag: Buffer.from("tag"),
  }
}
