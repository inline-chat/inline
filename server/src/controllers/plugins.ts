import { Elysia, t } from "elysia"
import { InlineError } from "@in/server/types/errors"
import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { sessions, users, type DbSession } from "@in/server/db/schema"
import { hashToken, normalizeToken } from "@in/server/utils/auth"
import { ConnectionError_Reason } from "@inline-chat/protocol/core"

export type AuthTokenFailure = "invalid_auth" | "user_deactivated" | "session_revoked" | "user_id_mismatch"

export type AuthTokenErrorDetails = {
  failure: AuthTokenFailure
  credentialFingerprint?: string
  tokenUserId?: number
  sessionId?: number
  sessionUserId?: number
  sessionClientType?: string | null
  sessionClientVersion?: string | null
  sessionOsVersion?: string | null
  sessionLastActiveAt?: string | null
  sessionRevokedAt?: string | null
  userDeleted?: boolean | null
}

export class AuthTokenError extends InlineError {
  constructor(
    error: (typeof InlineError.ApiError)[keyof typeof InlineError.ApiError],
    public readonly connectionReason: ConnectionError_Reason,
    public readonly details?: AuthTokenErrorDetails,
  ) {
    super(error)
  }
}

export const getConnectionReasonFromAuthError = (error: unknown): ConnectionError_Reason => {
  if (error instanceof AuthTokenError) {
    return error.connectionReason
  }

  return ConnectionError_Reason.UNAUTHORIZED
}

export const getAuthTokenErrorDetails = (error: unknown): AuthTokenErrorDetails | undefined => {
  if (error instanceof AuthTokenError) {
    return error.details
  }

  return undefined
}

export const authenticate = new Elysia({ name: "authenticate-post" })
  .state("currentUserId", 0)
  .state("currentSessionId", 0)
  .guard({
    as: "scoped",

    headers: t.Object({
      // Normalize in `beforeHandle` so we can accept case-insensitive `bearer` and extra whitespace.
      authorization: t.Optional(t.String()),
    }),

    beforeHandle: async ({ headers, store }) => {
      let auth = headers["authorization"]
      let token = normalizeToken(auth)
      if (!token) {
        throw new AuthTokenError(InlineError.ApiError.UNAUTHORIZED, ConnectionError_Reason.INVALID_AUTH)
      }

      const { userId, sessionId } = await getUserIdFromToken(token)
      store.currentUserId = userId
      store.currentSessionId = sessionId
    },
  })

export const authenticateGet = new Elysia({ name: "authenticate-get" })
  .state("currentUserId", 0)
  .state("currentSessionId", 0)
  .guard({
    as: "scoped",

    params: t.Object({
      token: t.Optional(t.String()),
    }),

    beforeHandle: async ({ headers, params, store }) => {
      let auth = params.token ?? headers["authorization"]
      let token = normalizeToken(auth)
      if (!token) {
        throw new AuthTokenError(InlineError.ApiError.UNAUTHORIZED, ConnectionError_Reason.INVALID_AUTH)
      }

      const { userId, sessionId } = await getUserIdFromToken(token)
      store.currentUserId = userId
      store.currentSessionId = sessionId
    },
  })

export const getUserIdFromToken = async (token: string): Promise<{ userId: number; sessionId: number }> => {
  let tokenUserId = parseTokenUserId(token)
  let tokenHash = hashToken(token)
  const credentialFingerprint = getCredentialFingerprint(tokenHash)
  const [row] = await db
    .select({ session: sessions, userDeleted: users.deleted })
    .from(sessions)
    .leftJoin(users, eq(sessions.userId, users.id))
    .where(eq(sessions.tokenHash, tokenHash))
    .limit(1)
  const session = row?.session

  if (!session || tokenUserId === undefined) {
    throw new AuthTokenError(InlineError.ApiError.UNAUTHORIZED, ConnectionError_Reason.INVALID_AUTH, {
      failure: "invalid_auth",
      credentialFingerprint,
      tokenUserId,
    })
  }

  if (row.userDeleted === true) {
    throw new AuthTokenError(
      InlineError.ApiError.USER_DEACTIVATED,
      ConnectionError_Reason.UNAUTHORIZED,
      authTokenErrorDetails("user_deactivated", session, row.userDeleted, {
        credentialFingerprint,
        tokenUserId,
      }),
    )
  }

  if (session.revoked) {
    throw new AuthTokenError(
      InlineError.ApiError.SESSION_REVOKED,
      ConnectionError_Reason.SESSION_REVOKED,
      authTokenErrorDetails("session_revoked", session, row.userDeleted, {
        credentialFingerprint,
        tokenUserId,
      }),
    )
  }

  // TODO: update last active

  if (session.userId !== tokenUserId) {
    throw new AuthTokenError(
      InlineError.ApiError.UNAUTHORIZED,
      ConnectionError_Reason.UNAUTHORIZED,
      authTokenErrorDetails("user_id_mismatch", session, row.userDeleted, {
        credentialFingerprint,
        tokenUserId,
      }),
    )
  }

  const now = new Date()
  const shouldTouchLastActive =
    !session.lastActive || now.getTime() - session.lastActive.getTime() > 60_000 /* 60s */
  if (shouldTouchLastActive) {
    // Best-effort update; auth should not fail if last-active cannot be updated.
    void db
      .update(sessions)
      .set({ lastActive: now })
      .where(eq(sessions.id, session.id))
      .catch(() => {})
  }

  return { userId: session.userId, sessionId: session.id }
}

const parseTokenUserId = (token: string): number | undefined => {
  const [userIdSegment = ""] = token.split(":", 1)
  if (!/^\d+$/.test(userIdSegment)) return undefined

  const parsed = Number(userIdSegment)
  return Number.isSafeInteger(parsed) ? parsed : undefined
}

const getCredentialFingerprint = (tokenHash: string): string => tokenHash.slice(0, 16)

const authTokenErrorDetails = (
  failure: AuthTokenFailure,
  session: DbSession,
  userDeleted: boolean | null | undefined,
  details: Pick<AuthTokenErrorDetails, "credentialFingerprint" | "tokenUserId">,
): AuthTokenErrorDetails => ({
  failure,
  ...details,
  sessionId: session.id,
  sessionUserId: session.userId,
  sessionClientType: session.clientType,
  sessionClientVersion: session.clientVersion,
  sessionOsVersion: session.osVersion,
  sessionLastActiveAt: session.lastActive?.toISOString() ?? null,
  sessionRevokedAt: session.revoked?.toISOString() ?? null,
  userDeleted: userDeleted ?? null,
})
