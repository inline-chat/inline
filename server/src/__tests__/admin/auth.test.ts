import { describe, expect, it } from "bun:test"
import { app } from "../../index"
import { db } from "@in/server/db"
import { loginCodes, superadminSessions, superadminUsers, users } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"
import { generateTotpCode } from "@in/server/utils/totp"

const ADMIN_ORIGIN = "http://localhost:5174"
const USER_AGENT = "admin-test-agent"

const buildRequest = (
  path: string,
  options: {
    method?: string
    body?: Record<string, unknown>
    cookie?: string
    headers?: Record<string, string>
  } = {},
) => {
  const { method = "GET", body, cookie, headers = {} } = options
  const requestHeaders: Record<string, string> = {
    origin: ADMIN_ORIGIN,
    "user-agent": USER_AGENT,
    ...headers,
  }

  if (cookie) {
    requestHeaders.Cookie = cookie
  }

  let requestBody: string | undefined
  if (body) {
    requestHeaders["Content-Type"] = "application/json"
    requestBody = JSON.stringify(body)
  }

  return new Request(`http://localhost${path}`, {
    method,
    headers: requestHeaders,
    body: requestBody,
  })
}

const extractAdminCookie = (response: Response) => {
  const setCookie = response.headers.get("set-cookie")
  if (!setCookie) return null
  const match = setCookie.match(/inline_admin_session=([^;]+)/)
  if (!match) return null
  return `inline_admin_session=${match[1]}`
}

const createSuperadmin = async (email: string, password?: string) => {
  const values: typeof superadminUsers.$inferInsert = { email }
  if (password) {
    values.passwordHash = await Bun.password.hash(password)
    values.passwordSetAt = new Date()
  }
  const [adminUser] = await db.insert(superadminUsers).values(values).returning()
  return adminUser
}

describe("Admin auth", () => {
  setupTestLifecycle()

  it("sends email code for allowed admin without password", async () => {
    const email = "founder-admin@example.com"
    await createSuperadmin(email)

    const response = await app.handle(
      buildRequest("/admin/auth/send-email-code", {
        method: "POST",
        body: { email },
      }),
    )

    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({ ok: true })

    const codes = await db.select().from(loginCodes).where(eq(loginCodes.email, email))
    expect(codes.length).toBe(1)
  })

  it("does not create login code for unknown admin", async () => {
    const email = "unknown-admin@example.com"

    const response = await app.handle(
      buildRequest("/admin/auth/send-email-code", {
        method: "POST",
        body: { email },
      }),
    )

    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({ ok: true })

    const codes = await db.select().from(loginCodes).where(eq(loginCodes.email, email))
    expect(codes.length).toBe(0)
  })

  it("verifies email code and establishes session", async () => {
    const email = "code-admin@example.com"
    await createSuperadmin(email)

    await db.insert(loginCodes).values({
      email,
      code: "123456",
      expiresAt: new Date(Date.now() + 1000 * 60 * 10),
      attempts: 0,
    })

    const response = await app.handle(
      buildRequest("/admin/auth/verify-email-code", {
        method: "POST",
        body: { email, code: "123456" },
      }),
    )

    expect(response.status).toBe(200)
    const json = await response.json()
    expect(json).toMatchObject({ ok: true, user: { email } })

    const cookie = extractAdminCookie(response)
    expect(cookie).not.toBeNull()

    const meResponse = await app.handle(
      buildRequest("/admin/me", {
        cookie: cookie ?? undefined,
      }),
    )

    expect(meResponse.status).toBe(200)
    const meJson = await meResponse.json()
    expect(meJson.ok).toBe(true)
    expect(meJson.user.email).toBe(email)

    const adminRow = (await db.select().from(superadminUsers).where(eq(superadminUsers.email, email)))[0]
    expect(adminRow?.userId).not.toBeNull()
  })

  it("logs in with password and logs out", async () => {
    const email = "password-admin@example.com"
    const password = "supersecurepassword"
    await createSuperadmin(email, password)

    const response = await app.handle(
      buildRequest("/admin/auth/login", {
        method: "POST",
        body: { email, password },
      }),
    )

    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({ ok: true })

    const cookie = extractAdminCookie(response)
    expect(cookie).not.toBeNull()

    const meResponse = await app.handle(
      buildRequest("/admin/me", {
        cookie: cookie ?? undefined,
      }),
    )

    expect(meResponse.status).toBe(200)
    const meJson = await meResponse.json()
    expect(meJson.ok).toBe(true)
    expect(meJson.user.email).toBe(email)

    const logoutResponse = await app.handle(
      buildRequest("/admin/auth/logout", {
        method: "POST",
        cookie: cookie ?? undefined,
      }),
    )

    expect(logoutResponse.status).toBe(200)
    expect(await logoutResponse.json()).toMatchObject({ ok: true })

    const meAfterResponse = await app.handle(
      buildRequest("/admin/me", {
        cookie: cookie ?? undefined,
      }),
    )

    expect(meAfterResponse.status).toBe(401)

    const adminUser = (await db.select().from(superadminUsers).where(eq(superadminUsers.email, email)))[0]
    const sessions = await db
      .select()
      .from(superadminSessions)
      .where(eq(superadminSessions.userId, adminUser!.userId!))
    expect(sessions.length).toBe(1)
    expect(sessions[0]?.revokedAt).not.toBeNull()
  })

  it("locks out after repeated invalid password attempts", async () => {
    const email = "lockout-admin@example.com"
    const password = "supersecurepassword"
    await createSuperadmin(email, password)

    for (let attempt = 1; attempt <= 4; attempt += 1) {
      const response = await app.handle(
        buildRequest("/admin/auth/login", {
          method: "POST",
          body: { email, password: "wrong-password" },
        }),
      )

      expect(response.status).toBe(401)
      const json = await response.json()
      expect(json).toMatchObject({ ok: false, error: "invalid_credentials" })
    }

    const finalResponse = await app.handle(
      buildRequest("/admin/auth/login", {
        method: "POST",
        body: { email, password: "wrong-password" },
      }),
    )

    expect(finalResponse.status).toBe(429)
    const finalJson = await finalResponse.json()
    expect(finalJson).toMatchObject({ ok: false, error: "login_locked" })

    const adminRow = (await db.select().from(superadminUsers).where(eq(superadminUsers.email, email)))[0]
    expect(adminRow?.loginLockedUntil).not.toBeNull()
    expect(adminRow?.failedLoginAttempts).toBeGreaterThanOrEqual(5)
  })

  it("enforces IP throttling independent of account lockouts", async () => {
    const email = "iplock-admin@example.com"
    const password = "supersecurepassword"
    await createSuperadmin(email, password)

    const ipHeaders = { "x-forwarded-for": "203.0.113.42" }

    for (let attempt = 0; attempt < 30; attempt += 1) {
      await app.handle(
        buildRequest("/admin/auth/login", {
          method: "POST",
          body: { email, password: "wrong-password" },
          headers: ipHeaders,
        }),
      )
    }

    await db
      .update(superadminUsers)
      .set({ failedLoginAttempts: 0, loginLockedUntil: null, lastLoginAttemptAt: null })
      .where(eq(superadminUsers.email, email))

    const response = await app.handle(
      buildRequest("/admin/auth/login", {
        method: "POST",
        body: { email, password: "wrong-password" },
        headers: ipHeaders,
      }),
    )

    expect(response.status).toBe(429)
    const json = await response.json()
    expect(json).toMatchObject({ ok: false, error: "login_locked" })

    const adminRow = (await db.select().from(superadminUsers).where(eq(superadminUsers.email, email)))[0]
    expect(adminRow?.loginLockedUntil).toBeNull()
  })

  it("requires setup + step-up before sensitive user updates", async () => {
    const email = "stepup-admin@example.com"
    const password = "supersecurepassword"
    await createSuperadmin(email, password)

    const targetUser = await testUtils.createUser("target-user@example.com")
    expect(targetUser).toBeDefined()

    const loginResponse = await app.handle(
      buildRequest("/admin/auth/login", {
        method: "POST",
        body: { email, password },
      }),
    )
    expect(loginResponse.status).toBe(200)
    const cookie = extractAdminCookie(loginResponse)
    expect(cookie).not.toBeNull()

    const updateBeforeSetup = await app.handle(
      buildRequest(`/admin/users/${targetUser!.id}/update`, {
        method: "POST",
        cookie: cookie ?? undefined,
        body: { firstName: "PreSetup" },
      }),
    )

    expect(updateBeforeSetup.status).toBe(403)
    expect(await updateBeforeSetup.json()).toMatchObject({ ok: false, error: "setup_required" })

    const setupResponse = await app.handle(
      buildRequest("/admin/auth/totp/setup", {
        method: "GET",
        cookie: cookie ?? undefined,
      }),
    )

    expect(setupResponse.status).toBe(200)
    const setupJson = await setupResponse.json()
    expect(setupJson.ok).toBe(true)
    expect(setupJson.secret).toBeDefined()

    const totpCode = generateTotpCode(setupJson.secret)
    const verifyResponse = await app.handle(
      buildRequest("/admin/auth/totp/verify", {
        method: "POST",
        cookie: cookie ?? undefined,
        body: { code: totpCode },
      }),
    )

    expect(verifyResponse.status).toBe(200)
    expect(await verifyResponse.json()).toMatchObject({ ok: true })

    const updateBeforeStepUp = await app.handle(
      buildRequest(`/admin/users/${targetUser!.id}/update`, {
        method: "POST",
        cookie: cookie ?? undefined,
        body: { firstName: "BeforeStepUp" },
      }),
    )

    expect(updateBeforeStepUp.status).toBe(403)
    expect(await updateBeforeStepUp.json()).toMatchObject({ ok: false, error: "step_up_required" })

    const stepUpCode = generateTotpCode(setupJson.secret)
    const stepUpResponse = await app.handle(
      buildRequest("/admin/auth/step-up", {
        method: "POST",
        cookie: cookie ?? undefined,
        body: { password, totpCode: stepUpCode },
      }),
    )

    expect(stepUpResponse.status).toBe(200)
    expect(await stepUpResponse.json()).toMatchObject({ ok: true })

    const updateResponse = await app.handle(
      buildRequest(`/admin/users/${targetUser!.id}/update`, {
        method: "POST",
        cookie: cookie ?? undefined,
        body: { firstName: "UpdatedByAdmin" },
      }),
    )

    expect(updateResponse.status).toBe(200)
    expect(await updateResponse.json()).toMatchObject({ ok: true })

    const updatedUser = (await db.select().from(users).where(eq(users.id, targetUser!.id)))[0]
    expect(updatedUser?.firstName).toBe("UpdatedByAdmin")
  })
})
