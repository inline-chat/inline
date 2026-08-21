import { and, eq, isNull } from "drizzle-orm"
import { createHash, randomBytes } from "node:crypto"
import type { Transaction } from "@in/server/db/types"
import { inlineProtocolAuthKeys, sessions } from "@in/server/db/schema"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { normalizeAuthClientType } from "@in/server/modules/auth/clientType"
import { validateIanaTimezone, validateUpToFourSegementSemver } from "@in/server/utils/validate"
import { InlineError } from "@in/server/types/errors"

export type InlineProtocolLoginClient = Record<string, string>

const validVersion = (value: string | undefined): string | undefined =>
  validateUpToFourSegementSemver(value ?? "") ? value : undefined

export async function authorizeInlineProtocolKey(input: {
  tx: Transaction
  authKeyId: Uint8Array
  userId: number
  client: InlineProtocolLoginClient
  ip?: string
  timeZone?: string
  now: Date
}): Promise<{ accountSessionId: number }> {
  const clientType = normalizeAuthClientType(input.client["clientType"], "inlineProtocol.authorizeKey") ?? "api"
  const timeZone = validateIanaTimezone(input.timeZone ?? "") ? input.timeZone : undefined
  const personalData = encrypt(JSON.stringify({
    timezone: timeZone,
    deviceName: input.client["deviceName"],
    ip: input.ip,
  }))
  const deviceId = input.client["deviceId"]
  if (deviceId) {
    await input.tx.update(sessions).set({ revoked: input.now, deviceId: null }).where(and(
      eq(sessions.userId, input.userId),
      eq(sessions.deviceId, deviceId),
    ))
  }
  const accountSession = (await input.tx.insert(sessions).values({
    userId: input.userId,
    tokenHash: createHash("sha256").update(randomBytes(32)).digest("hex"),
    revoked: null,
    active: false,
    personalDataEncrypted: personalData.encrypted,
    personalDataIv: personalData.iv,
    personalDataTag: personalData.authTag,
    deviceId: deviceId ?? null,
    clientType,
    clientVersion: validVersion(input.client["clientVersion"]) ?? null,
    osVersion: validVersion(input.client["osVersion"]) ?? null,
    date: input.now,
    lastActive: input.now,
  }).returning({ id: sessions.id }))[0]
  if (!accountSession) throw new InlineError(InlineError.ApiError.INTERNAL)

  const authorized = await input.tx.update(inlineProtocolAuthKeys).set({
    userId: input.userId,
    accountSessionId: accountSession.id,
    authorizedAt: input.now,
    lastUsedAt: input.now,
  }).where(and(
    eq(inlineProtocolAuthKeys.authKeyId, Buffer.from(input.authKeyId)),
    isNull(inlineProtocolAuthKeys.revokedAt),
    isNull(inlineProtocolAuthKeys.userId),
  )).returning({ authKeyId: inlineProtocolAuthKeys.authKeyId })
  if (authorized.length !== 1) throw new InlineError(InlineError.ApiError.UNAUTHORIZED)
  return { accountSessionId: accountSession.id }
}
