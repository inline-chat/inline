import { beforeEach, describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db, schema } from "@in/server/db"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import {
  disconnectOwnedConnection,
  getOwnedConnection,
  listCurrentUserConnections,
  saveCodexConnection,
} from "./connectionStore"

describe("chatgpt connection store", () => {
  setupTestLifecycle()

  beforeEach(() => {
    process.env["ENCRYPTION_KEY"] = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  })

  test("stores one active user Codex connection and clears sensitive metadata on disconnect", async () => {
    const user = await testUtils.createUser("chatgpt-connection@example.com")

    const first = await saveCodexConnection({
      connectedByUserId: user.id,
      scope: { type: "user", userId: user.id },
      credential: {
        accessToken: "access-1",
        refreshToken: "refresh-1",
        expiresAt: 1_770_000_000_000,
      },
      identity: {
        email: "first@example.com",
        profileName: "first@example.com",
        chatgptPlanType: "plus",
      },
    })
    const second = await saveCodexConnection({
      connectedByUserId: user.id,
      scope: { type: "user", userId: user.id },
      credential: {
        accessToken: "access-2",
        refreshToken: "refresh-2",
      },
      identity: {
        email: "second@example.com",
        profileName: "second@example.com",
      },
    })

    expect(first.id).not.toBe(second.id)

    const listed = await listCurrentUserConnections(user.id)
    expect(listed).toHaveLength(1)
    expect(listed[0]).toMatchObject({
      id: second.id,
      provider: "openai_codex",
      email: "second@example.com",
    })

    const [oldRow] = await db
      .select()
      .from(schema.oauthConnections)
      .where(eq(schema.oauthConnections.id, Number(first.id)))
    expect(oldRow?.status).toBe("revoked")

    const stored = await getOwnedConnection({ connectionId: Number(second.id), userId: user.id })
    expect(stored?.credential).toMatchObject({ accessToken: "access-2", refreshToken: "refresh-2" })
    expect(stored?.identity).toMatchObject({ email: "second@example.com" })

    await expect(disconnectOwnedConnection({ connectionId: Number(second.id), userId: user.id })).resolves.toBe(true)
    await expect(listCurrentUserConnections(user.id)).resolves.toEqual([])

    const disconnected = await getOwnedConnection({ connectionId: Number(second.id), userId: user.id })
    expect(disconnected?.row.status).toBe("revoked")
    expect(disconnected?.credential).toEqual({ accessToken: "revoked", refreshToken: "revoked" })
    expect(disconnected?.identity).toBeUndefined()
  })
})
