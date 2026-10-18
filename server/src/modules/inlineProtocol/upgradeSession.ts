import {
  AuthUpgradeDeclined_Reason,
  type AuthUpgradeSessionRequest,
  type AuthUpgradeSessionResult,
} from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { inlineProtocolAuthKeys, sessions, users } from "@in/server/db/schema"
import { lockGridMutations } from "@in/server/modules/grid/roomLifecycle"
import { getServerConfig } from "@in/server/modules/serverConfig"
import { encodeUser } from "@in/server/realtime/encoders/encodeUser"
import { InlineError } from "@in/server/types/errors"
import { hashToken } from "@in/server/utils/auth"
import { Log, LogLevel } from "@in/server/utils/log"
import type { InlineProtocolApplicationContext } from "./application"

// Migration successes must survive the production default of WARN. This scope
// contains only fixed outcomes, timing and validated internal cohort IDs.
const log = new Log("InlineProtocol.V3.Upgrade", LogLevel.INFO)
type UpgradeObservation = {
  phase: "validation" | "preflight" | "transaction"
  binding?: "bound" | "recovered"
  authority?: { userId: number; sessionId: number }
}
type UpgradeOutcome = NonNullable<UpgradeObservation["binding"]> | "not_bound" | "disabled" | "ineligible" |
  "source_rejected" | "invalid_request" | "key_rejected" | "internal_error" | "cancelled"

const recordUpgrade = (outcome: UpgradeOutcome, observation: UpgradeObservation, started: number): void => {
  const metadata = {
    outcome, phase: observation.phase, duration_ms: Math.max(0, Math.round(performance.now() - started)),
    // Join the fixed rollout cohort only after a successful commit. Declined
    // or failed requests never export attacker-supplied account identifiers.
    ...(outcome === "bound" || outcome === "recovered" ? observation.authority : {}),
  }
  try {
    if (outcome === "internal_error") log.error("legacy_v3_upgrade", metadata)
    else if (outcome === "source_rejected" || outcome === "invalid_request" || outcome === "key_rejected") {
      log.warn("legacy_v3_upgrade", metadata)
    } else log.info("legacy_v3_upgrade", metadata)
  } catch {
    // Telemetry failure must never turn a committed credential transition into
    // an apparent application failure or interfere with a retry.
  }
}

const declined = (reason: AuthUpgradeDeclined_Reason): AuthUpgradeSessionResult => ({
  state: { oneofKind: "declined", declined: { reason } },
})

/**
 * A credential transition, not a login: preserve the source session and its
 * bearer, push registration, device identity and permissions during rollout.
 * The encrypted envelope proves possession of the destination permanent key.
 */
export async function upgradeInlineProtocolSession(
  request: AuthUpgradeSessionRequest,
  context: InlineProtocolApplicationContext,
): Promise<AuthUpgradeSessionResult> {
  const started = performance.now()
  const observation: UpgradeObservation = { phase: "validation" }
  try {
    const result = await performUpgrade(request, context, observation)
    const outcome: UpgradeOutcome = result.state.oneofKind === "authorized" ? observation.binding! :
      result.state.oneofKind === "notBound" ? "not_bound" :
      result.state.oneofKind === "declined" && result.state.declined.reason === AuthUpgradeDeclined_Reason.DISABLED ? "disabled" :
      result.state.oneofKind === "declined" && result.state.declined.reason === AuthUpgradeDeclined_Reason.INELIGIBLE ? "ineligible" :
      "source_rejected"
    // Only record success once the transaction, including COMMIT, has finished.
    recordUpgrade(outcome, observation, started)
    return result
  } catch (error) {
    const cancelled = context.signal?.aborted === true || (error instanceof DOMException && error.name === "AbortError")
    const outcome: UpgradeOutcome = cancelled ? "cancelled" : error instanceof InlineError && error.code < 500 ?
      error.type === "BAD_REQUEST" ? "invalid_request" : "key_rejected" : "internal_error"
    recordUpgrade(outcome, observation, started)
    if (cancelled || error instanceof InlineError) throw error
    // The generic dispatcher logs uncaught errors. Database exceptions can
    // contain SQL parameters; report the safe phase above and do not forward
    // private error text/causes to that logging boundary.
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}

async function performUpgrade(
  request: AuthUpgradeSessionRequest,
  context: InlineProtocolApplicationContext,
  observation: UpgradeObservation,
): Promise<AuthUpgradeSessionResult> {
  if (!context.authorization.permanent || context.authorization.authKeyId.length !== 8) {
    throw new InlineError(InlineError.ApiError.UNAUTHORIZED)
  }
  const bearer = request.bearerToken
  if (bearer !== undefined && (bearer.length === 0 || bearer.includes("\0") || Buffer.byteLength(bearer) > 256)) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  const sourceUserSegment = bearer?.split(":", 1)[0]
  const parsedSourceUserId = sourceUserSegment !== undefined && /^\d+$/.test(sourceUserSegment)
    ? Number(sourceUserSegment)
    : undefined
  if (bearer !== undefined && (parsedSourceUserId === undefined || !Number.isSafeInteger(parsedSourceUserId))) {
    return declined(AuthUpgradeDeclined_Reason.SOURCE_REJECTED)
  }
  const sourceHash = bearer === undefined ? undefined : hashToken(bearer)
  const keyId = Buffer.from(context.authorization.authKeyId)
  observation.phase = "preflight"
  // Reject unauthenticated probes before acquiring the shared Grid/session
  // mutation lock. An unbound key is cheap to establish and is not account
  // authority; it must not be able to queue arbitrary work behind that lock.
  const [candidate] = await db.select().from(inlineProtocolAuthKeys)
    .where(eq(inlineProtocolAuthKeys.authKeyId, keyId)).limit(1)
  if (!candidate || candidate.revokedAt || (candidate.expiresAt && candidate.expiresAt <= new Date())) {
    throw new InlineError(InlineError.ApiError.UNAUTHORIZED)
  }
  const candidateBound = candidate.userId !== null || candidate.accountSessionId !== null
  if (!candidateBound && sourceHash === undefined) return { state: { oneofKind: "notBound", notBound: {} } }
  const [source] = await db.select({ session: sessions, user: users }).from(sessions)
    .innerJoin(users, eq(users.id, sessions.userId))
    .where(candidateBound ? eq(sessions.id, candidate.accountSessionId ?? -1) : eq(sessions.tokenHash, sourceHash!))
    .limit(1)
  if (!source || source.session.revoked || source.user.deleted === true ||
      (candidateBound && candidate.userId !== source.user.id) ||
      (sourceHash !== undefined && (source.session.tokenHash !== sourceHash || parsedSourceUserId !== source.user.id))) {
    return declined(AuthUpgradeDeclined_Reason.SOURCE_REJECTED)
  }
  if (!candidateBound && (source.user.bot === true ||
      (source.session.clientType !== "ios" && source.session.clientType !== "macos"))) {
    return declined(AuthUpgradeDeclined_Reason.INELIGIBLE)
  }
  const mode = candidateBound ? undefined : await getServerConfig("auth.session_upgrade_mode")
  if (mode?.value === "disabled") return declined(AuthUpgradeDeclined_Reason.DISABLED)

  observation.phase = "transaction"
  return db.transaction(async (tx): Promise<AuthUpgradeSessionResult> => {
    // Match session replacement/revocation and native login lock ordering.
    // A key revoker takes key -> session, so never take session -> key here.
    await lockGridMutations(tx)
    const [user] = await tx.select().from(users)
      .where(eq(users.id, source.user.id)).for("share").limit(1)
    const [key] = await tx.select().from(inlineProtocolAuthKeys)
      .where(eq(inlineProtocolAuthKeys.authKeyId, keyId)).for("update").limit(1)
    const now = new Date()
    if (!key || key.revokedAt || (key.expiresAt && key.expiresAt <= now)) {
      throw new InlineError(InlineError.ApiError.UNAUTHORIZED)
    }

    const bound = key.userId !== null || key.accountSessionId !== null
    if (!bound && sourceHash === undefined) return { state: { oneofKind: "notBound", notBound: {} } }
    if (!user || user.deleted === true || (bound && key.userId !== user.id)) {
      return declined(AuthUpgradeDeclined_Reason.SOURCE_REJECTED)
    }

    const [session] = await tx.select().from(sessions).where(and(
      eq(sessions.userId, user.id),
      bound
        ? eq(sessions.id, key.accountSessionId ?? -1)
        : eq(sessions.tokenHash, sourceHash!),
    )).for("update").limit(1)
    if (!session || session.revoked ||
        (sourceHash !== undefined && (session.tokenHash !== sourceHash || parsedSourceUserId !== user.id))) {
      return declined(AuthUpgradeDeclined_Reason.SOURCE_REJECTED)
    }

    if (!bound) {
      if (mode?.value !== "native") return declined(AuthUpgradeDeclined_Reason.DISABLED)
      if (user.bot === true || (session.clientType !== "ios" && session.clientType !== "macos")) {
        return declined(AuthUpgradeDeclined_Reason.INELIGIBLE)
      }
      await tx.update(inlineProtocolAuthKeys).set({
        userId: user.id,
        accountSessionId: session.id,
        authorizedAt: now,
        lastUsedAt: now,
      }).where(eq(inlineProtocolAuthKeys.authKeyId, keyId))
    }

    // The locked key is the durable receipt. Recovery remains available when
    // new upgrades are disabled and never relies on a transport replay cache.
    observation.binding = bound ? "recovered" : "bound"
    observation.authority = { userId: user.id, sessionId: session.id }
    return { state: { oneofKind: "authorized", authorized: {
      user: encodeUser({ user, viewerUserId: user.id }),
      accountSessionId: BigInt(session.id),
    } } }
  })
}
