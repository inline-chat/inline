import { and, eq, isNull } from "drizzle-orm"
import { createHash, randomBytes } from "node:crypto"
import type { Transaction } from "@in/server/db/types"
import { inlineProtocolAuthKeys } from "@in/server/db/schema"
import { SessionsModel, type SessionReplacement } from "@in/server/db/models/sessions"
import { finishSessionRevocation } from "@in/server/modules/sessions/revokeSession"
import { normalizeAuthClientType } from "@in/server/modules/auth/clientType"
import { validateIanaTimezone, validateUpToFourSegementSemver } from "@in/server/utils/validate"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"

const log = new Log("InlineProtocolAuthorization")

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
}): Promise<{ accountSessionId: number; replacement?: SessionReplacement }> {
  const clientType = normalizeAuthClientType(input.client["clientType"], "inlineProtocol.authorizeKey") ?? "api"
  const timeZone = validateIanaTimezone(input.timeZone ?? "") ? input.timeZone : undefined
  const { session: accountSession, replacement } = await SessionsModel.createReplacingInTransaction(input.tx, {
    userId: input.userId,
    tokenHash: createHash("sha256").update(randomBytes(32)).digest("hex"),
    personalData: {
      timezone: timeZone,
      deviceName: input.client["deviceName"],
      ip: input.ip,
    },
    deviceId: input.client["deviceId"],
    clientType,
    clientVersion: validVersion(input.client["clientVersion"]),
    osVersion: validVersion(input.client["osVersion"]),
  }, input.now)

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
  return { accountSessionId: accountSession.id, replacement }
}

// Run only after the authority transaction commits. A failed replacement must
// leave the previous live session usable; a committed one must close its carrier.
export async function finishInlineProtocolSessionReplacement(replacement?: SessionReplacement): Promise<void> {
  if (!replacement) return
  await finishSessionRevocation(replacement.outcome, replacement.input).catch((cause) => {
    log.warn("Session replacement follow-up failed after commit", {
      errorName: cause instanceof Error ? cause.name : "UnknownError",
    })
  })
}
