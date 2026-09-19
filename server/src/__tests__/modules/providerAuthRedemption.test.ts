import { describe, expect, test } from "bun:test"
import { and, eq, sql } from "drizzle-orm"
import { randomUUID } from "node:crypto"
import { db, schema } from "@in/server/db"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import {
  hashProviderSecret,
  redeemProviderTicket,
} from "@in/server/modules/auth/provider/service"
import { createAppCodeChallenge } from "@in/server/modules/auth/provider/appHandoff"
import { handleProviderCallback } from "@in/server/modules/oauth/httpHandlers"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { setupTestLifecycle, testUtils } from "../setup"

const verifier = "provider-redemption-verifier-000000000000000000"

const invalidRedemptions: {
  name: string
  patch?: Partial<schema.DbNewProviderAuthAttempt>
  presentedTicket?: string
  presentedVerifier?: string
}[] = [
  { name: "wrong proof key", presentedVerifier: "x".repeat(43) },
  { name: "malformed proof key", presentedVerifier: "short" },
  { name: "unknown ticket", presentedTicket: "unknown-ticket" },
  { name: "expired ticket", patch: { expiresAt: new Date(0) } },
  { name: "incomplete sign-in", patch: { status: "pending_invite" } },
  { name: "already consumed ticket", patch: { usedAt: new Date(0) } },
  { name: "wrong authentication flow", patch: { purpose: "mcp_oauth" } },
  { name: "missing account", patch: { inlineUserId: null } },
]

async function createCompletedAttempt(input: {
  userId: number
  ticket: string
  deviceId?: string
  legacyToken?: string
}) {
  const id = randomUUID()
  await db.insert(schema.providerAuthAttempts).values({
    id,
    provider: "google",
    purpose: "app",
    status: "complete",
    stateHash: hashProviderSecret(`state:${id}`),
    nonceHash: hashProviderSecret(`nonce:${id}`),
    nonceEncrypted: Buffer.from("unused-in-redemption"),
    appCallbackScheme: "inline-debug",
    appCodeChallenge: createAppCodeChallenge(verifier),
    client: { clientType: "ios", deviceId: input.deviceId },
    inlineUserId: input.userId,
    inlineTokenEncrypted: input.legacyToken
      ? Encryption2.encrypt(Buffer.from(input.legacyToken))
      : null,
    ticketHash: hashProviderSecret(input.ticket),
    expiresAt: new Date(Date.now() + 60_000),
  })
  return id
}

describe("provider app ticket redemption", () => {
  setupTestLifecycle()

  test.each(invalidRedemptions)("$name cannot consume a ticket or change existing sessions", async (scenario) => {
    const user = await testUtils.createUser("provider-invalid@test.com")
    await testUtils.createSessionForUser(user.id, { clientType: "ios", deviceId: "same-device" })
    const ticket = "valid-ticket"
    const attemptId = await createCompletedAttempt({ userId: user.id, ticket, deviceId: "same-device" })
    if (scenario.patch) await db.update(schema.providerAuthAttempts).set(scenario.patch)
      .where(eq(schema.providerAuthAttempts.id, attemptId))
    const snapshot = async () => ({
      attempts: await db.select().from(schema.providerAuthAttempts).where(eq(schema.providerAuthAttempts.id, attemptId)),
      sessions: await db.select().from(schema.sessions).where(eq(schema.sessions.userId, user.id)),
    })
    const before = await snapshot()
    expect(await redeemProviderTicket(scenario.presentedTicket ?? ticket, scenario.presentedVerifier ?? verifier)).toBeUndefined()
    expect(await snapshot()).toEqual(before)
  })

  test("a late redemption failure rolls back ticket consumption and device-session replacement together", async () => {
    const user = await testUtils.createUser("provider-rollback@test.com")
    const previous = await testUtils.createSessionForUser(user.id, { clientType: "ios", deviceId: "same-device" })
    const ticket = "rollback-ticket"
    const attemptId = await createCompletedAttempt({ userId: user.id, ticket, deviceId: "same-device" })
    const snapshot = async () => ({
      attempts: await db.select().from(schema.providerAuthAttempts).where(eq(schema.providerAuthAttempts.id, attemptId)),
      sessions: await db.select().from(schema.sessions).where(eq(schema.sessions.userId, user.id)),
    })
    const before = await snapshot()
    await db.execute(sql`CREATE FUNCTION test_reject_ticket_consumption() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'test injected ticket failure'; END $$;
      CREATE TRIGGER test_reject_ticket_consumption BEFORE UPDATE ON provider_auth_attempts
      FOR EACH ROW EXECUTE FUNCTION test_reject_ticket_consumption();`)
    try {
      await expect(redeemProviderTicket(ticket, verifier)).rejects.toThrow("test injected ticket failure")
      expect(await snapshot()).toEqual(before)
    } finally {
      await db.execute(sql`DROP TRIGGER test_reject_ticket_consumption ON provider_auth_attempts;
        DROP FUNCTION test_reject_ticket_consumption();`)
    }
    expect((await redeemProviderTicket(ticket, verifier))?.userId).toBe(user.id)
    const after = await snapshot()
    expect(after.attempts[0]).toMatchObject({ status: "used", usedAt: expect.any(Date) })
    expect(after.sessions).toHaveLength(2)
    expect(after.sessions.find((row) => row.id === previous.session.id)?.revoked).toBeInstanceOf(Date)
    expect(after.sessions.filter((row) => row.revoked === null)).toHaveLength(1)
  })

  test("creates the app session only when the ticket is redeemed and rejects replay", async () => {
    const user = await testUtils.createUser("provider-redeem@test.com")
    const ticket = "redeem-ticket"
    const attemptId = await createCompletedAttempt({ userId: user.id, ticket })

    expect(await db.select().from(schema.sessions).where(eq(schema.sessions.userId, user.id))).toHaveLength(0)
    const result = await redeemProviderTicket(ticket, verifier)
    expect(result?.userId).toBe(user.id)
    expect(result?.token).toBeString()
    expect(await db.select().from(schema.sessions).where(eq(schema.sessions.userId, user.id))).toHaveLength(1)
    expect(await redeemProviderTicket(ticket, verifier)).toBeUndefined()

    const [attempt] = await db.select().from(schema.providerAuthAttempts)
      .where(eq(schema.providerAuthAttempts.id, attemptId))
    expect(attempt?.status).toBe("used")
    expect(attempt?.usedAt).not.toBeNull()
  })

  test("allows only one concurrent redemption", async () => {
    const user = await testUtils.createUser("provider-concurrent@test.com")
    const ticket = "concurrent-ticket"
    await createCompletedAttempt({ userId: user.id, ticket })

    const results = await Promise.all([
      redeemProviderTicket(ticket, verifier),
      redeemProviderTicket(ticket, verifier),
    ])
    expect(results.filter(Boolean)).toHaveLength(1)
    expect(await db.select().from(schema.sessions).where(eq(schema.sessions.userId, user.id))).toHaveLength(1)
  })

  test("replaces a same-device session in the redemption transaction", async () => {
    const user = await testUtils.createUser("provider-device@test.com")
    const previous = await testUtils.createSessionForUser(user.id, {
      clientType: "ios",
      deviceId: "provider-device",
    })
    const ticket = "replacement-ticket"
    await createCompletedAttempt({ userId: user.id, ticket, deviceId: "provider-device" })

    expect(await redeemProviderTicket(ticket, verifier)).toBeDefined()
    const rows = await db.select().from(schema.sessions).where(eq(schema.sessions.userId, user.id))
    expect(rows).toHaveLength(2)
    expect(rows.find(({ id }) => id === previous.session.id)?.revoked).not.toBeNull()
    expect(rows.find(({ id }) => id === previous.session.id)?.deviceId).toBeNull()
    expect(rows.filter(({ revoked }) => revoked === null)).toHaveLength(1)
    expect(rows.find(({ revoked }) => revoked === null)?.deviceId).toBe("provider-device")
  })

  test("does not consume the ticket or create a session for a deactivated user", async () => {
    const user = await testUtils.createUser("provider-deactivated@test.com")
    const ticket = "deactivated-ticket"
    const attemptId = await createCompletedAttempt({ userId: user.id, ticket })
    await db.update(schema.users).set({ deleted: true }).where(eq(schema.users.id, user.id))

    await expect(redeemProviderTicket(ticket, verifier)).rejects.toBeDefined()
    const [attempt] = await db.select().from(schema.providerAuthAttempts)
      .where(and(
        eq(schema.providerAuthAttempts.id, attemptId),
        eq(schema.providerAuthAttempts.status, "complete"),
      ))
    expect(attempt?.usedAt).toBeNull()
    expect(await db.select().from(schema.sessions).where(eq(schema.sessions.userId, user.id))).toHaveLength(0)
  })

  test("redeems pre-rollout encrypted-token attempts without creating a second session", async () => {
    const user = await testUtils.createUser("provider-legacy@test.com")
    const ticket = "legacy-ticket"
    const { token: legacyToken } = await testUtils.createSessionForUser(user.id, { clientType: "ios" })
    await createCompletedAttempt({ userId: user.id, ticket, legacyToken })

    const result = await redeemProviderTicket(ticket, verifier)
    expect(result?.token).toBe(legacyToken)
    expect(await db.select().from(schema.sessions).where(eq(schema.sessions.userId, user.id))).toHaveLength(1)
  })

  test("closes a claimed callback after a post-claim failure and returns the app challenge", async () => {
    const id = randomUUID()
    const state = `terminal-state:${id}`
    const challenge = createAppCodeChallenge(verifier)
    await db.insert(schema.providerAuthAttempts).values({
      id,
      provider: "google",
      purpose: "app",
      status: "pending_provider",
      stateHash: hashProviderSecret(state),
      nonceHash: hashProviderSecret(`nonce:${id}`),
      nonceEncrypted: Buffer.from("not-an-encrypted-nonce"),
      appCallbackScheme: "inline-debug",
      appCodeChallenge: challenge,
      client: { clientType: "ios" },
      expiresAt: new Date(Date.now() + 60_000),
    })

    const callback = new URL("http://inline.test/v1/auth/provider/callback/google")
    callback.searchParams.set("state", state)
    callback.searchParams.set("code", "unused-provider-code")
    const response = await handleProviderCallback(
      "google",
      new Request(callback),
      undefined,
      "203.0.113.90",
      new InMemoryRateLimiter(),
    )

    expect(response.status).toBe(400)
    const body = await response.text()
    expect(body).toContain("inline-debug://auth/provider")
    expect(body).toContain("error=failed")
    expect(body).toContain(`code_challenge=${challenge}`)
    const [attempt] = await db.select().from(schema.providerAuthAttempts)
      .where(eq(schema.providerAuthAttempts.id, id))
    expect(attempt?.status).toBe("used")
    expect(attempt?.usedAt).not.toBeNull()
  })
})
