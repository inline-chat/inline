import { describe, expect, it, spyOn } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { inlineProtocolAuthKeys, loginTransactions } from "@in/server/db/schema"
import {
  beginInlineProtocolBrowserLogin,
  completeHostedLogin,
  inlineProtocolBrowserLoginStatus,
  issueHostedLoginCsrf,
} from "@in/server/modules/auth/hostedLogin/service"
import { setupTestLifecycle, testUtils } from "./setup"
import {
  continueHostedLoginAfterProof,
  handleHostedLoginConfirm,
  handleHostedLoginGet,
} from "@in/server/modules/auth/hostedLogin/httpHandlers"
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

  const beginCliLogin = async (fill: number) => {
    const authKeyId = crypto.getRandomValues(new Uint8Array(8))
    await db.insert(inlineProtocolAuthKeys).values({
      authKeyId: Buffer.from(authKeyId),
      authKeyEncrypted: Buffer.alloc(284, fill),
      keyEncryptionKeyId: "test",
      currentServerSalt: BigInt(fill),
    })
    const begun = await beginInlineProtocolBrowserLogin({
      authKeyId,
      client: { clientType: "cli", deviceName: "Attacker laptop", requestNetwork: "net-a" },
    })
    const capability = new URL(begun.browserUrl).searchParams.get("capability")!
    const [transaction] = await db.select().from(loginTransactions).where(eq(loginTransactions.id, begun.loginTransactionId))
    if (!transaction) throw new Error("Missing transaction")
    return { authKeyId, begun, capability, transaction }
  }

  const confirm = (capability: string, values: Record<string, string>) => handleHostedLoginConfirm(
    new Request("http://localhost/v1/auth/login/confirm", { method: "POST", headers: { cookie: `inline_hl=${capability}` } }),
    values,
  )

  /** The capability the proving browser receives; the original link's capability is rotated away. */
  const provenCapability = (response: Response): string => {
    const cookie = response.headers.getSetCookie().find((value) => value.startsWith("inline_hl="))
    const capability = cookie ? decodeURIComponent(cookie.slice("inline_hl=".length).split(";")[0] ?? "") : ""
    if (!capability) throw new Error("Missing rotated capability cookie")
    expect(cookie).toContain("HttpOnly")
    return capability
  }

  it("signing in alone never authorizes the CLI; the terminal code is required", async () => {
    const user = await testUtils.createUser("cli-confirm@example.com")
    const { authKeyId, begun, capability: originalCapability, transaction } = await beginCliLogin(11)

    const page = await continueHostedLoginAfterProof({ transaction, account: { userId: user.id, method: "email" } })
    const capability = provenCapability(page)
    expect(capability).not.toBe(originalCapability)
    const html = await page.text()
    expect(html).toContain("Sign in the Inline CLI?")
    expect(html).toContain("Attacker laptop")
    expect(html).not.toContain(begun.verificationCode)
    const csrf = /name="csrf" value="([^"]+)"/.exec(html)?.[1]
    if (!csrf) throw new Error("Missing csrf")
    expect(await inlineProtocolBrowserLoginStatus({ transactionId: begun.loginTransactionId, authKeyId }))
      .toEqual({ kind: "pending" })

    const wrong = begun.verificationCode === "000000" ? "111111" : "000000"
    const rejected = await confirm(capability, { csrf, code: wrong, decision: "confirm" })
    expect(rejected.status).toBe(400)
    expect(await inlineProtocolBrowserLoginStatus({ transactionId: begun.loginTransactionId, authKeyId }))
      .toEqual({ kind: "pending" })

    const accepted = await confirm(capability, { csrf, code: begun.verificationCode, decision: "confirm" })
    expect(accepted.status).toBe(200)
    const status = await inlineProtocolBrowserLoginStatus({ transactionId: begun.loginTransactionId, authKeyId })
    expect(status.kind).toBe("authorized")
  })

  it("cancelling at the confirmation step leaves the CLI unauthorized", async () => {
    const user = await testUtils.createUser("cli-cancel@example.com")
    const { authKeyId, begun, transaction } = await beginCliLogin(12)
    const page = await continueHostedLoginAfterProof({ transaction, account: { userId: user.id, method: "email" } })
    const capability = provenCapability(page)
    const html = await page.text()
    const csrf = /name="csrf" value="([^"]+)"/.exec(html)?.[1]
    if (!csrf) throw new Error("Missing csrf")
    const cancelled = await confirm(capability, { csrf, decision: "cancel" })
    expect(await cancelled.text()).toContain("Sign-in cancelled")
    expect(await inlineProtocolBrowserLoginStatus({ transactionId: begun.loginTransactionId, authKeyId }))
      .toEqual({ kind: "cancelled" })
  })

  it("a phisher holding the original link cannot confirm after the victim signs in", async () => {
    const victim = await testUtils.createUser("cli-phish-victim@example.com")
    // The attacker ran `inline login`: they hold the link capability and see the code.
    const { authKeyId, begun, capability: attackerCapability, transaction } = await beginCliLogin(13)

    // The victim opens the link and proves their account in their own browser.
    const proof = await continueHostedLoginAfterProof({ transaction, account: { userId: victim.id, method: "email" } })
    const victimCapability = provenCapability(proof)

    // Re-opening the original link no longer yields a session or CSRF for this transaction.
    const reopened = await handleHostedLoginGet(
      new Request(`http://localhost/v1/auth/login?capability=${encodeURIComponent(attackerCapability)}`),
    )
    expect(reopened.headers.getSetCookie().some((value) => value.startsWith("inline_hl="))).toBe(false)
    expect(await reopened.text()).toContain("invalid or expired")

    // Even with a CSRF value for the transaction, the original capability cannot confirm.
    const csrf = await issueHostedLoginCsrf(begun.loginTransactionId)
    const forged = await confirm(attackerCapability, { csrf, code: begun.verificationCode, decision: "confirm" })
    expect(await forged.text()).toContain("invalid or expired")
    expect(await inlineProtocolBrowserLoginStatus({ transactionId: begun.loginTransactionId, authKeyId }))
      .toEqual({ kind: "pending" })

    // The proving browser still completes with the code from the terminal.
    const accepted = await confirm(victimCapability, { csrf, code: begun.verificationCode, decision: "confirm" })
    expect(accepted.status).toBe(200)
    expect((await inlineProtocolBrowserLoginStatus({ transactionId: begun.loginTransactionId, authKeyId })).kind)
      .toBe("authorized")
  })
})
