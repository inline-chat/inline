import {
  Layer,
} from "effect"
import {
  AuthTokenError,
  getUserIdFromToken,
} from "@in/server/modules/auth/sessionAuthentication"
import {
  SessionAuthentication,
  SessionAuthenticationRejected,
  makeSessionAuthentication,
} from "./plugins.effect"

export const SessionAuthenticationLive = Layer.succeed(
  SessionAuthentication,
  makeSessionAuthentication({
    authenticateToken: getUserIdFromToken,
    classifyRejection: (cause) =>
      cause instanceof AuthTokenError
        ? new SessionAuthenticationRejected({
            error: cause.type,
            errorCode: cause.code,
            description: cause.description,
            connectionReason: cause.connectionReason,
            details: cause.details,
          })
        : undefined,
  }),
)
