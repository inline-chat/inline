import {
  Cause,
  Context,
  Data,
  Effect,
  Layer,
  Redacted,
  Schema,
} from "effect"
import {
  HttpServerRequest,
} from "effect/unstable/http"
import {
  HttpApiMiddleware,
} from "effect/unstable/httpapi"
import {
  ErrorReporter,
  reportUnexpectedError,
} from "../core/errors/errorReporter"
import {
  SessionId,
  UserId,
} from "../core/schema/identifiers"
import {
  AdminAvatarForbidden,
  AdminAvatarForbiddenValue,
  AdminAvatarUnauthorized,
  AdminAvatarUnauthorizedValue,
  AdminOriginNotAllowedError,
  AdminSetupRequiredError,
  AdminStepUpRequiredError,
  AdminInternalServerError,
  AdminUnauthorizedError,
} from "./adminErrors.effect"
import {
  AdminSessionSecurity,
} from "./adminCookies.effect"
import {
  ADMIN_STEP_UP_WINDOW_MS,
} from "./adminSecurityPolicy.effect"

const isProduction = () =>
  process.env.NODE_ENV === "production"

export const AdminSessionValueSchema = Schema.Struct({
  sessionId: SessionId,
  userId: UserId,
  email: Schema.String,
  firstName: Schema.NullOr(Schema.String),
  lastName: Schema.NullOr(Schema.String),
  passwordSet: Schema.Boolean,
  totpEnabled: Schema.Boolean,
  stepUpAt: Schema.NullOr(Schema.Date),
}).annotate({
  identifier: "AdminSession",
})

export type AdminSessionValue =
  typeof AdminSessionValueSchema.Type

export class AdminSession extends Context.Service<
  AdminSession,
  AdminSessionValue
>()("@inline/server/admin/AdminSession") {}

export class AdminSessionLookupFailure extends Data.TaggedError(
  "AdminSessionLookupFailure",
)<{
  readonly cause: unknown
}> {}

export interface AdminSessionStoreShape {
  readonly lookup: (
    token: string | undefined,
    userAgent: string,
  ) => Effect.Effect<
    AdminSessionValue | null,
    AdminSessionLookupFailure
  >
}

export class AdminSessionStore extends Context.Service<
  AdminSessionStore,
  AdminSessionStoreShape
>()("@inline/server/admin/AdminSessionStore") {}

const AuthenticationError = [
  AdminUnauthorizedError,
  AdminInternalServerError,
] as const

export class AdminOriginGuard extends HttpApiMiddleware.Service<
  AdminOriginGuard
>()("@inline/server/admin/AdminOriginGuard", {
  error: AdminOriginNotAllowedError,
}) {}

export class AdminAuthentication extends HttpApiMiddleware.Service<
  AdminAuthentication,
  {
    provides: AdminSession
    requires:
      | AdminSessionStore
      | ErrorReporter
  }
>()("@inline/server/admin/AdminAuthentication", {
  error: AuthenticationError,
  security: {
    adminSession: AdminSessionSecurity,
  },
}) {}

export class AdminSetupComplete extends HttpApiMiddleware.Service<
  AdminSetupComplete,
  {
    requires: AdminSession
  }
>()("@inline/server/admin/AdminSetupComplete", {
  error: AdminSetupRequiredError,
}) {}

export class AdminRecentStepUp extends HttpApiMiddleware.Service<
  AdminRecentStepUp,
  {
    requires: AdminSession
  }
>()("@inline/server/admin/AdminRecentStepUp", {
  error: AdminStepUpRequiredError,
}) {}

/**
 * The avatar endpoint intentionally preserves its legacy empty 401/403
 * responses. Dedicated middleware keeps that route-specific wire contract out
 * of the JSON middleware used by every other Admin endpoint.
 */
export class AdminAvatarOriginGuard extends HttpApiMiddleware.Service<
  AdminAvatarOriginGuard
>()("@inline/server/admin/AdminAvatarOriginGuard", {
  error: AdminAvatarForbidden,
}) {}

export class AdminAvatarAuthentication extends HttpApiMiddleware.Service<
  AdminAvatarAuthentication,
  {
    provides: AdminSession
    requires:
      | AdminSessionStore
      | ErrorReporter
  }
>()("@inline/server/admin/AdminAvatarAuthentication", {
  error: [
    AdminAvatarUnauthorized,
    AdminInternalServerError,
  ],
  security: {
    adminSession: AdminSessionSecurity,
  },
}) {}

export class AdminAvatarSetupComplete extends HttpApiMiddleware.Service<
  AdminAvatarSetupComplete,
  {
    requires: AdminSession
  }
>()("@inline/server/admin/AdminAvatarSetupComplete", {
  error: AdminAvatarForbidden,
}) {}

const ADMIN_ALLOWED_ORIGINS = new Set([
  "https://admin.inline.chat",
  "http://localhost:5174",
  "http://127.0.0.1:5174",
])

export const isAllowedAdminOrigin = (
  headers: Readonly<Record<string, string | undefined>>,
): boolean => {
  const origin = headers["origin"]
  if (
    origin !== undefined &&
    ADMIN_ALLOWED_ORIGINS.has(origin)
  ) {
    return true
  }

  const referer = headers["referer"]
  if (referer !== undefined) {
    for (const allowed of ADMIN_ALLOWED_ORIGINS) {
      if (referer.startsWith(`${allowed}/`)) {
        return true
      }
    }
  }

  return !isProduction()
}

export const AdminOriginGuardLive = Layer.succeed(
  AdminOriginGuard,
  (effect) =>
    Effect.gen(function* () {
      const request = yield* HttpServerRequest.HttpServerRequest
      if (!isAllowedAdminOrigin(request.headers)) {
        return yield* Effect.fail(new AdminOriginNotAllowedError({
          ok: false as const,
          error: "origin_not_allowed",
        }))
      }
      return yield* effect
    }),
)

const lookupAdminSession = (
  credential: Redacted.Redacted<string>,
) =>
  Effect.gen(function* () {
    const request =
      yield* HttpServerRequest.HttpServerRequest
    const store = yield* AdminSessionStore
    return yield* store
      .lookup(
        Redacted.value(credential) || undefined,
        request.headers["user-agent"] ?? "",
      )
      .pipe(
        Effect.catchTag(
          "AdminSessionLookupFailure",
          (failure) =>
            reportUnexpectedError({
              cause: Cause.fail(failure.cause),
              context: {
                operation:
                  "admin.authentication.lookup",
              },
            }).pipe(
              Effect.andThen(
                Effect.fail(new AdminInternalServerError({
                  ok: false as const,
                  error: "server_error",
                })),
              ),
            ),
        ),
      )
  })

export const AdminAuthenticationLive = Layer.succeed(
  AdminAuthentication,
  {
    adminSession: (effect, { credential }) =>
      Effect.gen(function* () {
        const session =
          yield* lookupAdminSession(credential)
        if (session === null) {
          return yield* Effect.fail(
            new AdminUnauthorizedError({
              ok: false as const,
              error: "unauthorized",
            }),
          )
        }

        return yield* effect.pipe(
          Effect.provideService(
            AdminSession,
            session,
          ),
        )
      }),
  },
)

export const AdminAvatarOriginGuardLive = Layer.succeed(
  AdminAvatarOriginGuard,
  (effect) =>
    Effect.gen(function* () {
      const request =
        yield* HttpServerRequest.HttpServerRequest
      if (!isAllowedAdminOrigin(request.headers)) {
        return yield* Effect.fail(
          AdminAvatarForbiddenValue,
        )
      }
      return yield* effect
    }),
)

export const AdminAvatarAuthenticationLive =
  Layer.succeed(
    AdminAvatarAuthentication,
    {
      adminSession: (effect, { credential }) =>
        Effect.gen(function* () {
          const session =
            yield* lookupAdminSession(credential)
          if (session === null) {
            return yield* Effect.fail(
              AdminAvatarUnauthorizedValue,
            )
          }

          return yield* effect.pipe(
            Effect.provideService(
              AdminSession,
              session,
            ),
          )
        }),
    },
  )

export const AdminSetupCompleteLive = Layer.succeed(
  AdminSetupComplete,
  (effect) =>
    Effect.gen(function* () {
      const session = yield* AdminSession
      if (
        !session.passwordSet ||
        !session.totpEnabled
      ) {
        return yield* Effect.fail(new AdminSetupRequiredError({
          ok: false as const,
          error: "setup_required",
        }))
      }
      return yield* effect
    }),
)

export const AdminAvatarSetupCompleteLive =
  Layer.succeed(
    AdminAvatarSetupComplete,
    (effect) =>
      Effect.gen(function* () {
        const session = yield* AdminSession
        if (
          !session.passwordSet ||
          !session.totpEnabled
        ) {
          return yield* Effect.fail(
            AdminAvatarForbiddenValue,
          )
        }
        return yield* effect
      }),
  )

export const AdminRecentStepUpLive = Layer.succeed(
  AdminRecentStepUp,
  (effect) =>
    Effect.gen(function* () {
      const session = yield* AdminSession
      if (
        session.stepUpAt === null ||
        Date.now() - session.stepUpAt.getTime() >
          ADMIN_STEP_UP_WINDOW_MS
      ) {
        return yield* Effect.fail(new AdminStepUpRequiredError({
          ok: false as const,
          error: "step_up_required",
        }))
      }
      return yield* effect
    }),
)
