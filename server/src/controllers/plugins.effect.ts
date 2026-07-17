import {
  Context,
  Data,
  Effect,
  ErrorReporter,
  Schema,
} from "effect"
import { ConnectionError_Reason } from "@inline-chat/protocol/core"
import type {
  AuthTokenErrorDetails,
} from "@in/server/modules/auth/sessionAuthentication"
import {
  SessionId,
  UserId,
} from "../core/schema/identifiers"

export const SessionIdentity = Schema.Struct({
  userId: UserId,
  sessionId: SessionId,
}).annotate({
  identifier: "SessionIdentity",
})

export type SessionIdentity = typeof SessionIdentity.Type

export const makeSessionIdentity = (
  userId: number,
  sessionId: number,
): SessionIdentity =>
  Schema.decodeUnknownSync(SessionIdentity)({
    userId,
    sessionId,
  })

export class SessionAuthenticationRejected extends Data.TaggedError(
  "SessionAuthenticationRejected",
)<{
  readonly error: string
  readonly errorCode: number
  readonly description: string | undefined
  readonly connectionReason: ConnectionError_Reason
  readonly details?: AuthTokenErrorDetails | undefined
}> {
  override readonly [ErrorReporter.ignore] = true
}

export class SessionAuthenticationFailure extends Data.TaggedError(
  "SessionAuthenticationFailure",
)<{
  readonly cause: unknown
}> {}

export interface SessionAuthenticationShape {
  readonly authenticate: (
    token: string,
  ) => Effect.Effect<
    SessionIdentity,
    SessionAuthenticationRejected | SessionAuthenticationFailure
  >
}

export class SessionAuthentication extends Context.Service<
  SessionAuthentication,
  SessionAuthenticationShape
>()("@inline/server/auth/SessionAuthentication") {}

export interface SessionAuthenticationAdapterOptions {
  readonly authenticateToken: (
    token: string,
  ) => Promise<{
    readonly userId: number
    readonly sessionId: number
  }>
  readonly classifyRejection: (
    cause: unknown,
  ) => SessionAuthenticationRejected | undefined
}

export const makeSessionAuthentication = ({
  authenticateToken,
  classifyRejection,
}: SessionAuthenticationAdapterOptions): SessionAuthenticationShape => ({
  authenticate: (token) =>
    Effect.tryPromise({
      try: () => authenticateToken(token),
      catch: (cause) =>
        classifyRejection(cause) ??
        new SessionAuthenticationFailure({ cause }),
    }).pipe(
      Effect.flatMap((identity) =>
        Schema.decodeUnknownEffect(SessionIdentity)(
          identity,
        ).pipe(
          Effect.mapError(
            (cause) =>
              new SessionAuthenticationFailure({ cause }),
          ),
        ),
      ),
    ),
})

export const missingSessionAuthentication =
  (): SessionAuthenticationRejected =>
    new SessionAuthenticationRejected({
      error: "UNAUTHORIZED",
      errorCode: 401,
      description: "Unauthorized",
      connectionReason: ConnectionError_Reason.INVALID_AUTH,
    })
