import { describe, test, expect, beforeEach, afterEach } from "bun:test"
import { setupTestLifecycle, testUtils } from "../setup"
import { handler } from "../../methods/disconnectIntegration"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { and, eq } from "drizzle-orm"
import type { HandlerContext } from "../../controllers/helpers"
import { encryptLinearTokens } from "../../libs/helpers"

describe("disconnectIntegration", () => {
  setupTestLifecycle()

  const makeContext = (userId: number): HandlerContext => ({
    currentUserId: userId,
    currentSessionId: 0,
    ip: "127.0.0.1",
  })

  let originalFetch: typeof fetch
  const fetchCalls: Array<{ url: string; init?: RequestInit }> = []

  beforeEach(() => {
    fetchCalls.length = 0
    originalFetch = globalThis.fetch
  })

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  test("revokes Linear token before deleting integration row", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Linear Space", ["linear-admin@example.com"])
    const user = users[0]
    if (!user) throw new Error("Failed to create user")

    await db
      .update(schema.members)
      .set({ role: "admin" })
      .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, user.id)))

    const tokens = { data: { access_token: "access-123", refresh_token: "refresh-456" } } as any
    const encrypted = encryptLinearTokens(tokens)

    await db.insert(schema.integrations).values({
      userId: user.id,
      spaceId: space.id,
      provider: "linear",
      accessTokenEncrypted: encrypted.encrypted,
      accessTokenIv: encrypted.iv,
      accessTokenTag: encrypted.authTag,
    })

    globalThis.fetch = (async (input: any, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input?.toString?.() ?? ""
      fetchCalls.push({ url, init })

      if (url === "https://api.linear.app/oauth/revoke") {
        return new Response("", { status: 200 })
      }

      return new Response("unexpected fetch", { status: 500 })
    }) as any

    await handler({ spaceId: space.id, provider: "linear" }, makeContext(user.id))

    expect(fetchCalls.some((c) => c.url === "https://api.linear.app/oauth/revoke")).toBe(true)

    const revokeCall = fetchCalls.find((c) => c.url === "https://api.linear.app/oauth/revoke")
    const body = revokeCall?.init?.body?.toString?.() ?? ""
    expect(body.includes("refresh_token=refresh-456")).toBe(true)

    const remaining = await db
      .select()
      .from(schema.integrations)
      .where(and(eq(schema.integrations.spaceId, space.id), eq(schema.integrations.provider, "linear")))
    expect(remaining.length).toBe(0)
  })

  test("fails disconnect if Linear revoke fails (keeps integration row)", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Linear Space 2", ["linear-admin2@example.com"])
    const user = users[0]
    if (!user) throw new Error("Failed to create user")

    await db
      .update(schema.members)
      .set({ role: "admin" })
      .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, user.id)))

    const tokens = { data: { access_token: "access-x", refresh_token: "refresh-y" } } as any
    const encrypted = encryptLinearTokens(tokens)

    await db.insert(schema.integrations).values({
      userId: user.id,
      spaceId: space.id,
      provider: "linear",
      accessTokenEncrypted: encrypted.encrypted,
      accessTokenIv: encrypted.iv,
      accessTokenTag: encrypted.authTag,
    })

    globalThis.fetch = (async (input: any) => {
      const url = typeof input === "string" ? input : input?.toString?.() ?? ""
      if (url === "https://api.linear.app/oauth/revoke") {
        return new Response("", { status: 401 })
      }
      return new Response("unexpected fetch", { status: 500 })
    }) as any

    await expect(handler({ spaceId: space.id, provider: "linear" }, makeContext(user.id))).rejects.toBeDefined()

    const remaining = await db
      .select()
      .from(schema.integrations)
      .where(and(eq(schema.integrations.spaceId, space.id), eq(schema.integrations.provider, "linear")))
    expect(remaining.length).toBe(1)
  })
})

