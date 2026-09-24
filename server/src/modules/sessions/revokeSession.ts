import { db } from "@in/server/db"
import { sessions, type DbSession } from "@in/server/db/schema"
import { connectionManager } from "@in/server/ws/connections"
import { and, eq, isNull } from "drizzle-orm"
import { finishGridSessionAccess } from "@in/server/modules/grid/accessLifecycle"
import {
  lockGridMutations,
  removeGridSessionPresenceInTransaction,
  type GridPresenceRemovalState,
} from "@in/server/modules/grid/roomLifecycle"
import type { Transaction } from "@in/server/db/types"
import { internalMessaging } from "@in/server/modules/internalMessaging/service"
import { outboundPublications } from "@in/server/modules/internalMessaging/outbound"
import { UserId, SessionId } from "@in/server/core/schema/identifiers"
import { sessionAuthority } from "@in/server/modules/auth/sessionAuthority"

type RevokeActor = "admin" | "user" | "system"

export type RevokeSessionInput = {
  actor: RevokeActor
  actorUserId?: number
  targetUserId: number
  sessionId: number
  preserveConnectionId?: string
}

export type RevokeSessionResult = {
  session: DbSession | null
  revoked: boolean
  alreadyRevoked: boolean
}

export type RevokeSessionTransactionOutcome = {
  result: RevokeSessionResult
  gridState: GridPresenceRemovalState | undefined
}

export async function revokeSession(input: RevokeSessionInput): Promise<RevokeSessionResult> {
  const outcome = await db.transaction((tx) => revokeSessionInTransaction(tx, input))

  await finishSessionRevocation(outcome, input)
  return outcome.result
}

export async function revokeSessionInTransaction(
  tx: Transaction,
  input: RevokeSessionInput,
  options: { releaseDeviceId?: boolean } = {},
): Promise<RevokeSessionTransactionOutcome> {
  // Grid mutations take this lock before checking the session row. Reusing
  // that order makes a claim either complete before revocation and get
  // removed here, or observe the revoked session after this transaction.
  await lockGridMutations(tx)
  const [session] = await tx
    .select()
    .from(sessions)
    .where(and(eq(sessions.id, input.sessionId), eq(sessions.userId, input.targetUserId)))
    .for("update")
    .limit(1)

  if (!session) {
    return {
      result: { session: null, revoked: false, alreadyRevoked: false },
      gridState: undefined,
    }
  }

  let result: RevokeSessionResult
  if (session.revoked) {
    if (options.releaseDeviceId && session.deviceId !== null) {
      await tx.update(sessions).set({ deviceId: null }).where(eq(sessions.id, session.id))
    }
    result = { session, revoked: false, alreadyRevoked: true }
  } else {
    const [updated] = await tx
      .update(sessions)
      .set({
        revoked: new Date(),
        active: false,
        ...(options.releaseDeviceId ? { deviceId: null } : {}),
        applePushToken: null,
        applePushTokenEncrypted: null,
        applePushTokenIv: null,
        applePushTokenTag: null,
        pushNotificationProvider: null,
        pushContentKeyPublic: null,
        pushContentKeyId: null,
        pushContentKeyAlgorithm: null,
        pushContentVersion: null,
      })
      .where(and(eq(sessions.id, input.sessionId), eq(sessions.userId, input.targetUserId), isNull(sessions.revoked)))
      .returning()
    if (!updated) throw new Error("Session revocation lost its row lock")
    result = { session: updated, revoked: true, alreadyRevoked: false }
  }

  const gridState = await removeGridSessionPresenceInTransaction(tx, input.targetUserId, input.sessionId)
  return { result, gridState }
}

export async function finishSessionRevocation(
  outcome: RevokeSessionTransactionOutcome,
  input: RevokeSessionInput,
): Promise<void> {
  // The committed local revocation must terminate local authority without
  // waiting for a best-effort broker round trip.
  if (outcome.result.session) {
    sessionAuthority.invalidate({ userId: input.targetUserId, sessionId: input.sessionId })
    connectionManager.closeConnectionForSession(input.targetUserId, input.sessionId, {
      authenticationInvalidated: true,
    }, input.preserveConnectionId)
  }
  if (outcome.result.revoked) {
    outboundPublications.enqueue({
      key: `session-revoked:${input.targetUserId}:${input.sessionId}`,
      priority: "critical",
      run: async () => {
        await internalMessaging.publish({
          target: { kind: "cluster" },
          event: { kind: "SessionRevoked", userId: UserId.make(input.targetUserId), sessionId: SessionId.make(input.sessionId) },
        })
      },
      merge: () => {},
    })
  }
  if (outcome.gridState) {
    await finishGridSessionAccess(outcome.gridState, input.targetUserId, input.sessionId)
  }
}
