import {
  AuthBeginResult_Delivery,
  type AuthBeginRequest,
  type AuthBeginResult,
  type AuthCompleteRequest,
  type AuthCompleteResult,
} from "@inline-chat/protocol/core"
import { and, count, eq, gte, inArray, isNull, or, sql } from "drizzle-orm"
import { createHash, randomBytes, timingSafeEqual } from "node:crypto"
import { db } from "@in/server/db"
import {
  inlineProtocolAuthChallenges,
  inlineProtocolAuthKeys,
  sessions,
} from "@in/server/db/schema"
import { encodeUser } from "@in/server/realtime/encoders/encodeUser"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { normalizeAuthClientType } from "@in/server/modules/auth/clientType"
import { getOrCreateUserByEmailForSignup } from "@in/server/modules/auth/signupInvites"
import { getOrCreateUserByPhoneForSignup } from "@in/server/modules/auth/signupInvites"
import { normalizeEmail } from "@in/server/utils/normalize"
import { sendEmail } from "@in/server/utils/email"
import { prelude } from "@in/server/libs/prelude"
import parsePhoneNumber from "libphonenumber-js"
import { isValidEmail, validateIanaTimezone, validateUpToFourSegementSemver } from "@in/server/utils/validate"
import { InlineError } from "@in/server/types/errors"
import type { InlineProtocolApplicationContext } from "./application"
import {
  inlineProtocolAuthCodeMac,
  inlineProtocolKeyedHash,
  randomInlineProtocolAuthCode,
} from "./authCode"
import type { InlineProtocolSecretKeyRing } from "./keyCipher"
import { InlineProtocolChallengeCipher } from "./challengeCipher"
import { DEMO_CODE, DEMO_CODE2, DEMO_EMAIL, DEMO_EMAIL2 } from "@in/server/env"

const CHALLENGE_TTL_MS = 10 * 60 * 1_000
const RATE_WINDOW_MS = 10 * 60 * 1_000
const MAX_CHALLENGES_PER_WINDOW = 5
const MAX_ATTEMPTS = 5
const RETRY_AFTER_SECONDS = 60
const MAX_EMAIL_BYTES = 320
const MAX_PHONE_BYTES = 64
const MAX_DEVICE_ID_BYTES = 128
const MAX_CLIENT_TYPE_BYTES = 32
const MAX_VERSION_BYTES = 64
const MAX_DEVICE_NAME_BYTES = 256
const MAX_INVITE_CODE_BYTES = 256
const MAX_TIME_ZONE_BYTES = 64

const configuredDemoCode = (email: string): string | undefined => {
  if (email === DEMO_EMAIL && DEMO_CODE && /^\d{6}$/.test(DEMO_CODE)) return DEMO_CODE
  if (email === DEMO_EMAIL2 && DEMO_CODE2 && /^\d{6}$/.test(DEMO_CODE2)) return DEMO_CODE2
  return undefined
}

const boundedString = (value: string | undefined, maximumBytes: number): string | undefined => {
  if (value === undefined) return undefined
  if (value.includes("\0") || Buffer.byteLength(value, "utf8") > maximumBytes) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  return value
}

const clientRecord = (request: AuthBeginRequest): Record<string, string> => {
  const client = request.client
  if (!client) return {}
  return Object.fromEntries(Object.entries({
    deviceId: boundedString(client.deviceId, MAX_DEVICE_ID_BYTES),
    clientType: boundedString(client.clientType, MAX_CLIENT_TYPE_BYTES),
    clientVersion: boundedString(client.clientVersion, MAX_VERSION_BYTES),
    osVersion: boundedString(client.osVersion, MAX_VERSION_BYTES),
    deviceName: boundedString(client.deviceName, MAX_DEVICE_NAME_BYTES),
  }).filter((entry): entry is [string, string] => typeof entry[1] === "string" && entry[1].length > 0))
}

const requirePermanentUnauthorised = (context: InlineProtocolApplicationContext): Uint8Array => {
  if (!context.authorization.permanent || context.authorization.userId !== undefined ||
      context.authorization.authKeyId.length !== 8) {
    throw new InlineError(InlineError.ApiError.UNAUTHORIZED)
  }
  return context.authorization.authKeyId
}

const validateClientVersion = (value: string | undefined): string | undefined =>
  validateUpToFourSegementSemver(value ?? "") ? value : undefined

type NormalizedIdentifier = {
  value: string
  delivery: "email" | "sms"
}

const normalizeIdentifier = (request: AuthBeginRequest): NormalizedIdentifier => {
  if (request.identifier.oneofKind === "email" &&
      boundedString(request.identifier.email, MAX_EMAIL_BYTES) !== undefined &&
      isValidEmail(request.identifier.email)) {
    return { value: normalizeEmail(request.identifier.email), delivery: "email" }
  }
  if (request.identifier.oneofKind === "phoneNumber") {
    boundedString(request.identifier.phoneNumber, MAX_PHONE_BYTES)
    const parsed = parsePhoneNumber(request.identifier.phoneNumber)
    if (parsed?.isValid()) return { value: parsed.number, delivery: "sms" }
    throw new InlineError(InlineError.ApiError.PHONE_INVALID)
  }
  throw new InlineError(InlineError.ApiError.EMAIL_INVALID)
}

export class InlineProtocolAuthOperations {
  private readonly challengeCipher: InlineProtocolChallengeCipher

  constructor(private readonly pepperRing: InlineProtocolSecretKeyRing) {
    this.challengeCipher = new InlineProtocolChallengeCipher(pepperRing)
  }

  private activePepper(): Uint8Array {
    const pepper = this.pepperRing.keys.get(this.pepperRing.activeId)
    if (!pepper) throw new RangeError("Inline Protocol active auth pepper is absent")
    return pepper
  }

  async begin(request: AuthBeginRequest, context: InlineProtocolApplicationContext): Promise<AuthBeginResult> {
    const authKeyId = requirePermanentUnauthorised(context)
    const identifier = normalizeIdentifier(request)
    const client = clientRecord(request)
    const challengeId = randomBytes(32)
    const code = identifier.delivery === "email"
      ? configuredDemoCode(identifier.value) ?? randomInlineProtocolAuthCode()
      : randomInlineProtocolAuthCode()
    const pepper = this.activePepper()
    const identifierHash = inlineProtocolKeyedHash(pepper, "identifier", identifier.value)
    const identifierHashes = [...this.pepperRing.keys.values()]
      .map((key) => inlineProtocolKeyedHash(key, "identifier", identifier.value))
    const networkHash = context.metadata?.ip
      ? inlineProtocolKeyedHash(pepper, "network", context.metadata.ip)
      : undefined
    const networkHashes = context.metadata?.ip
      ? [...this.pepperRing.keys.values()].map((key) => inlineProtocolKeyedHash(key, "network", context.metadata!.ip!))
      : []
    const deviceId = client["deviceId"]?.trim()
    const deviceHash = deviceId ? inlineProtocolKeyedHash(pepper, "device", deviceId) : undefined
    const deviceHashes = deviceId
      ? [...this.pepperRing.keys.values()].map((key) => inlineProtocolKeyedHash(key, "device", deviceId))
      : []
    const now = new Date()
    const rateStart = new Date(now.getTime() - RATE_WINDOW_MS)
    const [{ value: recent = 0 } = { value: 0 }] = await db.select({ value: count() })
      .from(inlineProtocolAuthChallenges)
      .where(and(
        gte(inlineProtocolAuthChallenges.createdAt, rateStart),
        or(
          eq(inlineProtocolAuthChallenges.authKeyId, Buffer.from(authKeyId)),
          inArray(inlineProtocolAuthChallenges.identifierHash, identifierHashes),
          ...(networkHashes.length > 0 ? [inArray(inlineProtocolAuthChallenges.networkHash, networkHashes)] : []),
          ...(deviceHashes.length > 0 ? [inArray(inlineProtocolAuthChallenges.deviceHash, deviceHashes)] : []),
        ),
      ))
    if (recent >= MAX_CHALLENGES_PER_WINDOW) throw new InlineError(InlineError.ApiError.FLOOD)

    const expiresAt = new Date(now.getTime() + CHALLENGE_TTL_MS)
    const encryptedIdentifier = this.challengeCipher.encrypt(challengeId, identifier.value)
    await db.transaction(async (tx) => {
      await tx.update(inlineProtocolAuthChallenges).set({ consumedAt: now }).where(and(
        eq(inlineProtocolAuthChallenges.authKeyId, Buffer.from(authKeyId)),
        eq(inlineProtocolAuthChallenges.identifierHash, identifierHash),
        isNull(inlineProtocolAuthChallenges.consumedAt),
      ))
      await tx.insert(inlineProtocolAuthChallenges).values({
        challengeId,
        authKeyId: Buffer.from(authKeyId),
        identifierEncrypted: encryptedIdentifier.encrypted,
        identifierHash,
        codeMac: inlineProtocolAuthCodeMac(pepper, challengeId, identifier.value, code),
        pepperKeyId: encryptedIdentifier.keyId,
        delivery: identifier.delivery,
        client,
        networkHash,
        deviceHash,
        expiresAt,
      })
    })
    try {
      if (identifier.delivery === "email") {
        await sendEmail({
          to: identifier.value,
          content: {
            template: "code",
            variables: { code, firstName: undefined, isExistingUser: true },
          },
        })
      } else {
        await prelude.sendCustomCode(identifier.value, code)
      }
    } catch (error) {
      await db.update(inlineProtocolAuthChallenges).set({ consumedAt: new Date() })
        .where(eq(inlineProtocolAuthChallenges.challengeId, challengeId))
      throw error
    }
    return {
      challengeId: Uint8Array.from(challengeId),
      delivery: identifier.delivery === "email"
        ? AuthBeginResult_Delivery.EMAIL
        : AuthBeginResult_Delivery.SMS,
      expiresAt: BigInt(Math.floor(expiresAt.getTime() / 1000)),
      retryAfterSeconds: RETRY_AFTER_SECONDS,
    }
  }

  async complete(request: AuthCompleteRequest, context: InlineProtocolApplicationContext): Promise<AuthCompleteResult> {
    const authKeyId = requirePermanentUnauthorised(context)
    boundedString(request.inviteCode, MAX_INVITE_CODE_BYTES)
    boundedString(request.timeZone, MAX_TIME_ZONE_BYTES)
    if (request.challengeId.length !== 32 || !/^\d{6}$/.test(request.code)) {
      throw new InlineError(InlineError.ApiError.EMAIL_CODE_INVALID)
    }
    const now = new Date()
    const challenge = (await db.select().from(inlineProtocolAuthChallenges).where(and(
      eq(inlineProtocolAuthChallenges.challengeId, Buffer.from(request.challengeId)),
      eq(inlineProtocolAuthChallenges.authKeyId, Buffer.from(authKeyId)),
      isNull(inlineProtocolAuthChallenges.consumedAt),
      gte(inlineProtocolAuthChallenges.expiresAt, now),
    )).limit(1))[0]
    if (!challenge || challenge.attempts >= MAX_ATTEMPTS) {
      throw new InlineError(InlineError.ApiError.EMAIL_CODE_INVALID)
    }
    const identifier = this.challengeCipher.decrypt(
      request.challengeId,
      challenge.pepperKeyId,
      challenge.identifierEncrypted,
    )
    const pepper = this.pepperRing.keys.get(challenge.pepperKeyId)
    if (!pepper) throw new InlineError(InlineError.ApiError.EMAIL_CODE_INVALID)
    const expected = inlineProtocolAuthCodeMac(pepper, request.challengeId, identifier, request.code)
    if (challenge.codeMac.length !== expected.length || !timingSafeEqual(challenge.codeMac, expected)) {
      await db.update(inlineProtocolAuthChallenges).set({ attempts: sql`${inlineProtocolAuthChallenges.attempts} + 1` })
        .where(and(
          eq(inlineProtocolAuthChallenges.challengeId, Buffer.from(request.challengeId)),
          isNull(inlineProtocolAuthChallenges.consumedAt),
        ))
      throw new InlineError(InlineError.ApiError.EMAIL_CODE_INVALID)
    }

    const client = challenge.client
    const clientType = normalizeAuthClientType(client["clientType"], "inlineProtocol.authComplete") ?? "api"
    const timeZone = validateIanaTimezone(request.timeZone ?? "") ? request.timeZone : undefined
    const personalData = encrypt(JSON.stringify({
      timezone: timeZone,
      deviceName: client["deviceName"],
      ip: context.metadata?.ip,
    }))
    const tokenHash = createHash("sha256").update(randomBytes(32)).digest("hex")
    let completed
    try {
      completed = await db.transaction(async (tx) => {
        const consumed = await tx.update(inlineProtocolAuthChallenges).set({ consumedAt: now }).where(and(
          eq(inlineProtocolAuthChallenges.challengeId, Buffer.from(request.challengeId)),
          isNull(inlineProtocolAuthChallenges.consumedAt),
        )).returning({ challengeId: inlineProtocolAuthChallenges.challengeId })
        if (consumed.length !== 1) throw new InlineError(InlineError.ApiError.EMAIL_CODE_INVALID)

        const user = challenge.delivery === "sms"
          ? (await getOrCreateUserByPhoneForSignup(identifier, request.inviteCode, tx)).user
          : (await getOrCreateUserByEmailForSignup(identifier, request.inviteCode, tx)).user
        const deviceId = client["deviceId"]
        if (deviceId) {
          await tx.update(sessions).set({ revoked: now, deviceId: null }).where(and(
            eq(sessions.userId, user.id),
            eq(sessions.deviceId, deviceId),
          ))
        }
        const accountSession = (await tx.insert(sessions).values({
          userId: user.id,
          tokenHash,
          revoked: null,
          active: false,
          personalDataEncrypted: personalData.encrypted,
          personalDataIv: personalData.iv,
          personalDataTag: personalData.authTag,
          deviceId: deviceId ?? null,
          clientType,
          clientVersion: validateClientVersion(client["clientVersion"]) ?? null,
          osVersion: validateClientVersion(client["osVersion"]) ?? null,
          date: now,
          lastActive: now,
        }).returning({ id: sessions.id }))[0]
        if (!accountSession) throw new InlineError(InlineError.ApiError.INTERNAL)
        const authorized = await tx.update(inlineProtocolAuthKeys).set({
          userId: user.id,
          accountSessionId: accountSession.id,
          authorizedAt: now,
          lastUsedAt: now,
        }).where(and(
          eq(inlineProtocolAuthKeys.authKeyId, Buffer.from(authKeyId)),
          isNull(inlineProtocolAuthKeys.revokedAt),
          isNull(inlineProtocolAuthKeys.userId),
        )).returning({ authKeyId: inlineProtocolAuthKeys.authKeyId })
        if (authorized.length !== 1) throw new InlineError(InlineError.ApiError.UNAUTHORIZED)
        return { user, accountSession }
      })
    } catch (error) {
      if (error instanceof InlineError && error.type === "INVITE_CODE_REQUIRED") {
        return { state: { oneofKind: "inviteRequired", inviteRequired: {} } }
      }
      throw error
    }
    return {
      state: {
        oneofKind: "authorized",
        authorized: {
          user: encodeUser({ user: completed.user, viewerUserId: completed.user.id }),
          accountSessionId: BigInt(completed.accountSession.id),
        },
      },
    }
  }
}
