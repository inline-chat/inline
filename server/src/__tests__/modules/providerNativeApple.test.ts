import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { randomUUID } from "node:crypto"
import { db, schema } from "@in/server/db"
import { InviteCodesModel } from "@in/server/db/models/inviteCodes"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { createAppCodeChallenge } from "@in/server/modules/auth/provider/appHandoff"
import type { ProviderClaims } from "@in/server/modules/auth/provider/claims"
import type { NativeAppleConfig } from "@in/server/modules/auth/provider/nativeApple"
import {
  completeNativeAppleAuth,
  continueProviderWithInvite,
  hashProviderSecret,
  issueAppTicket,
  redeemProviderTicket,
} from "@in/server/modules/auth/provider/service"
import {
  handleNativeAppleComplete,
  handleNativeAppleContinueInvite,
} from "@in/server/modules/oauth/httpHandlers"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { setupTestLifecycle, testUtils } from "../setup"

const verifier = "native-apple-verifier-0000000000000000000000"
const nativeConfig: NativeAppleConfig = {
  clientId: "chat.inline.auth",
  nativeClientIds: ["chat.inline.InlineIOS", "chat.inline.InlineIOS.debug"],
  teamId: "TEAM123456",
  keyId: "KEY1234567",
  privateKey: new Uint8Array([1]),
}

async function createNativeAttempt(input: {
  state?: string
  nonce?: string
  malformedNonce?: boolean
}) {
  const id = randomUUID()
  const state = input.state ?? `native-state:${id}`
  const nonce = input.nonce ?? `native-nonce:${id}`
  await db.insert(schema.providerAuthAttempts).values({
    id,
    provider: "apple",
    purpose: "app",
    status: "pending_provider",
    stateHash: hashProviderSecret(state),
    nonceHash: hashProviderSecret(nonce),
    nonceEncrypted: input.malformedNonce
      ? Buffer.from("not-an-encrypted-nonce")
      : Encryption2.encrypt(Buffer.from(nonce)),
    appCallbackScheme: "inline-debug",
    appCodeChallenge: createAppCodeChallenge(verifier),
    client: {
      clientType: "ios",
      deviceId: "native-apple-device",
      clientVersion: "1.0.0",
      osVersion: "18.0",
    },
    expiresAt: new Date(Date.now() + 60_000),
  })
  return { id, state, nonce }
}

async function createStoredInviteAttempt(
  claims: ProviderClaims,
  continuation: string,
) {
  const attempt = await createNativeAttempt({})
  await db.update(schema.providerAuthAttempts).set({
    status: "pending_invite",
    continuationHash: hashProviderSecret(continuation),
    subjectHash: hashProviderSecret(`apple\0${claims.subject}`),
    pendingProfileEncrypted: Encryption2.encrypt(Buffer.from(JSON.stringify(claims))),
  }).where(eq(schema.providerAuthAttempts.id, attempt.id))
  return attempt
}

describe("native Apple provider completion", () => {
  setupTestLifecycle()

  test("claims an Apple attempt and creates a session only after one-time ticket redemption", async () => {
    const user = await testUtils.createUser("native-apple-login@example.com")
    const claims: ProviderClaims = {
      provider: "apple",
      subject: "native-apple-existing-subject",
      email: "native-apple-login@example.com",
      authoritativeEmail: true,
      firstName: "Existing",
      lastName: "Apple",
    }
    await db.insert(schema.accountIdentities).values({
      userId: user.id,
      provider: "apple",
      subjectHash: hashProviderSecret(`apple\0${claims.subject}`),
    })
    const attempt = await createNativeAttempt({})

    const outcome = await completeNativeAppleAuth({
      state: attempt.state,
      code: "single-use-apple-code",
      identityToken: "signed-apple-identity-token",
    }, {
      config: nativeConfig,
      verifyAuthorization: async (input) => {
        expect(input.code).toBe("single-use-apple-code")
        expect(input.nonce).toBe(attempt.nonce)
        return claims
      },
    })

    expect(outcome.kind).toBe("login")
    if (outcome.kind !== "login") throw new Error("Expected native Apple login outcome")
    expect(outcome.result.userId).toBe(user.id)
    expect(outcome.result.token).toBeUndefined()
    expect(await db.select().from(schema.sessions).where(eq(schema.sessions.userId, user.id))).toHaveLength(0)

    const ticket = await issueAppTicket(outcome.attempt)
    const redemption = await redeemProviderTicket(ticket, verifier)
    expect(redemption?.userId).toBe(user.id)
    expect(redemption?.token).toBeString()
    expect(redemption?.user.firstName).toBe("Existing")
    expect(redemption?.user.lastName).toBe("Apple")
    expect(await db.select().from(schema.sessions).where(eq(schema.sessions.userId, user.id))).toHaveLength(1)
    expect(await redeemProviderTicket(ticket, verifier)).toBeUndefined()
  })

  test("completes a new Apple signup through the configured policy and ticket redemption", async () => {
    const claims: ProviderClaims = {
      provider: "apple",
      subject: "native-apple-invited-subject",
      email: "native-apple-invited@example.com",
      authoritativeEmail: true,
      firstName: "Native",
      lastName: "Apple",
    }
    const attempt = await createNativeAttempt({})
    const initialOutcome = await completeNativeAppleAuth({
      state: attempt.state,
      code: "single-use-invited-apple-code",
      identityToken: "signed-invited-apple-identity-token",
    }, {
      config: nativeConfig,
      verifyAuthorization: async (input) => {
        expect(input.nonce).toBe(attempt.nonce)
        return claims
      },
    })
    if (initialOutcome.kind === "email") throw new Error("Expected authoritative Apple email")
    let completedAttempt = initialOutcome.attempt
    if (initialOutcome.kind === "invite") {
      const [invite] = await InviteCodesModel.create({ count: 1 })
      if (!invite) throw new Error("Expected an invite code")
      completedAttempt = (await continueProviderWithInvite({
        attemptId: initialOutcome.attempt.id,
        continuation: initialOutcome.continuation,
        inviteCode: invite.code,
      })).attempt
    }
    const ticket = await issueAppTicket(completedAttempt)
    const redemption = await redeemProviderTicket(ticket, verifier)

    expect(redemption?.user.email).toBe(claims.email)
    expect(redemption?.user.firstName).toBe("Native")
    expect(redemption?.user.lastName).toBe("Apple")
    const [identity] = await db.select().from(schema.accountIdentities)
      .where(eq(schema.accountIdentities.subjectHash, hashProviderSecret(`apple\0${claims.subject}`)))
    expect(identity?.userId).toBe(redemption?.userId)
    expect(await redeemProviderTicket(ticket, verifier)).toBeUndefined()
  })

  test("continues a stored Apple invite through identity attachment and ticket redemption", async () => {
    const claims: ProviderClaims = {
      provider: "apple",
      subject: "native-apple-stored-invite-subject",
      email: "native-apple-stored-invite@example.com",
      authoritativeEmail: true,
    }
    const continuation = "native-apple-stored-invite-continuation"
    const attempt = await createStoredInviteAttempt(claims, continuation)
    const [invite] = await InviteCodesModel.create({ count: 1 })
    if (!invite) throw new Error("Expected an invite code")

    const outcome = await continueProviderWithInvite({
      attemptId: attempt.id,
      continuation,
      inviteCode: invite.code,
    })
    const ticket = await issueAppTicket(outcome.attempt)
    const redemption = await redeemProviderTicket(ticket, verifier)

    expect(redemption?.user.email).toBe(claims.email)
    const [identity] = await db.select().from(schema.accountIdentities)
      .where(eq(schema.accountIdentities.subjectHash, hashProviderSecret(`apple\0${claims.subject}`)))
    expect(identity?.userId).toBe(redemption?.userId)
    expect(await redeemProviderTicket(ticket, verifier)).toBeUndefined()
  })

  test("terminalizes a claimed native failure and keeps the JSON response out of caches", async () => {
    const attempt = await createNativeAttempt({ malformedNonce: true })
    const response = await handleNativeAppleComplete({
      state: attempt.state,
      authorizationCode: "unused-apple-code",
      identityToken: "unused-apple-token",
    }, "203.0.113.91", new InMemoryRateLimiter())

    expect(response.status).toBe(400)
    expect(response.headers.get("cache-control")).toBe("no-store")
    const [stored] = await db.select().from(schema.providerAuthAttempts)
      .where(eq(schema.providerAuthAttempts.id, attempt.id))
    expect(stored?.status).toBe("used")
    expect(stored?.usedAt).not.toBeNull()
  })

  test("rejects malformed invite continuations before lookup and keeps the response out of caches", async () => {
    const response = await handleNativeAppleContinueInvite({
      attemptId: "",
      continuation: "x".repeat(257),
      inviteCode: "INVITE01",
    }, "203.0.113.92", new InMemoryRateLimiter())

    expect(response.status).toBe(400)
    expect(response.headers.get("cache-control")).toBe("no-store")
    expect(await response.json()).toMatchObject({ ok: false, error: "INVALID_REQUEST" })
  })
})
