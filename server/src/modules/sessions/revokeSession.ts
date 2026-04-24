import { db } from "@in/server/db"
import { sessions, type DbSession } from "@in/server/db/schema"
import { connectionManager } from "@in/server/ws/connections"
import { and, eq, isNull } from "drizzle-orm"

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
  const session = await db._query.sessions.findFirst({
    where: and(eq(sessions.id, input.sessionId), eq(sessions.userId, input.targetUserId)),
  })

  if (!session) {
    return { session: null, revoked: false, alreadyRevoked: false }
  }

  if (session.revoked) {
    return { session, revoked: false, alreadyRevoked: true }
  }

  const now = new Date()
  const [updated] = await db
    .update(sessions)
    .set({
      revoked: now,
      active: false,
      applePushToken: null,
      applePushTokenEncrypted: null,
      applePushTokenIv: null,
      applePushTokenTag: null,
      pushContentKeyPublic: null,
      pushContentKeyId: null,
      pushContentKeyAlgorithm: null,
      pushContentVersion: null,
    })
    .where(and(eq(sessions.id, input.sessionId), eq(sessions.userId, input.targetUserId), isNull(sessions.revoked)))
    .returning()

  if (!updated) {
    const latest = await db._query.sessions.findFirst({
      where: and(eq(sessions.id, input.sessionId), eq(sessions.userId, input.targetUserId)),
    })

    return { session: latest ?? session, revoked: false, alreadyRevoked: true }
  }

  connectionManager.closeConnectionForSession(input.targetUserId, input.sessionId)

  return { session: updated, revoked: true, alreadyRevoked: false }
}
