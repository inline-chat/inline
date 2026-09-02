import { afterEach, beforeEach, describe, expect, it } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { inviteCodes, users } from "@in/server/db/schema"
import { setupTestLifecycle } from "@in/server/__tests__/setup"
import {
  getOrCreateUserByEmailForSignup,
  getOrCreateUserByPhoneForSignup,
  isInviteCodeRequired,
  isLoginUser,
  isSignupComplete,
} from "./signupInvites"
import { resetServerConfigCacheForTests } from "@in/server/modules/serverConfig"
import { handler as sendEmailCode } from "@in/server/methods/sendEmailCode"
import { handler as sendSmsCode } from "@in/server/methods/sendSmsCode"

describe("signup invite user setup state", () => {
  setupTestLifecycle()

  let previousInviteCodesRequired: string | undefined
  let previousSignupMode: string | undefined

  beforeEach(() => {
    previousInviteCodesRequired = process.env["INVITE_CODES_REQUIRED"]
    previousSignupMode = process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"]
    process.env["INVITE_CODES_REQUIRED"] = "false"
    delete process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"]
    resetServerConfigCacheForTests()
  })

  afterEach(() => {
    if (previousInviteCodesRequired === undefined) {
      delete process.env["INVITE_CODES_REQUIRED"]
    } else {
      process.env["INVITE_CODES_REQUIRED"] = previousInviteCodesRequired
    }
    if (previousSignupMode === undefined) {
      delete process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"]
    } else {
      process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"] = previousSignupMode
    }
    resetServerConfigCacheForTests()
  })

  it("creates new email and phone users with profile setup pending", async () => {
    const emailResult = await getOrCreateUserByEmailForSignup("new-email-signup@example.com")
    const phoneResult = await getOrCreateUserByPhoneForSignup("+15555550123")

    expect(emailResult.created).toBe(true)
    expect(emailResult.user.emailVerified).toBe(true)
    expect(emailResult.user.pendingSetup).toBe(true)
    expect(phoneResult.created).toBe(true)
    expect(phoneResult.user.phoneVerified).toBe(true)
    expect(phoneResult.user.pendingSetup).toBe(true)
  })

  it("preserves pending setup for unfinished users and completed state for returning users", async () => {
    await db.insert(users).values({
      email: "unfinished-signup@example.com",
      emailVerified: false,
      pendingSetup: true,
    })
    await db.insert(users).values({
      phoneNumber: "+15555550456",
      phoneVerified: true,
      pendingSetup: false,
    })

    const unfinished = await getOrCreateUserByEmailForSignup("unfinished-signup@example.com")
    const completed = await getOrCreateUserByPhoneForSignup("+15555550456")

    expect(unfinished.created).toBe(false)
    expect(unfinished.user.emailVerified).toBe(true)
    expect(unfinished.user.pendingSetup).toBe(true)
    expect(isLoginUser(unfinished.user)).toBe(true)
    expect(isSignupComplete(unfinished.user)).toBe(false)
    expect(completed.created).toBe(false)
    expect(completed.user.phoneVerified).toBe(true)
    expect(completed.user.pendingSetup).toBe(false)
    expect(isSignupComplete(completed.user)).toBe(true)

    process.env["INVITE_CODES_REQUIRED"] = "true"
    expect(await isInviteCodeRequired(unfinished.user)).toBe(false)
  })

  it("blocks unknown contacts while sign-ups are disabled", async () => {
    process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"] = "disabled"
    resetServerConfigCacheForTests()

    await expect(
      sendEmailCode(
        { email: "disabled-email-code@example.com" },
        { ip: undefined, source: "/v1/sendEmailCode" },
      ),
    ).rejects.toMatchObject({ type: "SIGNUPS_DISABLED", code: 400 })
    await expect(
      sendSmsCode(
        { phoneNumber: "+14155552671" },
        { ip: undefined, source: "/v1/sendSmsCode" },
      ),
    ).rejects.toMatchObject({ type: "SIGNUPS_DISABLED", code: 400 })
    await expect(
      getOrCreateUserByEmailForSignup("disabled-email-signup@example.com"),
    ).rejects.toMatchObject({ type: "SIGNUPS_DISABLED", code: 400 })
    await expect(
      getOrCreateUserByPhoneForSignup("+15555550999"),
    ).rejects.toMatchObject({ type: "SIGNUPS_DISABLED", code: 400 })
  })

  it("does not let a valid invite code bypass disabled sign-ups", async () => {
    process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"] = "disabled"
    resetServerConfigCacheForTests()
    await db.insert(inviteCodes).values({ code: "STOP1234" })

    await expect(
      getOrCreateUserByEmailForSignup("disabled-invited-signup@example.com", "STOP1234"),
    ).rejects.toMatchObject({ type: "SIGNUPS_DISABLED", code: 400 })

    expect(
      await db.select().from(users).where(eq(users.email, "disabled-invited-signup@example.com")),
    ).toHaveLength(0)
    expect(
      await db.select().from(inviteCodes).where(eq(inviteCodes.code, "STOP1234")),
    ).toEqual([expect.objectContaining({ redeemedAt: null, redeemedByUserId: null })])
  })

  it("lets an existing pending user continue while new sign-ups are disabled", async () => {
    process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"] = "disabled"
    resetServerConfigCacheForTests()
    await db.insert(users).values({
      email: "existing-pending-signup@example.com",
      pendingSetup: true,
      emailVerified: false,
    })

    const result = await getOrCreateUserByEmailForSignup("existing-pending-signup@example.com")

    expect(result.created).toBe(false)
    expect(result.user.emailVerified).toBe(true)
    expect(result.user.pendingSetup).toBe(true)
  })
})
