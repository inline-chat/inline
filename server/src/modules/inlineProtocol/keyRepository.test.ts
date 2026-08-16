import { beforeEach, describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { authKeyId } from "@inline-chat/protocol/secure"
import { db, schema } from "@in/server/db"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import {
  countInlineProtocolChallengesBlockingPepperRetirement,
  PermanentAuthorizationKeyRepository,
} from "@in/server/db/models/inlineProtocol"
import { makeAuthorizationKeyCipher } from "./keyCipher"
import { InlineProtocolAuthorizationKeys } from "./authorizationKeys"
import { TemporaryAuthorizationKeyStore } from "./temporaryKeys"

const oldKey = new Uint8Array(32).fill(0x11)
const newKey = new Uint8Array(32).fill(0x22)

const repository = (activeId: "old" | "new", includeOld = true) =>
  new PermanentAuthorizationKeyRepository(makeAuthorizationKeyCipher({
    activeId,
    keys: new Map([
      ...(includeOld ? [["old", oldKey] as const] : []),
      ...(activeId === "new" ? [["new", newKey] as const] : []),
    ]),
  }))

describe("Inline Protocol durable authorization-key lifecycle", () => {
  setupTestLifecycle()

  let key: Uint8Array
  let keyId: Uint8Array

  beforeEach(() => {
    key = Uint8Array.from({ length: 256 }, (_, index) => index)
    keyId = authKeyId(key)
  })

  test("rewraps predecessor-encrypted keys in restart-safe batches before KEK retirement", async () => {
    expect(await repository("old").create({
      key,
      keyId,
      serverSalt: 123n,
      temporary: false,
    })).toBe("created")

    const rotating = repository("new")
    expect(await rotating.countUsingKeyEncryptionKey("old")).toBe(1)
    expect((await rotating.getActive(keyId))?.key).toEqual(key)
    expect(await rotating.rewrapBatch(1)).toEqual({ rewrapped: 1, remaining: 0 })
    expect(await rotating.rewrapBatch(1)).toEqual({ rewrapped: 0, remaining: 0 })
    expect(await rotating.countUsingKeyEncryptionKey("old")).toBe(0)

    const newOnly = repository("new", false)
    expect((await newOnly.getActive(keyId))?.key).toEqual(key)
    await expect(repository("old").getActive(keyId)).rejects.toThrow()
  })

  test("blocks pepper retirement across live challenges and the rate-limit horizon", async () => {
    await repository("old").create({ key, keyId, serverSalt: 789n, temporary: false })
    const now = new Date("2026-08-16T12:00:00.000Z")
    await db.insert(schema.inlineProtocolAuthChallenges).values([
      {
        challengeId: Buffer.alloc(32, 1),
        authKeyId: Buffer.from(keyId),
        identifierEncrypted: Buffer.alloc(40, 2),
        identifierHash: Buffer.alloc(32, 3),
        codeMac: Buffer.alloc(32, 4),
        pepperKeyId: "old-pepper",
        delivery: "email",
        client: {},
        createdAt: new Date(now.getTime() - 60_000),
        expiresAt: new Date(now.getTime() + 1_000),
      },
      {
        challengeId: Buffer.alloc(32, 5),
        authKeyId: Buffer.from(keyId),
        identifierEncrypted: Buffer.alloc(40, 6),
        identifierHash: Buffer.alloc(32, 7),
        codeMac: Buffer.alloc(32, 8),
        pepperKeyId: "old-pepper",
        delivery: "email",
        client: {},
        createdAt: new Date(now.getTime() - 11 * 60_000),
        expiresAt: new Date(now.getTime() - 1_000),
      },
      {
        challengeId: Buffer.alloc(32, 9),
        authKeyId: Buffer.from(keyId),
        identifierEncrypted: Buffer.alloc(40, 10),
        identifierHash: Buffer.alloc(32, 11),
        codeMac: Buffer.alloc(32, 12),
        pepperKeyId: "old-pepper",
        delivery: "email",
        client: {},
        createdAt: new Date(now.getTime() - 60_000),
        expiresAt: new Date(now.getTime() + 1_000),
        consumedAt: now,
      },
    ])
    expect(await countInlineProtocolChallengesBlockingPepperRetirement("old-pepper", now)).toBe(2)
    expect(await countInlineProtocolChallengesBlockingPepperRetirement("other-pepper", now)).toBe(0)
    expect(await countInlineProtocolChallengesBlockingPepperRetirement(
      "old-pepper",
      new Date(now.getTime() + 11 * 60_000),
    )).toBe(0)
  })

  test("revokes the bound account session with the permanent authorization key", async () => {
    const user = await testUtils.createUser("inline-protocol-revoke@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const keys = repository("old")
    await keys.create({ key, keyId, serverSalt: 456n, temporary: false })
    expect(await keys.authorize(keyId, user.id, account.session.id)).toBeTrue()
    expect(await keys.revoke(keyId)).toBeTrue()
    expect(await keys.getActive(keyId)).toBeUndefined()
    const [session] = await db.select({ revoked: schema.sessions.revoked })
      .from(schema.sessions)
      .where(eq(schema.sessions.id, account.session.id))
      .limit(1)
    expect(session?.revoked).toBeInstanceOf(Date)
  })

  test("invalidates cached temporary bindings when the account session is revoked elsewhere", async () => {
    const user = await testUtils.createUser("inline-protocol-session-revoke@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const permanent = repository("old")
    await permanent.create({ key, keyId, serverSalt: 456n, temporary: false })
    await permanent.authorize(keyId, user.id, account.session.id)

    const temporaryKey = new Uint8Array(256).fill(0x77)
    const temporaryKeyId = authKeyId(temporaryKey)
    const temporary = new TemporaryAuthorizationKeyStore(() => 100)
    const authorizations = new InlineProtocolAuthorizationKeys(permanent, temporary)
    await temporary.create({
      key: temporaryKey,
      keyId: temporaryKeyId,
      serverSalt: 789n,
      temporary: true,
      expiresAt: 200,
    })
    temporary.bind(temporaryKeyId, {
      permanentAuthKeyId: keyId,
      temporarySessionId: 1n,
      nonce: 2n,
      expiresAt: 190,
      userId: user.id,
      accountSessionId: account.session.id,
    })
    expect(await authorizations.load(temporaryKeyId)).toBeDefined()

    await db.update(schema.sessions).set({ revoked: new Date() })
      .where(eq(schema.sessions.id, account.session.id))
    expect(await authorizations.load(temporaryKeyId)).toBeUndefined()
    expect(temporary.size).toBe(0)
  })
})
