import {
  ErrorReporter,
  Schema,
} from "effect"
import {
  HttpApiSchema,
} from "effect/unstable/httpapi"

const errorFields = <const Code extends string>(
  code: Code,
) => ({
  ok: Schema.Literal(false),
  error: Schema.Literal(code),
})

const jsonError = <
  const Codes extends readonly [
    string,
    ...Array<string>,
  ],
>(
  identifier: string,
  status: number,
  codes: Codes,
) =>
  Schema.Struct({
    ok: Schema.Literal(false),
    error: Schema.Literals(codes),
  }).pipe(HttpApiSchema.status(status)).annotate({
    identifier,
  })

const emptyError = <
  const Identifier extends string,
>(
  identifier: Identifier,
  status: number,
  description: string,
) =>
  Schema.Literal(identifier).pipe(
    HttpApiSchema.asNoContent({
      decode: () => identifier,
    }),
    HttpApiSchema.status(status),
  ).annotate({
    identifier,
    description,
  })

/**
 * Middleware failures are distinct because callers can act on each policy
 * failure differently. Route-operation errors below are wire schemas rather
 * than one tagged error per message.
 */
export class AdminOriginNotAllowedError extends Schema.ErrorClass<AdminOriginNotAllowedError>(
  "@inline/server/admin/AdminOriginNotAllowedError",
)(errorFields("origin_not_allowed"), {
  httpApiStatus: 403,
}) {
  override readonly [ErrorReporter.ignore] = true
}

export class AdminUnauthorizedError extends Schema.ErrorClass<AdminUnauthorizedError>(
  "@inline/server/admin/AdminUnauthorizedError",
)(errorFields("unauthorized"), {
  httpApiStatus: 401,
}) {
  override readonly [ErrorReporter.ignore] = true
}

export class AdminSetupRequiredError extends Schema.ErrorClass<AdminSetupRequiredError>(
  "@inline/server/admin/AdminSetupRequiredError",
)(errorFields("setup_required"), {
  httpApiStatus: 403,
}) {
  override readonly [ErrorReporter.ignore] = true
}

export class AdminStepUpRequiredError extends Schema.ErrorClass<AdminStepUpRequiredError>(
  "@inline/server/admin/AdminStepUpRequiredError",
)(errorFields("step_up_required"), {
  httpApiStatus: 403,
}) {
  override readonly [ErrorReporter.ignore] = true
}

export class AdminInternalServerError extends Schema.ErrorClass<AdminInternalServerError>(
  "@inline/server/admin/AdminInternalServerError",
)(errorFields("server_error"), {
  httpApiStatus: 500,
}) {
  // This public value is emitted only after the private cause was reported.
  override readonly [ErrorReporter.ignore] = true
}

export const AdminAvatarUnauthorizedValue =
  "AdminAvatarUnauthorized" as const
export const AdminAvatarForbiddenValue =
  "AdminAvatarForbidden" as const

export const AdminAvatarBadRequest = emptyError(
  "AdminAvatarBadRequest",
  400,
  "Empty response for an invalid user identifier.",
)

export const AdminAvatarUnauthorized = emptyError(
  AdminAvatarUnauthorizedValue,
  401,
  "Empty response when no valid admin session exists.",
)

export const AdminAvatarForbidden = emptyError(
  AdminAvatarForbiddenValue,
  403,
  "Empty response when an admin policy rejects the request.",
)

export const AdminAvatarNotFound = emptyError(
  "AdminAvatarNotFound",
  404,
  "Empty response when the avatar is unavailable.",
)

export const AdminAvatarServiceUnavailable =
  emptyError(
    "AdminAvatarServiceUnavailable",
    503,
    "Empty response when avatar storage is unavailable.",
  )

export const AdminSendEmailCodeBadRequest = jsonError(
  "AdminSendEmailCodeBadRequest",
  400,
  ["invalid_email"],
)

export const AdminSendEmailCodeForbidden = jsonError(
  "AdminSendEmailCodeForbidden",
  403,
  ["already_signed_in"],
)

export const AdminSendEmailCodeInternal = jsonError(
  "AdminSendEmailCodeInternal",
  500,
  ["send_failed", "server_error"],
)

export const AdminVerifyEmailCodeBadRequest = jsonError(
  "AdminVerifyEmailCodeBadRequest",
  400,
  ["invalid_email", "invalid_code"],
)

export const AdminVerifyEmailCodeUnauthorized = jsonError(
  "AdminVerifyEmailCodeUnauthorized",
  401,
  ["invalid_code"],
)

export const AdminVerifyEmailCodeForbidden = jsonError(
  "AdminVerifyEmailCodeForbidden",
  403,
  [
    "already_signed_in",
    "not_allowed",
    "password_required",
  ],
)

export const AdminVerifyEmailCodeInternal = jsonError(
  "AdminVerifyEmailCodeInternal",
  500,
  ["user_missing", "server_error"],
)

export const AdminLoginBadRequest = jsonError(
  "AdminLoginBadRequest",
  400,
  ["invalid_email"],
)

export const AdminLoginUnauthorized = jsonError(
  "AdminLoginUnauthorized",
  401,
  ["invalid_credentials", "invalid_totp"],
)

export const AdminLoginForbidden = jsonError(
  "AdminLoginForbidden",
  403,
  ["not_allowed", "password_not_set"],
)

export const AdminLoginTooManyRequests = jsonError(
  "AdminLoginTooManyRequests",
  429,
  ["login_locked"],
)

export const AdminSetPasswordBadRequest = jsonError(
  "AdminSetPasswordBadRequest",
  400,
  ["password_already_set", "password_too_short"],
)

export const AdminSetPasswordForbidden = jsonError(
  "AdminSetPasswordForbidden",
  403,
  ["not_allowed"],
)

export const AdminTotpSetupBadRequest = jsonError(
  "AdminTotpSetupBadRequest",
  400,
  ["password_required", "totp_already_enabled"],
)

export const AdminTotpSetupForbidden = jsonError(
  "AdminTotpSetupForbidden",
  403,
  ["not_allowed"],
)

export const AdminTotpVerifyBadRequest = jsonError(
  "AdminTotpVerifyBadRequest",
  400,
  ["totp_already_enabled", "invalid_totp"],
)

export const AdminTotpVerifyForbidden = jsonError(
  "AdminTotpVerifyForbidden",
  403,
  ["not_allowed"],
)

export const AdminStepUpBadRequest = jsonError(
  "AdminStepUpBadRequest",
  400,
  ["totp_required"],
)

export const AdminStepUpUnauthorized = jsonError(
  "AdminStepUpUnauthorized",
  401,
  ["invalid_credentials"],
)

export const AdminStepUpForbidden = jsonError(
  "AdminStepUpForbidden",
  403,
  ["not_allowed"],
)

export const AdminInvalidCountBadRequest = jsonError(
  "AdminInvalidCountBadRequest",
  400,
  ["invalid_count"],
)

export const AdminGrantInvitesBadRequest = jsonError(
  "AdminGrantInvitesBadRequest",
  400,
  ["invalid_user", "invalid_count"],
)

export const AdminInvalidUserBadRequest = jsonError(
  "AdminInvalidUserBadRequest",
  400,
  ["invalid_user"],
)

export const AdminInvalidSessionBadRequest = jsonError(
  "AdminInvalidSessionBadRequest",
  400,
  ["invalid_session"],
)

export const AdminUpdateUserBadRequest = jsonError(
  "AdminUpdateUserBadRequest",
  400,
  ["invalid_user", "invalid_email", "no_updates"],
)

export const AdminNotFound = jsonError(
  "AdminNotFound",
  404,
  ["not_found"],
)

export const AdminValidationError = Schema.Struct({
  type: Schema.Literal("validation"),
  on: Schema.Literals(["body", "query", "params"]),
  property: Schema.String,
  message: Schema.String,
  summary: Schema.String,
  expected: Schema.Record(Schema.String, Schema.Unknown),
  found: Schema.optionalKey(Schema.Unknown),
  errors: Schema.Array(Schema.Unknown),
}).pipe(HttpApiSchema.status(422)).annotate({
  identifier: "AdminValidationError",
})

export const AdminTransportBadRequest = Schema.Literal(
  "Bad Request",
).pipe(
  HttpApiSchema.status(400),
  HttpApiSchema.asText(),
).annotate({
  identifier: "AdminTransportBadRequest",
})
