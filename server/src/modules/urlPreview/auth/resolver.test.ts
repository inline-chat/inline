import { describe, expect, test } from "bun:test"
import { accessTokenFromPayload, resolvePreviewAuthWithDeps } from "./resolver"
import type { PreviewAuthResolverDeps, PreviewIntegrationRow } from "./types"

const spaceRow = row({ id: 1, spaceId: 10, userId: 7, token: "space-token" })
const userRow = row({ id: 2, spaceId: null, userId: 7, token: "user-token" })

describe("url preview auth resolver", () => {
  test("prefers space integration for space chats", async () => {
    const auth = await resolvePreviewAuthWithDeps(
      { provider: "notion", currentUserId: 7, chatId: 100 },
      deps({ chatSpaceId: 10, spaceIntegration: spaceRow, userIntegration: userRow }),
    )

    expect(auth).toMatchObject({
      provider: "notion",
      accessToken: "space-token",
      integrationId: 1,
      owner: { type: "space", spaceId: 10 },
    })
  })

  test("does not fall back to user integration in space chats by default", async () => {
    const auth = await resolvePreviewAuthWithDeps(
      { provider: "notion", currentUserId: 7, chatId: 100 },
      deps({ chatSpaceId: 10, spaceIntegration: null, userIntegration: userRow }),
    )

    expect(auth).toBeNull()
  })

  test("can fall back to user integration in space chats through policy", async () => {
    const auth = await resolvePreviewAuthWithDeps(
      { provider: "notion", currentUserId: 7, chatId: 100 },
      deps({ chatSpaceId: 10, spaceIntegration: null, userIntegration: userRow }),
      { allowUserTokenFallbackInSpaceChats: true },
    )

    expect(auth).toMatchObject({
      accessToken: "user-token",
      owner: { type: "user", userId: 7 },
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
    userId: input.userId,
    spaceId: input.spaceId,
    accessTokenEncrypted: Buffer.from(input.token),
    accessTokenIv: Buffer.from("iv"),
    accessTokenTag: Buffer.from("tag"),
  }
}
