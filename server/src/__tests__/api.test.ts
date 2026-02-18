import { describe, expect, it } from "bun:test"
import { app } from "../index"
import { db } from "@in/server/db"
import { loginCodes, sessions, users } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import { hashLoginCode, hashToken } from "@in/server/utils/auth"
import { setupTestLifecycle } from "./setup"

describe("API Endpoints", () => {
  // Setup test lifecycle
  setupTestLifecycle()

  const testServer = app

  describe("Health Check", () => {
    it("should return 200 for health check", async () => {
      const response = await testServer.handle(new Request("http://localhost/"))
      expect(response.status).toBe(200)
      expect(await response.text()).toContain("running")
    })
  })

  describe("Authentication", () => {
    it("should create login code and send email", async () => {
      const request = new Request("http://localhost/v1/sendEmailCode", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          email: "test@example.com",
        }),
      })

      const response = await testServer.handle(request)
      expect(response.status).toBe(200)
      const responseJson = await response.json()
      expect(responseJson).toMatchObject({
        ok: true,
        result: {
          existingUser: false,
        },
      })
      expect(responseJson.result.challengeToken).toEqual(expect.any(String))

      const loginCodes_ = await db.select().from(loginCodes).where(eq(loginCodes.email, "test@example.com"))
      expect(loginCodes_.length).toBe(1)
      expect(loginCodes_[0]?.codeHash).toBeDefined()
      expect(loginCodes_[0]?.code).toBeNull()
      expect(loginCodes_[0]?.challengeId).toBe(responseJson.result.challengeToken)
    })

    it("creates independent email login challenges during active TTL", async () => {
      const email = "stable-code@example.com"

      const firstSend = new Request("http://localhost/v1/sendEmailCode", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ email }),
      })

      const firstResponse = await testServer.handle(firstSend)
      expect(firstResponse.status).toBe(200)
      const firstJson = await firstResponse.json()
      const firstChallengeToken = firstJson.result.challengeToken as string
      expect(firstChallengeToken).toEqual(expect.any(String))

      const secondSend = new Request("http://localhost/v1/sendEmailCode", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ email }),
      })

      const secondResponse = await testServer.handle(secondSend)
      expect(secondResponse.status).toBe(200)
      const secondJson = await secondResponse.json()
      const secondChallengeToken = secondJson.result.challengeToken as string
      expect(secondChallengeToken).toEqual(expect.any(String))
      expect(secondChallengeToken).not.toBe(firstChallengeToken)

      const rows = await db.select().from(loginCodes).where(eq(loginCodes.email, email))
      expect(rows.length).toBe(2)
      expect(rows.every((row) => row.code === null)).toBe(true)
      const challengeTokens = rows.map((row) => row.challengeId)
      expect(challengeTokens).toContain(firstChallengeToken)
      expect(challengeTokens).toContain(secondChallengeToken)
    })

    it("verifies a specific email challenge token", async () => {
      const email = "challenge-token@example.com"
      const code = "123456"
      const challengeToken = "lc_challenge_token_1"

      await db.insert(loginCodes).values({
        email,
        code: null,
        codeHash: await hashLoginCode(code),
        challengeId: challengeToken,
        expiresAt: new Date(Date.now() + 1000 * 60 * 60 * 24),
      })

      const request = new Request("http://localhost/v1/verifyEmailCode", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          email,
          code,
          challengeToken,
        }),
      })

      const response = await testServer.handle(request)
      expect(response.status).toBe(200)
    })

    it("should enter login code and get a token (legacy flow without challenge token)", async () => {
      // Create a login code
      const code = "123456"
      await db.insert(loginCodes).values({
        email: "test@example.com",
        code: null,
        codeHash: await hashLoginCode(code),
        expiresAt: new Date(Date.now() + 1000 * 60 * 60 * 24),
      })

      // Enter the login code
      const request = new Request("http://localhost/v1/verifyEmailCode", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          email: "test@example.com",
          code: code,
        }),
      })

      const response = await testServer.handle(request)
      expect(response.status).toBe(200)
      const json = await response.json()
      expect(json.ok).toBe(true)
      expect(json.result.token).toBeDefined()

      // Verify user creation
      const user = await db.select().from(users).where(eq(users.email, "test@example.com"))
      expect(user.length).toBe(1)
      expect(user[0]?.email).toBe("test@example.com")
    })

    it("legacy verify can match any active challenge for an email", async () => {
      const email = "legacy-fallback@example.com"
      await db.insert(loginCodes).values({
        email,
        code: null,
        codeHash: await hashLoginCode("111111"),
        challengeId: "lc_legacy_1",
        expiresAt: new Date(Date.now() + 1000 * 60 * 60 * 24),
      })
      await db.insert(loginCodes).values({
        email,
        code: null,
        codeHash: await hashLoginCode("222222"),
        challengeId: "lc_legacy_2",
        expiresAt: new Date(Date.now() + 1000 * 60 * 60 * 24),
      })

      const request = new Request("http://localhost/v1/verifyEmailCode", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          email,
          code: "111111",
        }),
      })

      const response = await testServer.handle(request)
      expect(response.status).toBe(200)
    })

    it("returns EMAIL_CODE_INVALID for incorrect email code", async () => {
      const email = "invalid-code@example.com"
      await db.insert(loginCodes).values({
        email,
        code: null,
        codeHash: await hashLoginCode("123456"),
        expiresAt: new Date(Date.now() + 1000 * 60 * 60 * 24),
      })

      const request = new Request("http://localhost/v1/verifyEmailCode", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          email,
          code: "000000",
        }),
      })

      const response = await testServer.handle(request)
      expect(response.status).toBe(500)
      expect(await response.json()).toMatchObject({
        ok: false,
        error: "EMAIL_CODE_INVALID",
        errorCode: 400,
      })
    })

    it("should preserve deviceId when saving push token", async () => {
      const code = "654321"
      await db.insert(loginCodes).values({
        email: "device@test.com",
        code: null,
        codeHash: await hashLoginCode(code),
        expiresAt: new Date(Date.now() + 1000 * 60 * 60 * 24),
      })

      const request = new Request("http://localhost/v1/verifyEmailCode", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          email: "device@test.com",
          code,
          deviceId: "device-test-1",
        }),
      })

      const response = await testServer.handle(request)
      expect(response.status).toBe(200)
      const json = await response.json()
      expect(json.ok).toBe(true)
      const token = json.result.token as string
      expect(token).toBeDefined()

      const saveRequest = new Request("http://localhost/v1/savePushNotification?applePushToken=apn-test-token", {
        method: "GET",
        headers: {
          Authorization: `Bearer ${token}`,
        },
      })

      const saveResponse = await testServer.handle(saveRequest)
      expect(saveResponse.status).toBe(200)

      const tokenHash = hashToken(token)
      const session = (await db.select().from(sessions).where(eq(sessions.tokenHash, tokenHash)))[0]
      expect(session).toBeDefined()
      expect(session?.deviceId).toBe("device-test-1")
    })
  })
})
