import { describe, expect, it } from "bun:test"
import { app } from "../index"
import { db } from "@in/server/db"
import { inviteCodes, loginCodes, members, sessions, spaces, users } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import { hashLoginCode, hashToken } from "@in/server/utils/auth"
import { setupTestLifecycle } from "./setup"

describe("API Endpoints", () => {
  // Setup test lifecycle
  setupTestLifecycle()

  const testServer = app

  const createInviteCode = async (code: string) => {
    await db.insert(inviteCodes).values({ code })
    return code
  }

  describe("Health Check", () => {
    it("should return 200 for health check", async () => {
      const response = await testServer.handle(new Request("http://localhost/"))
      expect(response.status).toBe(200)
      expect(await response.text()).toContain("running")
    })

    it("sets hardening headers", async () => {
      const response = await testServer.handle(
        new Request("http://localhost/", {
          headers: {
            origin: "https://inline.chat",
          },
        }),
      )

      expect(response.headers.get("access-control-allow-origin")).toContain("https://inline.chat")
      expect(response.headers.get("x-content-type-options")).toContain("nosniff")
      expect(response.headers.get("cross-origin-opener-policy")).toContain("same-origin")
      expect(response.headers.get("x-request-id")).toBeTruthy()
    })
  })

  describe("Controller routing", () => {
    it("keeps public JSON POST routes reachable", async () => {
      const waitlistResponse = await testServer.handle(
        new Request("http://localhost/waitlist/subscribe", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            origin: "https://inline.chat",
          },
          body: JSON.stringify({
            email: "waitlist-route@example.com",
            timeZone: "UTC",
          }),
        }),
      )

      expect(waitlistResponse.status).toBe(200)
      expect(await waitlistResponse.json()).toMatchObject({ ok: true })

      const thereResponse = await testServer.handle(
        new Request("http://localhost/api/there/signup", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            origin: "https://inline.chat",
          },
          body: JSON.stringify({
            email: "there-route@example.com",
            timeZone: "UTC",
          }),
        }),
      )

      expect(thereResponse.status).toBe(200)
      expect(await thereResponse.json()).toMatchObject({ ok: true })
    })

    it("keeps admin auth JSON POST route reachable", async () => {
      const response = await testServer.handle(
        new Request("http://localhost/admin/auth/send-email-code", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            origin: "https://admin.inline.chat",
          },
          body: JSON.stringify({
            email: "missing-admin@example.com",
          }),
        }),
      )

      expect(response.status).toBe(200)
      expect(await response.json()).toMatchObject({ ok: true })
    })
  })

  describe("Error handling", () => {
    it("returns the API error HTTP status", async () => {
      const response = await testServer.handle(
        new Request("http://localhost/v1/getMe", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
          },
          body: JSON.stringify({}),
        }),
      )

      expect(response.status).toBe(401)
      expect(await response.json()).toMatchObject({
        ok: false,
        error: "UNAUTHORIZED",
        errorCode: 401,
      })
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
          needsInviteCode: true,
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
      const inviteCode = await createInviteCode("CHALNG01")

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
          inviteCode,
        }),
      })

      const response = await testServer.handle(request)
      expect(response.status).toBe(200)
    })

    it("rejects email login verification without a challenge token", async () => {
      // Create a login code
      const code = "123456"
      const inviteCode = await createInviteCode("LEGACY01")
      await db.insert(loginCodes).values({
        email: "test@example.com",
        code: null,
        codeHash: await hashLoginCode(code),
        challengeId: "lc_no_token",
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
          inviteCode,
        }),
      })

      const response = await testServer.handle(request)
      expect(response.status).toBe(400)
      const json = await response.json()
      expect(json).toMatchObject({
        ok: false,
        error: "EMAIL_CODE_INVALID",
      })

      const user = await db.select().from(users).where(eq(users.email, "test@example.com"))
      expect(user.length).toBe(0)
    })

    it("does not match other active challenges without the challenge token", async () => {
      const email = "legacy-fallback@example.com"
      const inviteCode = await createInviteCode("LEGACY02")
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
          inviteCode,
        }),
      })

      const response = await testServer.handle(request)
      expect(response.status).toBe(400)
      expect(await response.json()).toMatchObject({
        ok: false,
        error: "EMAIL_CODE_INVALID",
      })
    })

    it("checks an invite code before signup", async () => {
      await createInviteCode("CHECK001")

      const request = new Request("http://localhost/v1/checkInviteCode", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-forwarded-for": "198.51.100.10",
        },
        body: JSON.stringify({
          inviteCode: "check001",
        }),
      })

      const response = await testServer.handle(request)
      expect(response.status).toBe(200)
      expect(await response.json()).toMatchObject({
        ok: true,
        result: {
          valid: true,
        },
      })
    })

    it("allows the dev invite code without a database row in development", async () => {
      const previousEnv = process.env.NODE_ENV
      process.env.NODE_ENV = "development"

      try {
        const request = new Request("http://localhost/v1/checkInviteCode", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-forwarded-for": "198.51.100.12",
          },
          body: JSON.stringify({
            inviteCode: "aaaaaaaa",
          }),
        })

        const response = await testServer.handle(request)
        expect(response.status).toBe(200)
        expect(await response.json()).toMatchObject({
          ok: true,
          result: {
            valid: true,
          },
        })
      } finally {
        if (previousEnv === undefined) {
          Reflect.deleteProperty(process.env, "NODE_ENV")
        } else {
          process.env.NODE_ENV = previousEnv
        }
      }
    })

    it("does not allow the dev invite code bypass in production", async () => {
      const previousEnv = process.env.NODE_ENV
      process.env.NODE_ENV = "production"

      try {
        const request = new Request("http://localhost/v1/checkInviteCode", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-forwarded-for": "198.51.100.13",
          },
          body: JSON.stringify({
            inviteCode: "AAAAAAAA",
          }),
        })

        const response = await testServer.handle(request)
        expect(response.status).toBe(400)
        expect(await response.json()).toMatchObject({
          ok: false,
          error: "INVITE_CODE_NOT_FOUND",
        })
      } finally {
        if (previousEnv === undefined) {
          Reflect.deleteProperty(process.env, "NODE_ENV")
        } else {
          process.env.NODE_ENV = previousEnv
        }
      }
    })

    it("redeems the dev invite code without a database row in development", async () => {
      const previousEnv = process.env.NODE_ENV
      process.env.NODE_ENV = "development"
      const email = "dev-invite-code@example.com"
      const code = "123456"
      await db.insert(loginCodes).values({
        email,
        code: null,
        codeHash: await hashLoginCode(code),
        challengeId: "lc_dev_invite_code",
        expiresAt: new Date(Date.now() + 1000 * 60 * 60 * 24),
      })

      try {
        const request = new Request("http://localhost/v1/verifyEmailCode", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            email,
            code,
            challengeToken: "lc_dev_invite_code",
            inviteCode: "AAAAAAAA",
          }),
        })

        const response = await testServer.handle(request)
        expect(response.status).toBe(200)
        const created = (await db.select().from(users).where(eq(users.email, email)).limit(1))[0]
        expect(created?.emailVerified).toBe(true)
        expect(created?.pendingSetup).toBe(false)
        const bypassCode = (await db.select().from(inviteCodes).where(eq(inviteCodes.code, "AAAAAAAA")).limit(1))[0]
        expect(bypassCode).toBeUndefined()
      } finally {
        if (previousEnv === undefined) {
          Reflect.deleteProperty(process.env, "NODE_ENV")
        } else {
          process.env.NODE_ENV = previousEnv
        }
      }
    })

    it("rate limits invite code checks in memory", async () => {
      let lastJson: any

      for (let i = 0; i < 6; i += 1) {
        const request = new Request("http://localhost/v1/checkInviteCode", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-forwarded-for": "198.51.100.11",
          },
          body: JSON.stringify({
            inviteCode: "RATELIM1",
          }),
        })

        const response = await testServer.handle(request)
        lastJson = await response.json()
      }

      expect(lastJson).toMatchObject({
        ok: false,
        error: "FLOOD",
      })
    })

    it("requires invite code for a new email signup", async () => {
      const email = "invite-required@example.com"
      const code = "123456"
      await db.insert(loginCodes).values({
        email,
        code: null,
        codeHash: await hashLoginCode(code),
        challengeId: "lc_invite_required",
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
          challengeToken: "lc_invite_required",
        }),
      })

      const response = await testServer.handle(request)
      expect(response.status).toBe(400)
      expect(await response.json()).toMatchObject({
        ok: false,
        error: "INVITE_CODE_REQUIRED",
        errorCode: 400,
        description: "Enter an invite code to sign up.",
      })
    })

    it("returns a clear error for malformed invite codes", async () => {
      const email = "invite-malformed@example.com"
      const code = "123456"
      await db.insert(loginCodes).values({
        email,
        code: null,
        codeHash: await hashLoginCode(code),
        challengeId: "lc_invite_malformed",
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
          challengeToken: "lc_invite_malformed",
          inviteCode: "bad",
        }),
      })

      const response = await testServer.handle(request)
      expect(response.status).toBe(400)
      expect(await response.json()).toMatchObject({
        ok: false,
        error: "INVITE_CODE_INVALID",
        errorCode: 400,
        description: "Invite code must be 8 letters or numbers.",
      })
    })

    it("returns a clear error for unknown invite codes", async () => {
      const email = "invite-unknown@example.com"
      const code = "123456"
      await db.insert(loginCodes).values({
        email,
        code: null,
        codeHash: await hashLoginCode(code),
        challengeId: "lc_invite_unknown",
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
          challengeToken: "lc_invite_unknown",
          inviteCode: "MISSNG01",
        }),
      })

      const response = await testServer.handle(request)
      expect(response.status).toBe(400)
      expect(await response.json()).toMatchObject({
        ok: false,
        error: "INVITE_CODE_NOT_FOUND",
        errorCode: 400,
        description: "We couldn't find that invite code.",
      })
    })

    it("returns a clear error for used invite codes", async () => {
      const email = "invite-taken@example.com"
      const code = "123456"
      const [redeemer] = await db.insert(users).values({ email: "invite-code-redeemer@example.com" }).returning()
      await db.insert(inviteCodes).values({
        code: "TAKEN001",
        redeemedByUserId: redeemer?.id,
        redeemedAt: new Date(),
      })
      await db.insert(loginCodes).values({
        email,
        code: null,
        codeHash: await hashLoginCode(code),
        challengeId: "lc_invite_taken",
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
          challengeToken: "lc_invite_taken",
          inviteCode: "taken001",
        }),
      })

      const response = await testServer.handle(request)
      expect(response.status).toBe(400)
      expect(await response.json()).toMatchObject({
        ok: false,
        error: "INVITE_CODE_TAKEN",
        errorCode: 400,
        description: "This invite code has already been used.",
      })
    })

    it("can disable invite code requirement from the server", async () => {
      const email = "invite-disabled@example.com"
      const code = "123456"
      const previous = process.env["INVITE_CODES_REQUIRED"]
      process.env["INVITE_CODES_REQUIRED"] = "false"
      await db.insert(loginCodes).values({
        email,
        code: null,
        codeHash: await hashLoginCode(code),
        challengeId: "lc_invite_disabled",
        expiresAt: new Date(Date.now() + 1000 * 60 * 60 * 24),
      })

      try {
        const sendRequest = new Request("http://localhost/v1/sendEmailCode", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ email }),
        })
        const sendResponse = await testServer.handle(sendRequest)
        expect(sendResponse.status).toBe(200)
        expect(await sendResponse.json()).toMatchObject({
          ok: true,
          result: {
            existingUser: false,
            needsInviteCode: false,
          },
        })

        const request = new Request("http://localhost/v1/verifyEmailCode", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            email,
            code,
            challengeToken: "lc_invite_disabled",
          }),
        })

        const response = await testServer.handle(request)
        expect(response.status).toBe(200)
        const created = (await db.select().from(users).where(eq(users.email, email)).limit(1))[0]
        expect(created?.emailVerified).toBe(true)
        expect(created?.pendingSetup).toBe(false)
      } finally {
        if (previous === undefined) {
          delete process.env["INVITE_CODES_REQUIRED"]
        } else {
          process.env["INVITE_CODES_REQUIRED"] = previous
        }
      }
    })

    it("does not require invite code for a pending space invite", async () => {
      const email = "space-invited@example.com"
      const code = "123456"
      const [inviter] = await db.insert(users).values({ email: "space-inviter@example.com" }).returning()
      const [space] = await db.insert(spaces).values({ name: "Invite Test", creatorId: inviter?.id }).returning()
      const [invitee] = await db
        .insert(users)
        .values({ email, pendingSetup: true, emailVerified: false })
        .returning()

      if (!space || !invitee) {
        throw new Error("Failed to seed invited user")
      }

      await db.insert(members).values({ userId: invitee.id, spaceId: space.id, invitedBy: inviter?.id })
      await db.insert(loginCodes).values({
        email,
        code: null,
        codeHash: await hashLoginCode(code),
        challengeId: "lc_space_invite",
        expiresAt: new Date(Date.now() + 1000 * 60 * 60 * 24),
      })

      const sendRequest = new Request("http://localhost/v1/sendEmailCode", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ email }),
      })
      const sendResponse = await testServer.handle(sendRequest)
      expect(sendResponse.status).toBe(200)
      expect(await sendResponse.json()).toMatchObject({
        ok: true,
        result: {
          existingUser: false,
          needsInviteCode: false,
        },
      })

      const request = new Request("http://localhost/v1/verifyEmailCode", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          email,
          code,
          challengeToken: "lc_space_invite",
        }),
      })

      const response = await testServer.handle(request)
      expect(response.status).toBe(200)
      const updated = (await db.select().from(users).where(eq(users.id, invitee.id)).limit(1))[0]
      expect(updated?.pendingSetup).toBe(false)
      expect(updated?.emailVerified).toBe(true)
    })

    it("returns EMAIL_CODE_INVALID for incorrect email code", async () => {
      const email = "invalid-code@example.com"
      await db.insert(loginCodes).values({
        email,
        code: null,
        codeHash: await hashLoginCode("123456"),
        challengeId: "lc_invalid_code",
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
          challengeToken: "lc_invalid_code",
        }),
      })

      const response = await testServer.handle(request)
      expect(response.status).toBe(400)
      expect(await response.json()).toMatchObject({
        ok: false,
        error: "EMAIL_CODE_INVALID",
        errorCode: 400,
      })
    })

    it("should preserve deviceId when saving push token", async () => {
      const code = "654321"
      const inviteCode = await createInviteCode("DEVICE01")
      await db.insert(loginCodes).values({
        email: "device@test.com",
        code: null,
        codeHash: await hashLoginCode(code),
        challengeId: "lc_device",
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
          challengeToken: "lc_device",
          inviteCode,
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
