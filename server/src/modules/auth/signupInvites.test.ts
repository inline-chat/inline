import { afterEach, beforeEach, describe, expect, it } from "bun:test"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { setupTestLifecycle } from "@in/server/__tests__/setup"
import {
  getOrCreateUserByEmailForSignup,
  getOrCreateUserByPhoneForSignup,
  isInviteCodeRequired,
  isLoginUser,
} from "./signupInvites"

describe("signup invite user setup state", () => {
  setupTestLifecycle()

  let previousInviteCodesRequired: string | undefined

  beforeEach(() => {
    previousInviteCodesRequired = process.env["INVITE_CODES_REQUIRED"]
    process.env["INVITE_CODES_REQUIRED"] = "false"
  })

  afterEach(() => {
    if (previousInviteCodesRequired === undefined) {
      delete process.env["INVITE_CODES_REQUIRED"]
    } else {
      process.env["INVITE_CODES_REQUIRED"] = previousInviteCodesRequired
    }
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
    expect(completed.created).toBe(false)
    expect(completed.user.phoneVerified).toBe(true)
    expect(completed.user.pendingSetup).toBe(false)

    process.env["INVITE_CODES_REQUIRED"] = "true"
    expect(await isInviteCodeRequired(unfinished.user)).toBe(false)
  })
})
