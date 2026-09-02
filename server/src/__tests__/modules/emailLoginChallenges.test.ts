import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db, schema } from "@in/server/db"
import { issueEmailLoginChallenge, verifyEmailLoginChallenge } from "@in/server/modules/auth/emailLoginChallenges"
import { verifyEmailAccountProof } from "@in/server/modules/auth/contactProof"
import { resetServerConfigCacheForTests } from "@in/server/modules/serverConfig"
import { setupTestLifecycle } from "../setup"

describe("email login challenge concurrency", () => {
  setupTestLifecycle()

  test("a valid proof can be consumed only once across concurrent requests", async () => {
    const email = "concurrent-email@example.com"
    const challenge = await issueEmailLoginChallenge({ email })
    const results = await Promise.all(Array.from({ length: 8 }, () =>
      verifyEmailLoginChallenge({ email, ...challenge })))
    expect(results.filter(Boolean)).toHaveLength(1)
    expect(await db.select().from(schema.loginCodes)).toHaveLength(0)
  })

  test("concurrent invalid guesses cannot exceed or overwrite the attempt budget", async () => {
    const email = "attempt-budget@example.com"
    const challenge = await issueEmailLoginChallenge({ email })
    const wrongCode = challenge.code === "123456" ? "654321" : "123456"
    const results = await Promise.all(Array.from({ length: 12 }, () =>
      verifyEmailLoginChallenge({ email, challengeToken: challenge.challengeToken, code: wrongCode })))
    expect(results.some(Boolean)).toBe(false)
    const [stored] = await db.select().from(schema.loginCodes)
      .where(eq(schema.loginCodes.challengeId, challenge.challengeToken))
    expect(stored?.attempts).toBe(5)
    expect(await verifyEmailLoginChallenge({ email, ...challenge })).toBe(false)
  })

  test("a legacy nullable attempt count starts at zero", async () => {
    const email = "legacy-null-attempts@example.com"
    const challenge = await issueEmailLoginChallenge({ email })
    await db.update(schema.loginCodes).set({ attempts: null })
      .where(eq(schema.loginCodes.challengeId, challenge.challengeToken))
    expect(await verifyEmailLoginChallenge({ email, ...challenge })).toBe(true)
  })

  test("invite failures preserve valid proof and roll back account creation", async () => {
    const priorMode = process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"]
    process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"] = "invite_only"
    resetServerConfigCacheForTests()
    try {
      const email = "retry-email-invite@example.com"
      const challenge = await issueEmailLoginChallenge({ email })
      await db.insert(schema.inviteCodes).values({ code: "AUTH1234" })
      await expect(verifyEmailAccountProof({ email, ...challenge }))
        .rejects.toMatchObject({ type: "INVITE_CODE_REQUIRED" })
      await expect(verifyEmailAccountProof({ email, ...challenge, inviteCode: "bad" }))
        .rejects.toMatchObject({ type: "INVITE_CODE_INVALID" })
      for (let attempt = 0; attempt < 6; attempt++) {
        await expect(verifyEmailAccountProof({ email, ...challenge, inviteCode: "BADCODE1" }))
          .rejects.toMatchObject({ type: "INVITE_CODE_NOT_FOUND" })
      }
      expect(await db.select().from(schema.users).where(eq(schema.users.email, email))).toHaveLength(0)
      const [stored] = await db.select().from(schema.loginCodes)
        .where(eq(schema.loginCodes.challengeId, challenge.challengeToken))
      expect(stored?.attempts).toBe(0)
      const result = await verifyEmailAccountProof({ email, ...challenge, inviteCode: "AUTH1234" })
      expect(result.created).toBe(true)
      expect(result.user.email).toBe(email)
      await expect(verifyEmailAccountProof({ email, ...challenge, inviteCode: "AUTH1234" }))
        .rejects.toMatchObject({ type: "EMAIL_CODE_INVALID" })
    } finally {
      if (priorMode === undefined) delete process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"]
      else process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"] = priorMode
      resetServerConfigCacheForTests()
    }
  }, 10_000)

  test("missing, expired, and another email's challenges do not authenticate", async () => {
    const email = "challenge-binding@example.com"
    const challenge = await issueEmailLoginChallenge({ email })
    expect(await verifyEmailLoginChallenge({ email, code: challenge.code })).toBe(false)
    expect(await verifyEmailLoginChallenge({ email: "other@example.com", ...challenge })).toBe(false)
    await db.update(schema.loginCodes).set({ expiresAt: new Date(Date.now() - 1_000) })
    expect(await verifyEmailLoginChallenge({ email, ...challenge })).toBe(false)
  })
})
