import { beforeEach, describe, expect, mock, test } from "bun:test"
import { eq } from "drizzle-orm"
import { authKeyId } from "@inline-chat/protocol/secure"
import { db, schema } from "@in/server/db"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import type { InlineProtocolApplicationContext } from "./application"

let deliveredCode: string | undefined

mock.module("@in/server/utils/email", () => ({
  sendEmail: async (input: { content: { variables: { code: string } } }) => {
    deliveredCode = input.content.variables.code
  },
}))
mock.module("@in/server/libs/prelude", () => ({
  prelude: { sendCustomCode: async (_phone: string, code: string) => { deliveredCode = code } },
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
