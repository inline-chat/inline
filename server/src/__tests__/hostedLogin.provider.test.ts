import { describe, expect, it, spyOn } from "bun:test"
import { generateKeyPairSync, randomUUID } from "node:crypto"
import { eq } from "drizzle-orm"
import { exportJWK, generateKeyPair, SignJWT } from "jose"
import { db } from "@in/server/db"
import { inlineProtocolAuthKeys, loginTransactions, providerAuthAttempts, sessions } from "@in/server/db/schema"
import { ProviderAuthModel } from "@in/server/db/models/providerAuth"
import { hashProviderSecret } from "@in/server/modules/auth/provider/service"
import {
  beginInlineProtocolBrowserLogin,
  inlineProtocolBrowserLoginStatus,
} from "@in/server/modules/auth/hostedLogin/service"
import { handleHostedLoginConfirm } from "@in/server/modules/auth/hostedLogin/httpHandlers"
import { handleProviderCallback, handleProviderStart } from "@in/server/modules/oauth/httpHandlers"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { setupTestLifecycle, testUtils } from "./setup"

// Provider config is read lazily once per process; configure test credentials before any sign-in starts.
const GOOGLE_CLIENT_ID = "hosted-login-test.apps.googleusercontent.com"
const APPLE_CLIENT_ID = "chat.inline.hosted-login-test"
process.env["GOOGLE_AUTH_CLIENT_ID"] = GOOGLE_CLIENT_ID
process.env["GOOGLE_AUTH_CLIENT_SECRET"] = "hosted-login-test-secret"
process.env["APPLE_AUTH_CLIENT_ID"] = APPLE_CLIENT_ID
process.env["APPLE_AUTH_TEAM_ID"] = "TESTTEAM01"
process.env["APPLE_AUTH_KEY_ID"] = "TESTKEY001"
process.env["APPLE_AUTH_PRIVATE_KEY"] = generateKeyPairSync("ec", { namedCurve: "prime256v1" })
  .privateKey.export({ format: "pem", type: "pkcs8" })
  .toString()

const providers = [
  {
    provider: "google" as const,
    issuer: "https://accounts.google.com",
    audience: GOOGLE_CLIENT_ID,
    tokenUrl: "https://oauth2.googleapis.com/token",
    jwksUrl: "https://www.googleapis.com/oauth2/v3/certs",
  },
  {
    provider: "apple" as const,
    issuer: "https://appleid.apple.com",
    audience: APPLE_CLIENT_ID,
    tokenUrl: "https://appleid.apple.com/auth/token",
    jwksUrl: "https://appleid.apple.com/auth/keys",
  },
]

describe("hosted CLI login through a provider", () => {
  setupTestLifecycle()

  it.each(providers)(
    "$provider sign-in reaches the confirm page and needs the terminal code",
    async ({ provider, issuer, audience, tokenUrl, jwksUrl }) => {
      const user = await testUtils.createUser(`cli-${provider}-${randomUUID()}@gmail.com`)
      const subject = `${provider}-subject-${randomUUID()}`
      await ProviderAuthModel.attachIdentity({
        provider,
        subjectHash: hashProviderSecret(`${provider}\0${subject}`),
        userId: user.id,
      })

      // The attacker-or-user's terminal ran `inline login`.
      const authKeyId = crypto.getRandomValues(new Uint8Array(8))
      await db.insert(inlineProtocolAuthKeys).values({
        authKeyId: Buffer.from(authKeyId),
        authKeyEncrypted: Buffer.alloc(284, provider === "google" ? 21 : 22),
        keyEncryptionKeyId: "test",
        currentServerSalt: provider === "google" ? 21n : 22n,
      })
      const begun = await beginInlineProtocolBrowserLogin({
        authKeyId,
        client: { clientType: "cli", deviceName: "Provider laptop" },
      })
      const linkCapability = new URL(begun.browserUrl).searchParams.get("capability")!

      // The browser picks the provider on the hosted login page.
      const limiter = new InMemoryRateLimiter()
      const start = await handleProviderStart(
        new Request(`http://localhost/v1/auth/provider/start?provider=${provider}&purpose=hosted_login`, {
          headers: { cookie: `inline_hl=${encodeURIComponent(linkCapability)}` },
        }),
        "203.0.113.30",
        limiter,
      )
      expect(start.status).toBe(302)
      const providerUrl = new URL(start.headers.get("location")!)
      const state = providerUrl.searchParams.get("state")!
      const nonce = providerUrl.searchParams.get("nonce")!
      expect(state).toBeTruthy()
      expect(nonce).toBeTruthy()

      // Only the provider's network endpoints are faked; claims and hand-off run for real.
      const { publicKey, privateKey } = await generateKeyPair("RS256", { extractable: true })
      const jwk = { ...(await exportJWK(publicKey)), kid: `kid-${provider}`, alg: "RS256", use: "sig" }
      const idToken = await new SignJWT({ nonce, email: user.email, email_verified: true })
        .setProtectedHeader({ alg: "RS256", kid: jwk.kid })
        .setIssuer(issuer)
        .setAudience(audience)
        .setSubject(subject)
        .setIssuedAt()
        .setExpirationTime("5m")
        .sign(privateKey)
      const fetchSpy = spyOn(globalThis, "fetch").mockImplementation((async (input: RequestInfo | URL) => {
        const url = input instanceof Request ? input.url : String(input)
        if (url === tokenUrl) {
          return Response.json({ access_token: "provider-access", token_type: "Bearer", expires_in: 3600, id_token: idToken })
        }
        if (url === jwksUrl) return Response.json({ keys: [jwk] })
        return new Response("unexpected request in test", { status: 404 })
      }) as unknown as typeof fetch)

      let confirmPage: Response
      try {
        const callbackUrl = new URL(`http://localhost/v1/auth/provider/callback/${provider}`)
        if (provider === "google") {
          callbackUrl.searchParams.set("state", state)
          callbackUrl.searchParams.set("code", "provider-code")
        }
        confirmPage = await handleProviderCallback(
          provider,
          new Request(callbackUrl, provider === "apple" ? { method: "POST" } : undefined),
          provider === "apple" ? { state, code: "provider-code" } : undefined,
          "203.0.113.30",
          limiter,
        )
      } finally {
        fetchSpy.mockRestore()
      }

      // The provider proved the account, but the CLI is not authorized: the confirm page asks for the code.
      expect(confirmPage.status).toBe(200)
      const html = await confirmPage.text()
      expect(html).toContain("Sign in the Inline CLI?")
      expect(html).toContain("Provider laptop")
      expect(html).toContain(`name="code"`)
      expect(html).not.toContain(begun.verificationCode)
      expect(await inlineProtocolBrowserLoginStatus({ transactionId: begun.loginTransactionId, authKeyId }))
        .toEqual({ kind: "pending" })
      expect(await db.select().from(sessions).where(eq(sessions.userId, user.id))).toHaveLength(0)
      const [transaction] = await db.select().from(loginTransactions)
        .where(eq(loginTransactions.id, begun.loginTransactionId))
      expect(transaction?.status).toBe("pending")
      expect(transaction?.userId).toBe(user.id)
      const [attempt] = await db.select().from(providerAuthAttempts)
        .where(eq(providerAuthAttempts.loginTransactionId, begun.loginTransactionId))
      expect(attempt?.status).toBe("complete")
      expect(attempt?.inlineTokenEncrypted).toBeNull()

      // Only the proving browser gets the rotated capability; the original link no longer confirms.
      const cookie = confirmPage.headers.getSetCookie().find((value) => value.startsWith("inline_hl="))
      const capability = decodeURIComponent(cookie?.slice("inline_hl=".length).split(";")[0] ?? "")
      expect(capability).toBeTruthy()
      expect(capability).not.toBe(linkCapability)
      const csrf = /name="csrf" value="([^"]+)"/.exec(html)?.[1]
      if (!csrf) throw new Error("Missing csrf")
      const confirm = (withCapability: string, values: Record<string, string>) => handleHostedLoginConfirm(
        new Request("http://localhost/v1/auth/login/confirm", {
          method: "POST",
          headers: { cookie: `inline_hl=${encodeURIComponent(withCapability)}` },
        }),
        values,
      )

      expect(await (await confirm(linkCapability, { csrf, code: begun.verificationCode, decision: "confirm" })).text())
        .toContain("invalid or expired")
      const wrong = begun.verificationCode === "000000" ? "111111" : "000000"
      expect((await confirm(capability, { csrf, code: wrong, decision: "confirm" })).status).toBe(400)
      expect(await inlineProtocolBrowserLoginStatus({ transactionId: begun.loginTransactionId, authKeyId }))
        .toEqual({ kind: "pending" })

      const accepted = await confirm(capability, { csrf, code: begun.verificationCode, decision: "confirm" })
      expect(accepted.status).toBe(200)
      const status = await inlineProtocolBrowserLoginStatus({ transactionId: begun.loginTransactionId, authKeyId })
      expect(status.kind).toBe("authorized")
      if (status.kind === "authorized") expect(status.user.id).toBe(user.id)
    },
  )
})
