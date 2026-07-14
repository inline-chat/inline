import { db } from "@in/server/db"
import { sessions, type DbSession } from "@in/server/db/schema"
import { connectionManager } from "@in/server/ws/connections"
import { and, eq, isNull } from "drizzle-orm"
import { finishGridSessionAccess } from "@in/server/modules/grid/accessLifecycle"
import {
  lockGridMutations,
  removeGridSessionPresenceInTransaction,
} from "@in/server/modules/grid/roomLifecycle"

type RevokeActor = "admin" | "user" | "system"

export type RevokeSessionInput = {
  actor: RevokeActor
  actorUserId?: number
  targetUserId: number
  sessionId: number
}

export type RevokeSessionResult = {
  session: DbSession | null
  revoked: boolean
  alreadyRevoked: boolean
}

export async function revokeSession(input: RevokeSessionInput): Promise<RevokeSessionResult> {
  const outcome = await db.transaction(async (tx) => {
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
        result: { session: null, revoked: false, alreadyRevoked: false } satisfies RevokeSessionResult,
        gridState: undefined,
      }
    }

    if (session.revoked) {
      const gridState = await removeGridSessionPresenceInTransaction(tx, input.targetUserId, input.sessionId)
      return {
        result: { session, revoked: false, alreadyRevoked: true } satisfies RevokeSessionResult,
        gridState,
      }
    }

    const [updated] = await tx
      .update(sessions)
      .set({
        revoked: new Date(),
        active: false,
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

    const gridState = await removeGridSessionPresenceInTransaction(tx, input.targetUserId, input.sessionId)
    return {
      result: { session: updated, revoked: true, alreadyRevoked: false } satisfies RevokeSessionResult,
      gridState,
    }
  })

  if (outcome.gridState) {
    await finishGridSessionAccess(outcome.gridState, input.targetUserId, input.sessionId)
  }
  if (outcome.result.session) {
    connectionManager.closeConnectionForSession(input.targetUserId, input.sessionId)
  }
  return outcome.result
}
