import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from "bun:test"
import { eq } from "drizzle-orm"
import { authKeyId } from "@inline-chat/protocol/secure"
import { db, schema } from "@in/server/db"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import type { InlineProtocolApplicationContext } from "./application"
import { connectionManager } from "@in/server/ws/connections"
import { SessionsModel } from "@in/server/db/models/sessions"
import { resetServerConfigCacheForTests } from "@in/server/modules/serverConfig"

let deliveredCode: string | undefined
let preludeGeneratedSends = 0
let preludeCustomSends = 0
let preludeChecks = 0
let preludeCreateStatus: "success" | "retry" | "blocked" = "success"
const preludeGeneratedCode = "654321"
const priorPhoneCodeMode = process.env["INLINE_CONFIG_AUTH_PHONE_CODE_MODE"]

mock.module("@in/server/utils/email", () => ({
  sendEmail: async (input: { content: { variables: { code: string } } }) => {
    deliveredCode = input.content.variables.code
  },
}))
mock.module("@in/server/libs/prelude", () => ({
  prelude: {
    sendCode: async () => {
      preludeGeneratedSends += 1
      deliveredCode = preludeGeneratedCode
      return { status: preludeCreateStatus }
    },
    sendCustomCode: async (_phone: string, code: string) => {
      preludeCustomSends += 1
      deliveredCode = code
      return { status: preludeCreateStatus }
    },
    checkCode: async (_phone: string, code: string) => {
      preludeChecks += 1
      return { status: code === deliveredCode ? "success" : "failure" }
    },
  },
}))

const { InlineProtocolAuthOperations } = await import("./auth")
const { PermanentAuthorizationKeyRepository } = await import("@in/server/db/models/inlineProtocol")
const { makeAuthorizationKeyCipher } = await import("./keyCipher")

describe("Inline Protocol native authentication lifecycle", () => {
  setupTestLifecycle()

  const pepper = new Uint8Array(32).fill(0x42)
  const operations = new InlineProtocolAuthOperations({
    activeId: "pepper1",
    keys: new Map([["pepper1", pepper]]),
  })
  let context: InlineProtocolApplicationContext
  let permanentKeyId: Uint8Array

  beforeEach(async () => {
    deliveredCode = undefined
    preludeGeneratedSends = 0
    preludeCustomSends = 0
    preludeChecks = 0
    preludeCreateStatus = "success"
    delete process.env["INLINE_CONFIG_AUTH_PHONE_CODE_MODE"]
    resetServerConfigCacheForTests()
    const permanentKey = Uint8Array.from({ length: 256 }, (_, index) => 255 - index)
    permanentKeyId = authKeyId(permanentKey)
    const repository = new PermanentAuthorizationKeyRepository(makeAuthorizationKeyCipher({
      activeId: "kek1",
      keys: new Map([["kek1", new Uint8Array(32).fill(0x24)]]),
    }))
    await repository.create({
      key: permanentKey,
      keyId: permanentKeyId,
      serverSalt: 789n,
      temporary: false,
    })
    context = {
      authorization: {
        authKeyId: permanentKeyId,
        permanent: true,
        temporaryBound: false,
      },
      metadata: { ip: "203.0.113.10", userAgent: "Inline Protocol test" },
    }
  })

  afterEach(() => {
    if (priorPhoneCodeMode === undefined) delete process.env["INLINE_CONFIG_AUTH_PHONE_CODE_MODE"]
    else process.env["INLINE_CONFIG_AUTH_PHONE_CODE_MODE"] = priorPhoneCodeMode
    resetServerConfigCacheForTests()
  })

  test("delivers and consumes a challenge, creates a normal session, and binds it to the permanent key", async () => {
    const existing = await testUtils.createUser("v3-native-auth@example.com")
    const begun = await operations.begin({
      identifier: { oneofKind: "email", email: "v3-native-auth@example.com" },
      client: {
        deviceId: "v3-test-device",
        clientType: "macos",
        clientVersion: "1.0.0",
        osVersion: "15.0",
        deviceName: "V3 Test Mac",
      },
    }, context)
    expect(deliveredCode).toMatch(/^\d{6}$/)

    const completed = await operations.complete({
      challengeId: begun.challengeId,
      code: deliveredCode!,
      timeZone: "Asia/Tehran",
    }, context)
    expect(completed.state.oneofKind).toBe("authorized")
    if (completed.state.oneofKind !== "authorized") throw new Error("Expected authorization")
    expect(completed.state.authorized.user?.id).toBe(BigInt(existing.id))

    const [keyRow] = await db.select().from(schema.inlineProtocolAuthKeys)
      .where(eq(schema.inlineProtocolAuthKeys.authKeyId, Buffer.from(permanentKeyId)))
      .limit(1)
    expect(keyRow?.userId).toBe(existing.id)
    expect(keyRow?.accountSessionId).toBe(Number(completed.state.authorized.accountSessionId))
    const [challenge] = await db.select().from(schema.inlineProtocolAuthChallenges)
      .where(eq(schema.inlineProtocolAuthChallenges.challengeId, Buffer.from(begun.challengeId)))
      .limit(1)
    expect(challenge?.consumedAt).toBeInstanceOf(Date)

    await expect(operations.complete({
      challengeId: begun.challengeId,
      code: deliveredCode!,
    }, context)).rejects.toThrow()
  })

  test("uses Prelude-generated phone codes by default and freezes the challenge mode", async () => {
    const phoneNumber = "+12025550101"
    const begun = await operations.begin({
      identifier: { oneofKind: "phoneNumber", phoneNumber },
    }, context)

    expect(deliveredCode).toBe(preludeGeneratedCode)
    expect(preludeGeneratedSends).toBe(1)
    expect(preludeCustomSends).toBe(0)
    const [issued] = await db.select().from(schema.inlineProtocolAuthChallenges)
      .where(eq(schema.inlineProtocolAuthChallenges.challengeId, Buffer.from(begun.challengeId)))
    expect(issued?.delivery).toBe("sms_prelude")

    process.env["INLINE_CONFIG_AUTH_PHONE_CODE_MODE"] = "custom"
    resetServerConfigCacheForTests()
    const completed = await operations.complete({
      challengeId: begun.challengeId,
      code: deliveredCode!,
    }, context)

    expect(completed.state.oneofKind).toBe("authorized")
    expect(preludeChecks).toBe(1)
    const [verified] = await db.select().from(schema.inlineProtocolAuthChallenges)
      .where(eq(schema.inlineProtocolAuthChallenges.challengeId, Buffer.from(begun.challengeId)))
    expect(verified?.delivery).toBe("sms_verified")
  })

  test("reuses a Prelude-verified phone proof while an invite is entered", async () => {
    const priorSignupMode = process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"]
    process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"] = "invite_only"
    resetServerConfigCacheForTests()
    try {
      await db.insert(schema.inviteCodes).values({ code: "PHONE123" })
      const begun = await operations.begin({
        identifier: { oneofKind: "phoneNumber", phoneNumber: "+12025550103" },
      }, context)
      const code = deliveredCode!

      expect((await operations.complete({ challengeId: begun.challengeId, code }, context)).state.oneofKind)
        .toBe("inviteRequired")
      expect(preludeChecks).toBe(1)
      const [verified] = await db.select().from(schema.inlineProtocolAuthChallenges)
        .where(eq(schema.inlineProtocolAuthChallenges.challengeId, Buffer.from(begun.challengeId)))
      expect(verified?.delivery).toBe("sms_verified")

      expect((await operations.complete({
        challengeId: begun.challengeId,
        code,
        inviteCode: "PHONE123",
      }, context)).state.oneofKind).toBe("authorized")
      expect(preludeChecks).toBe(1)
    } finally {
      if (priorSignupMode === undefined) delete process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"]
      else process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"] = priorSignupMode
      resetServerConfigCacheForTests()
    }
  })

  test("uses Inline-generated custom phone codes only when enabled", async () => {
    process.env["INLINE_CONFIG_AUTH_PHONE_CODE_MODE"] = "custom"
    resetServerConfigCacheForTests()
    const begun = await operations.begin({
      identifier: { oneofKind: "phoneNumber", phoneNumber: "+12025550102" },
    }, context)

    expect(deliveredCode).toMatch(/^\d{6}$/)
    expect(preludeGeneratedSends).toBe(0)
    expect(preludeCustomSends).toBe(1)
    const [issued] = await db.select().from(schema.inlineProtocolAuthChallenges)
      .where(eq(schema.inlineProtocolAuthChallenges.challengeId, Buffer.from(begun.challengeId)))
    expect(issued?.delivery).toBe("sms_custom")

    const wrongCode = deliveredCode === "123456" ? "654321" : "123456"
    await expect(operations.complete({
      challengeId: begun.challengeId,
      code: wrongCode,
    }, context)).rejects.toMatchObject({ type: "SMS_CODE_INVALID" })
    expect(preludeChecks).toBe(1)

    const completed = await operations.complete({
      challengeId: begun.challengeId,
      code: deliveredCode!,
    }, context)
    expect(completed.state.oneofKind).toBe("authorized")
    expect(preludeChecks).toBe(2)
  })

  test("rejects and consumes a provider-blocked phone challenge", async () => {
    preludeCreateStatus = "blocked"
    await expect(operations.begin({
      identifier: { oneofKind: "phoneNumber", phoneNumber: "+12025550104" },
    }, context)).rejects.toThrow("Phone verification provider blocked code delivery")

    const [challenge] = await db.select().from(schema.inlineProtocolAuthChallenges)
    expect(challenge?.delivery).toBe("sms_prelude")
    expect(challenge?.consumedAt).toBeInstanceOf(Date)
  })

  test("keeps an outstanding challenge verifiable under its predecessor pepper", async () => {
    await testUtils.createUser("v3-pepper-overlap@example.com")
    const begun = await operations.begin({
      identifier: { oneofKind: "email", email: "v3-pepper-overlap@example.com" },
    }, context)
    const rotating = new InlineProtocolAuthOperations({
      activeId: "pepper2",
      keys: new Map([
        ["pepper1", pepper],
        ["pepper2", new Uint8Array(32).fill(0x43)],
      ]),
    })
    const result = await rotating.complete({ challengeId: begun.challengeId, code: deliveredCode! }, context)
    expect(result.state.oneofKind).toBe("authorized")
  })

  test("native login revokes and closes the previous same-device session after commit", async () => {
    const user = await testUtils.createUser("v3-replacement@example.com")
    const previous = await testUtils.createSessionForUser(user.id, { deviceId: "replacement-device" })
    await SessionsModel.updatePushNotificationDetails(previous.session.id, { applePushToken: "test-push" })
    const begun = await operations.begin({
      identifier: { oneofKind: "email", email: "v3-replacement@example.com" },
      client: { deviceId: "replacement-device" },
    }, context)
    const close = spyOn(connectionManager, "closeConnectionForSession")
    try {
      const result = await operations.complete({ challengeId: begun.challengeId, code: deliveredCode! }, context)
      expect(result.state.oneofKind).toBe("authorized")
      expect(close).toHaveBeenCalledWith(user.id, previous.session.id, { authenticationInvalidated: true }, undefined)
      const [revoked] = await db.select().from(schema.sessions).where(eq(schema.sessions.id, previous.session.id))
      expect(revoked?.revoked).toBeInstanceOf(Date)
      expect(revoked?.deviceId).toBeNull()
      expect(revoked?.applePushTokenEncrypted).toBeNull()
      expect(revoked?.active).toBe(false)
    } finally {
      close.mockRestore()
    }
  })

  test("failed key binding rolls back session replacement without closing the old carrier", async () => {
    const user = await testUtils.createUser("v3-rollback@example.com")
    const previous = await testUtils.createSessionForUser(user.id, { deviceId: "rollback-device" })
    const begun = await operations.begin({
      identifier: { oneofKind: "email", email: "v3-rollback@example.com" },
      client: { deviceId: "rollback-device" },
    }, context)
    await db.update(schema.inlineProtocolAuthKeys).set({ userId: user.id })
      .where(eq(schema.inlineProtocolAuthKeys.authKeyId, Buffer.from(permanentKeyId)))
    const close = spyOn(connectionManager, "closeConnectionForSession")
    try {
      await expect(operations.complete({ challengeId: begun.challengeId, code: deliveredCode! }, context)).rejects.toThrow()
      expect(close).not.toHaveBeenCalled()
      const rows = await db.select().from(schema.sessions).where(eq(schema.sessions.userId, user.id))
      expect(rows).toHaveLength(1)
      expect(rows[0]?.id).toBe(previous.session.id)
      expect(rows[0]?.revoked).toBeNull()
      expect(rows[0]?.deviceId).toBe("rollback-device")
    } finally {
      close.mockRestore()
    }
  })

  test("normalizes a submitted email before validation and lookup", async () => {
    const existing = await testUtils.createUser("v3-normalized-auth@example.com")
    const begun = await operations.begin({
      identifier: { oneofKind: "email", email: "  V3-NORMALIZED-AUTH@EXAMPLE.COM  " },
    }, context)

    const completed = await operations.complete({
      challengeId: begun.challengeId,
      code: deliveredCode!,
    }, context)

    expect(completed.state.oneofKind).toBe("authorized")
    if (completed.state.oneofKind !== "authorized") throw new Error("Expected authorization")
    expect(completed.state.authorized.user?.id).toBe(BigInt(existing.id))
  })

  test("concurrent native guesses share the five-attempt limit", async () => {
    await testUtils.createUser("v3-budget@example.com")
    const begun = await operations.begin({
      identifier: { oneofKind: "email", email: "v3-budget@example.com" },
    }, context)
    const code = deliveredCode!
    const wrongCode = code === "123456" ? "654321" : "123456"
    const results = await Promise.allSettled(Array.from({ length: 12 }, () =>
      operations.complete({ challengeId: begun.challengeId, code: wrongCode }, context)))
    expect(results.every((result) => result.status === "rejected")).toBe(true)
    const [challenge] = await db.select().from(schema.inlineProtocolAuthChallenges)
      .where(eq(schema.inlineProtocolAuthChallenges.challengeId, Buffer.from(begun.challengeId)))
    expect(challenge?.attempts).toBe(5)
    await expect(operations.complete({ challengeId: begun.challengeId, code }, context)).rejects.toThrow()
  })

  test("parallel code sends cannot overrun the shared challenge quota", async () => {
    const results = await Promise.allSettled(Array.from({ length: 8 }, () => operations.begin({
      identifier: { oneofKind: "email", email: "quota@example.com" },
      client: { deviceId: "quota-device" },
    }, context)))
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(5)
    expect(results.filter((result) => result.status === "rejected")).toHaveLength(3)
    expect(await db.select().from(schema.inlineProtocolAuthChallenges)).toHaveLength(5)
  })

  test.each(["identifier", "network", "device"])("code sends across keys share the %s quota", async (dimension) => {
    const repository = new PermanentAuthorizationKeyRepository(makeAuthorizationKeyCipher({
      activeId: "kek1", keys: new Map([["kek1", new Uint8Array(32).fill(0x24)]]),
    }))
    const contexts = await Promise.all(Array.from({ length: 8 }, async (_, index) => {
      const key = new Uint8Array(256).fill(index + 1)
      const keyId = authKeyId(key)
      await repository.create({ key, keyId, serverSalt: 789n, temporary: false })
      return {
        authorization: { authKeyId: keyId, permanent: true, temporaryBound: false },
        metadata: { ip: dimension === "network" ? "203.0.113.1" : `203.0.113.${index + 1}` },
      }
    }))
    const results = await Promise.allSettled(contexts.map((context, index) => operations.begin({
      identifier: { oneofKind: "email", email: dimension === "identifier" ? "shared@example.com" : `person${index}@example.com` },
      client: { deviceId: dimension === "device" ? "shared-device" : `device-${index}` },
    }, context)))
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(5)
    expect(await db.select().from(schema.inlineProtocolAuthChallenges)).toHaveLength(5)
  })

  test("a valid proof remains usable after the invite-required response", async () => {
    const priorMode = process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"]
    process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"] = "invite_only"
    resetServerConfigCacheForTests()
    try {
      await db.insert(schema.inviteCodes).values({ code: "AUTH1234" })
      const begun = await operations.begin({
        identifier: { oneofKind: "email", email: "new-invite-user@example.com" },
      }, context)
      const code = deliveredCode!
      expect((await operations.complete({ challengeId: begun.challengeId, code }, context)).state.oneofKind).toBe("inviteRequired")
      for (let attempt = 0; attempt < 6; attempt++) {
        await expect(operations.complete({ challengeId: begun.challengeId, code, inviteCode: "bad" }, context))
          .rejects.toMatchObject({ type: "INVITE_CODE_INVALID" })
      }
      const [challenge] = await db.select().from(schema.inlineProtocolAuthChallenges)
        .where(eq(schema.inlineProtocolAuthChallenges.challengeId, Buffer.from(begun.challengeId)))
      expect(challenge?.attempts).toBe(0)
      expect((await operations.complete({ challengeId: begun.challengeId, code, inviteCode: "AUTH1234" }, context)).state.oneofKind).toBe("authorized")
    } finally {
      if (priorMode === undefined) delete process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"]
      else process.env["INLINE_CONFIG_AUTH_SIGNUP_MODE"] = priorMode
      resetServerConfigCacheForTests()
    }
  })

  test("concurrent native proof redemption establishes just one session", async () => {
    const user = await testUtils.createUser("v3-concurrent-proof@example.com")
    const begun = await operations.begin({
      identifier: { oneofKind: "email", email: "v3-concurrent-proof@example.com" },
    }, context)
    const code = deliveredCode!
    const results = await Promise.allSettled(Array.from({ length: 4 }, () =>
      operations.complete({ challengeId: begun.challengeId, code }, context)))
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1)
    expect(await db.select().from(schema.sessions).where(eq(schema.sessions.userId, user.id))).toHaveLength(1)
  })

  test("rejects oversized authentication strings before persistence or delivery", async () => {
    await expect(operations.begin({
      identifier: { oneofKind: "email", email: `${"a".repeat(321)}@example.com` },
      client: { deviceName: "x".repeat(257) },
    }, context)).rejects.toThrow()
    expect(deliveredCode).toBeUndefined()

    await expect(operations.complete({
      challengeId: new Uint8Array(32),
      code: "000000",
      timeZone: "x".repeat(65),
    }, context)).rejects.toThrow()
  })
})
