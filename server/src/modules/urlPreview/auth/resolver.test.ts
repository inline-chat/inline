import { describe, expect, test } from "bun:test"
import {
  accessTokenFromPayload,
  resolvePreviewAuthCandidatesWithDeps,
  resolvePreviewAuthWithDeps,
} from "./resolver"
import type { PreviewAuthResolverDeps, PreviewIntegrationRow } from "./types"

const spaceRow = row({ id: 1, spaceId: 10, userId: 7, token: "space-token" })
const userRow = row({ id: 2, spaceId: null, userId: 7, token: "user-token" })

describe("url preview auth resolver", () => {
  test("new-thread previews resolve only the requesting user's connection without a chat or space lookup", async () => {
    const personalOnlyDeps: PreviewAuthResolverDeps = {
      ...deps({ chatSpaceId: 10, spaceIntegration: spaceRow, userIntegration: userRow }),
      async getChatSpaceId() { throw new Error("No chat should be resolved") },
      async findSpaceIntegration() { throw new Error("No space connection should be resolved") },
      async findUserIntegration(provider, userId) {
        expect(provider).toBe("notion")
        expect(userId).toBe(7)
        return userRow
      },
    }
    const input = { provider: "notion", currentUserId: 7 }
    const candidates = await resolvePreviewAuthCandidatesWithDeps(input, personalOnlyDeps)
    expect(candidates).toHaveLength(1)
    expect(candidates[0]).toMatchObject({ integrationId: 2, owner: { type: "user", userId: 7 } })
    expect(await resolvePreviewAuthWithDeps(input, personalOnlyDeps)).toEqual(candidates[0] ?? null)
  })

  test("new-thread previews never fall back to a space connection when personal Notion is disconnected", async () => {
    const auth = await resolvePreviewAuthCandidatesWithDeps(
      { provider: "notion", currentUserId: 7 },
      {
        ...deps({ chatSpaceId: 10, spaceIntegration: spaceRow, userIntegration: null }),
        async getChatSpaceId() { throw new Error("No chat should be resolved") },
        async findSpaceIntegration() { throw new Error("No space connection should be resolved") },
      },
    )
    expect(auth).toEqual([])
  })

  test("prefers the requesting user's integration for space-chat previews", async () => {
    const auth = await resolvePreviewAuthWithDeps(
      { provider: "notion", currentUserId: 7, chatId: 100 },
      deps({ chatSpaceId: 10, spaceIntegration: spaceRow, userIntegration: userRow }),
    )

    expect(auth).toMatchObject({
      provider: "notion",
      accessToken: "user-token",
      integrationId: 2,
      owner: { type: "user", userId: 7 },
    })
  })

  test("uses a personal integration in a space chat when no space connection exists", async () => {
    const auth = await resolvePreviewAuthWithDeps(
      { provider: "notion", currentUserId: 7, chatId: 100 },
      deps({ chatSpaceId: 10, spaceIntegration: null, userIntegration: userRow }),
    )

    expect(auth).toMatchObject({
      accessToken: "user-token",
      owner: { type: "user", userId: 7 },
    })
  })

  test("returns personal and space credentials for provider fallback", async () => {
    const auth = await resolvePreviewAuthCandidatesWithDeps(
      { provider: "notion", currentUserId: 7, chatId: 100 },
      deps({ chatSpaceId: 10, spaceIntegration: spaceRow, userIntegration: userRow }),
    )

    expect(auth.map((candidate) => candidate.integrationId)).toEqual([2, 1])
  })

  test("can explicitly use only the space integration", async () => {
    const auth = await resolvePreviewAuthWithDeps(
      { provider: "notion", currentUserId: 7, chatId: 100 },
      deps({ chatSpaceId: 10, spaceIntegration: spaceRow, userIntegration: userRow }),
      { scopeOrderInSpace: ["space"] },
    )

    expect(auth).toMatchObject({
      accessToken: "space-token",
      owner: { type: "space", spaceId: 10 },
    })
  })

  test("uses user integration outside space chats", async () => {
    const auth = await resolvePreviewAuthWithDeps(
      { provider: "notion", currentUserId: 7, chatId: 100 },
      deps({ chatSpaceId: null, spaceIntegration: null, userIntegration: userRow }),
    )

    expect(auth).toMatchObject({
      accessToken: "user-token",
      owner: { type: "user", userId: 7 },
    })
  })

  test("parses direct and arctic-style token payloads", () => {
    expect(accessTokenFromPayload({ access_token: "direct" })).toBe("direct")
    expect(accessTokenFromPayload({ data: { access_token: "nested" } })).toBe("nested")
    expect(accessTokenFromPayload({ data: {} })).toBeNull()
  })

  test("returns null when token payload cannot be decrypted or parsed", async () => {
    const auth = await resolvePreviewAuthWithDeps(
      { provider: "notion", currentUserId: 7, chatId: 100 },
      {
        ...deps({ chatSpaceId: null, spaceIntegration: null, userIntegration: userRow }),
        decryptToken() {
          throw new Error("bad token payload")
        },
      },
    )

    expect(auth).toBeNull()
  })
})

function deps(input: {
  chatSpaceId: number | null
  spaceIntegration: PreviewIntegrationRow | null
  userIntegration: PreviewIntegrationRow | null
}): PreviewAuthResolverDeps {
  return {
    async getChatSpaceId() {
      return input.chatSpaceId
    },
    async findSpaceIntegration() {
      return input.spaceIntegration
    },
    async findUserIntegration() {
      return input.userIntegration
    },
    decryptToken(row) {
      return { data: { access_token: row.id === 1 ? "space-token" : "user-token" } }
    },
  }
}

function row(input: { id: number; spaceId: number | null; userId: number | null; token: string }): PreviewIntegrationRow {
  return {
    id: input.id,
    provider: "notion",
    date: new Date("2026-01-01T00:00:00Z"),
    userId: input.userId,
    spaceId: input.spaceId,
    accessTokenEncrypted: Buffer.from(input.token),
    accessTokenIv: Buffer.from("iv"),
    accessTokenTag: Buffer.from("tag"),
  }
}
