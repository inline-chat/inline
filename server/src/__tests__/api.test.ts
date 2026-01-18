import { describe, expect, it } from "bun:test"
import { app } from "../index"
import { db } from "@in/server/db"
import { loginCodes, sessions, users } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import { hashToken } from "@in/server/utils/auth"
import { testUtils, setupTestLifecycle } from "./setup"

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
      expect(await response.json()).toMatchObject({
        ok: true,
        result: {
          existingUser: false,
        },
      })

      const loginCodes_ = await db.select().from(loginCodes).where(eq(loginCodes.email, "test@example.com"))
      expect(loginCodes_.length).toBe(1)
      expect(loginCodes_[0]?.code).toBeDefined()
    })

    it("should enter login code and get a token", async () => {
      // Create a login code
      await db.insert(loginCodes).values({
        email: "test@example.com",
        code: "123456",
        expiresAt: new Date(Date.now() + 1000 * 60 * 60 * 24),
      })

      // Enter the login code
      const loginCodes_ = await db.select().from(loginCodes).where(eq(loginCodes.email, "test@example.com"))
      const code = loginCodes_[0]?.code

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

    it("should preserve deviceId when saving push token", async () => {
      await db.insert(loginCodes).values({
        email: "device@test.com",
        code: "654321",
        expiresAt: new Date(Date.now() + 1000 * 60 * 60 * 24),
      })

      const request = new Request("http://localhost/v1/verifyEmailCode", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          email: "device@test.com",
          code: "654321",
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
