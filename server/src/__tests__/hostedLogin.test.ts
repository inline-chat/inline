import { describe, expect, it, spyOn } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { inlineProtocolAuthKeys, loginTransactions } from "@in/server/db/schema"
import {
  beginInlineProtocolBrowserLogin,
  completeHostedLogin,
  inlineProtocolBrowserLoginStatus,
} from "@in/server/modules/auth/hostedLogin/service"
import { setupTestLifecycle, testUtils } from "./setup"
import { connectionManager } from "@in/server/ws/connections"

describe("hosted login transactions", () => {
  setupTestLifecycle()

  it("authorizes exactly the bound V3 key without putting credentials in the browser URL", async () => {
    const user = await testUtils.createUser("hosted-login@example.com")
    const authKeyId = crypto.getRandomValues(new Uint8Array(8))
    await db.insert(inlineProtocolAuthKeys).values({
      authKeyId: Buffer.from(authKeyId),
      authKeyEncrypted: Buffer.alloc(284, 7),
      keyEncryptionKeyId: "test",
      currentServerSalt: 1n,
    })

    const deviceId = crypto.randomUUID()
    const previous = await testUtils.createSessionForUser(user.id, { deviceId })
    const begun = await beginInlineProtocolBrowserLogin({
      authKeyId,
      client: { clientType: "cli", deviceId, deviceName: "test CLI" },
    })
    expect(begun.verificationCode).toMatch(/^\d{6}$/)
    expect(begun.browserUrl).not.toContain(Buffer.from(authKeyId).toString("hex"))
    expect(await inlineProtocolBrowserLoginStatus({
      transactionId: begun.loginTransactionId,
      authKeyId,
    })).toEqual({ kind: "pending" })

    const close = spyOn(connectionManager, "closeConnectionForSession")
    try {
      await completeHostedLogin({
        transactionId: begun.loginTransactionId,
        account: { userId: user.id, method: "email" },
      })
      expect(close).toHaveBeenCalledWith(user.id, previous.session.id, { authenticationInvalidated: true }, undefined)
    } finally {
      close.mockRestore()
    }
    const status = await inlineProtocolBrowserLoginStatus({
      transactionId: begun.loginTransactionId,
      authKeyId,
    })
    expect(status.kind).toBe("authorized")
    if (status.kind === "authorized") {
      expect(status.user.id).toBe(user.id)
      expect(status.accountSessionId).toBeGreaterThan(0)
    }
    await expect(completeHostedLogin({
      transactionId: begun.loginTransactionId,
      account: { userId: user.id, method: "email" },
    })).rejects.toBeDefined()

    const [transaction] = await db.select().from(loginTransactions)
      .where(eq(loginTransactions.id, begun.loginTransactionId))
    expect(transaction?.status).toBe("complete")
    expect(transaction?.authMethod).toBe("email")
  })

  it("does not disclose another key's transaction status", async () => {
    const authKeyId = crypto.getRandomValues(new Uint8Array(8))
    await db.insert(inlineProtocolAuthKeys).values({
      authKeyId: Buffer.from(authKeyId),
      authKeyEncrypted: Buffer.alloc(284, 9),
      keyEncryptionKeyId: "test",
      currentServerSalt: 2n,
    })
    const begun = await beginInlineProtocolBrowserLogin({ authKeyId, client: { clientType: "cli" } })
    await expect(inlineProtocolBrowserLoginStatus({
      transactionId: begun.loginTransactionId,
      authKeyId: crypto.getRandomValues(new Uint8Array(8)),
    })).rejects.toBeDefined()
  })
})
