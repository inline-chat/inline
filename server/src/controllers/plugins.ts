import { Elysia, t } from "elysia"
import { InlineError } from "@in/server/types/errors"
import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { sessions } from "@in/server/db/schema"
import { hashToken, normalizeToken } from "@in/server/utils/auth"
import { ConnectionError_Reason } from "@inline-chat/protocol/core"

export class AuthTokenError extends InlineError {
  constructor(
    error: (typeof InlineError.ApiError)[keyof typeof InlineError.ApiError],
    public readonly connectionReason: ConnectionError_Reason,
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
  let supposedUserId = token.split(":")[0]
  let tokenHash = hashToken(token)
  let session = await db._query.sessions.findFirst({
    where: eq(sessions.tokenHash, tokenHash),
  })

  if (!session || !supposedUserId) {
    throw new AuthTokenError(InlineError.ApiError.UNAUTHORIZED, ConnectionError_Reason.INVALID_AUTH)
  }

  if (session.revoked) {
    throw new AuthTokenError(InlineError.ApiError.SESSION_REVOKED, ConnectionError_Reason.SESSION_REVOKED)
  }

  // TODO: update last active

  if (session.userId !== parseInt(supposedUserId, 10)) {
    console.error("userId mismatch", session.userId, supposedUserId)
    throw new AuthTokenError(InlineError.ApiError.UNAUTHORIZED, ConnectionError_Reason.UNAUTHORIZED)
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
