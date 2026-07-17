import {
  Effect,
  Layer,
  Schema,
} from "effect"
import {
  and,
  eq,
  gt,
  isNull,
} from "drizzle-orm"
import {
  db,
} from "@in/server/db"
import {
  superadminSessions,
  superadminUsers,
  users,
} from "@in/server/db/schema"
import {
  hashToken,
} from "@in/server/utils/auth"
import {
  AdminAvatarAuthenticationLive,
  AdminAvatarOriginGuardLive,
  AdminAvatarSetupCompleteLive,
  AdminAuthenticationLive,
  AdminOriginGuardLive,
  AdminRecentStepUpLive,
  AdminSessionLookupFailure,
  AdminSessionStore,
  AdminSessionValueSchema,
  AdminSetupCompleteLive,
} from "./adminSecurity.effect"
import {
  ADMIN_IDLE_MS,
} from "./adminSecurityPolicy.effect"

const lookupSession = async (
  token: string | undefined,
  userAgent: string,
): Promise<unknown | null> => {
  if (!token) {
    return null
  }

  const tokenHash = hashToken(token)
  const session = (
    await db
      .select()
      .from(superadminSessions)
      .where(
        and(
          eq(superadminSessions.tokenHash, tokenHash),
          isNull(superadminSessions.revokedAt),
        ),
      )
      .limit(1)
  )[0]
  if (!session) {
    return null
  }

  const tokenUserId = Number(token.split(":")[0])
  if (
    !Number.isFinite(tokenUserId) ||
    tokenUserId !== session.userId
  ) {
    return null
  }

  const now = new Date()
  if (
    session.expiresAt <= now ||
    session.idleExpiresAt <= now
  ) {
    return null
  }

  const userAgentHash = userAgent
    ? hashToken(userAgent)
    : null
  if (
    session.userAgentHash &&
    session.userAgentHash !== userAgentHash
  ) {
    return null
  }

  const adminUser = (
    await db
      .select()
      .from(superadminUsers)
      .where(
        and(
          eq(superadminUsers.userId, session.userId),
          isNull(superadminUsers.disabledAt),
        ),
      )
      .limit(1)
  )[0]
  if (!adminUser) {
    return null
  }

  const user = (
    await db
      .select()
      .from(users)
      .where(eq(users.id, session.userId))
      .limit(1)
  )[0]
  if (!user?.email) {
    return null
  }

  const refreshed = await db
    .update(superadminSessions)
    .set({
      lastSeenAt: now,
      idleExpiresAt: new Date(
        now.getTime() + ADMIN_IDLE_MS,
      ),
    })
    .where(
      and(
        eq(superadminSessions.id, session.id),
        isNull(superadminSessions.revokedAt),
        gt(superadminSessions.expiresAt, now),
        gt(
          superadminSessions.idleExpiresAt,
          now,
        ),
      ),
    )
    .returning({
      id: superadminSessions.id,
    })
  if (refreshed.length === 0) {
    return null
  }

  return {
    sessionId: session.id,
    userId: user.id,
    email: user.email,
    firstName: user.firstName ?? null,
    lastName: user.lastName ?? null,
    passwordSet: Boolean(adminUser.passwordHash),
    totpEnabled: Boolean(adminUser.totpEnabledAt),
    stepUpAt: session.stepUpAt ?? null,
  }
}

export const AdminSessionStoreLive = Layer.succeed(
  AdminSessionStore,
  {
    lookup: (token, userAgent) =>
      Effect.tryPromise({
        try: () => lookupSession(token, userAgent),
        catch: (cause) =>
          new AdminSessionLookupFailure({ cause }),
      }).pipe(
        Effect.flatMap((value) =>
          value === null
            ? Effect.succeed(null)
            : Schema.decodeUnknownEffect(
                AdminSessionValueSchema,
              )(value).pipe(
                Effect.mapError(
                  (cause) =>
                    new AdminSessionLookupFailure({
                      cause,
                    }),
                ),
              ),
        ),
      ),
  },
)

export const AdminSecurityLive = Layer.mergeAll(
  AdminAvatarAuthenticationLive,
  AdminAvatarOriginGuardLive,
  AdminAvatarSetupCompleteLive,
  AdminOriginGuardLive,
  AdminAuthenticationLive,
  AdminSetupCompleteLive,
  AdminRecentStepUpLive,
)
