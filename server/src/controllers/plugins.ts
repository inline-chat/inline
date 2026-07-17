import { Elysia, t } from "elysia"
import { InlineError } from "@in/server/types/errors"
import { normalizeToken } from "@in/server/utils/auth"
import { ConnectionError_Reason } from "@inline-chat/protocol/core"
import {
  AuthTokenError,
  getUserIdFromToken,
} from "@in/server/modules/auth/sessionAuthentication"

export {
  AuthTokenError,
  getAuthTokenErrorDetails,
  getConnectionReasonFromAuthError,
  getUserIdFromToken,
  type AuthTokenErrorDetails,
  type AuthTokenFailure,
} from "@in/server/modules/auth/sessionAuthentication"

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
