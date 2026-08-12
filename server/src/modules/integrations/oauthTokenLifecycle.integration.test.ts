import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { integrations } from "@in/server/db/schema"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { usableOAuthAccessToken } from "./oauthTokenLifecycle"

describe("OAuth token refresh persistence", () => {
  setupTestLifecycle()

  test("serializes concurrent refreshes without changing connected time", async () => {
    const user = await testUtils.createUser("connector-refresh@example.com")
    const connectedAt = new Date("2026-08-01T00:00:00Z")
    const token = encrypt(JSON.stringify({
      data: {
        access_token: "expired-access",
        refresh_token: "refresh-once",
        expires_in: 3_600,
        obtained_at: 1_754_006_400,
      },
    }))
    const [integration] = await db.insert(integrations).values({
      userId: user.id,
      provider: "linear",
      date: connectedAt,
      accessTokenEncrypted: token.encrypted,
      accessTokenIv: token.iv,
      accessTokenTag: token.authTag,
    }).returning()
    if (!integration) throw new Error("integration not created")

    let refreshCalls = 0
    const dependencies = {
      async refreshTokens() {
        refreshCalls += 1
        return {
          access_token: "fresh-access",
          refresh_token: "fresh-refresh",
          expires_in: 86_400,
        }
      },
    }

    const tokens = await Promise.all([
      usableOAuthAccessToken(integration, dependencies),
      usableOAuthAccessToken(integration, dependencies),
    ])

    expect(tokens).toEqual(["fresh-access", "fresh-access"])
    expect(refreshCalls).toBe(1)
    const [stored] = await db
      .select({ date: integrations.date })
      .from(integrations)
      .where(eq(integrations.id, integration.id))
    expect(stored?.date).toEqual(connectedAt)
  })
})
