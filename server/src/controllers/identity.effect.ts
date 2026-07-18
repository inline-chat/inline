import {
  Cause,
  Effect,
  Schema,
} from "effect"
import {
  HttpServerRequest,
  HttpServerResponse,
} from "effect/unstable/http"
import {
  HttpApiEndpoint,
  HttpApiGroup,
  HttpApiSchema,
} from "effect/unstable/httpapi"
import { normalizeToken } from "@in/server/utils/auth"
import { recordApiError } from "@in/server/utils/metrics"
import {
  reportUnexpectedError,
} from "../core/errors/errorReporter"
import {
  HttpRequestContext,
} from "../core/http/requestContext"
import {
  requireOpenApiRequestHeader,
} from "../core/http/openApi"
import {
  parseLegacyElysiaBody,
} from "../core/http/legacyElysiaBody"
import {
  missingSessionAuthentication,
  SessionAuthentication,
  type SessionAuthenticationRejected,
} from "./plugins.effect"
import {
  IdentityOperationFailure,
  IdentityOperations,
  type IdentityPublicError,
} from "../modules/auth/identityOperations.effect"
import {
  CheckInviteCodeInput,
  CheckInviteCodeResult,
  IdentityLogoutSuccess,
  LoginSessionResult,
  LogoutInput,
  SendEmailCodeInput,
  SendEmailCodeResult,
  SendSmsCodeInput,
  SendSmsCodeResult,
  VerifyEmailCodeInput,
  VerifySmsCodeInput,
  identityApiErrorAt,
  identitySuccess,
} from "../modules/auth/identitySchemas.effect"

const identityErrors = [
  identityApiErrorAt(400),
  identityApiErrorAt(401),
  identityApiErrorAt(420),
  identityApiErrorAt(500),
] as const

const SendSmsCodeSuccess = identitySuccess(
  SendSmsCodeResult,
).annotate({
  identifier: "SendSmsCodeSuccess",
})
const VerifySmsCodeSuccess = identitySuccess(
  LoginSessionResult,
).annotate({
  identifier: "VerifySmsCodeSuccess",
})
const SendEmailCodeSuccess = identitySuccess(
  SendEmailCodeResult,
).annotate({
  identifier: "SendEmailCodeSuccess",
})
const VerifyEmailCodeSuccess = identitySuccess(
  LoginSessionResult,
).annotate({
  identifier: "VerifyEmailCodeSuccess",
})
const CheckInviteCodeSuccess = identitySuccess(
  CheckInviteCodeResult,
).annotate({
  identifier: "CheckInviteCodeSuccess",
})

const AuthorizationHeader = {
  authorization: Schema.optionalKey(Schema.String),
} as const

const legacyPostPayloads = <
  S extends Schema.Top & Schema.Decoder<unknown>,
>(
  schema: S,
) => [
  schema,
  schema.pipe(HttpApiSchema.asFormUrlEncoded()),
  schema.pipe(HttpApiSchema.asMultipart()),
] as const

const IdentityEndpointGroup = HttpApiGroup.make("identity")
  .add(
    HttpApiEndpoint.get("getSendSmsCode", "/v1/sendSmsCode", {
      payload: SendSmsCodeInput.fields,
      success: SendSmsCodeSuccess,
      error: identityErrors,
    }),
  )
  .add(
    HttpApiEndpoint.post("postSendSmsCode", "/v1/sendSmsCode", {
      payload: legacyPostPayloads(SendSmsCodeInput),
      success: SendSmsCodeSuccess,
      error: identityErrors,
    }),
  )
  .add(
    HttpApiEndpoint.get("getVerifySmsCode", "/v1/verifySmsCode", {
      payload: VerifySmsCodeInput.fields,
      success: VerifySmsCodeSuccess,
      error: identityErrors,
    }),
  )
  .add(
    HttpApiEndpoint.post("postVerifySmsCode", "/v1/verifySmsCode", {
      payload: legacyPostPayloads(VerifySmsCodeInput),
      success: VerifySmsCodeSuccess,
      error: identityErrors,
    }),
  )
  .add(
    HttpApiEndpoint.get(
      "getSendEmailCode",
      "/v1/sendEmailCode",
      {
        payload: SendEmailCodeInput.fields,
        success: SendEmailCodeSuccess,
        error: identityErrors,
      },
    ),
  )
  .add(
    HttpApiEndpoint.post(
      "postSendEmailCode",
      "/v1/sendEmailCode",
      {
        payload: legacyPostPayloads(SendEmailCodeInput),
        success: SendEmailCodeSuccess,
        error: identityErrors,
      },
    ),
  )
  .add(
    HttpApiEndpoint.get(
      "getVerifyEmailCode",
      "/v1/verifyEmailCode",
      {
        payload: VerifyEmailCodeInput.fields,
        success: VerifyEmailCodeSuccess,
        error: identityErrors,
      },
    ),
  )
  .add(
    HttpApiEndpoint.post(
      "postVerifyEmailCode",
      "/v1/verifyEmailCode",
      {
        payload: legacyPostPayloads(VerifyEmailCodeInput),
        success: VerifyEmailCodeSuccess,
        error: identityErrors,
      },
    ),
  )
  .add(
    HttpApiEndpoint.get(
      "getCheckInviteCode",
      "/v1/checkInviteCode",
      {
        payload: CheckInviteCodeInput.fields,
        success: CheckInviteCodeSuccess,
        error: identityErrors,
      },
    ),
  )
  .add(
    HttpApiEndpoint.post(
      "postCheckInviteCode",
      "/v1/checkInviteCode",
      {
        payload: legacyPostPayloads(CheckInviteCodeInput),
        success: CheckInviteCodeSuccess,
        error: identityErrors,
      },
    ),
  )
  .add(
    HttpApiEndpoint.get("getLogout", "/v1/logout", {
      payload: LogoutInput.fields,
      headers: AuthorizationHeader,
      success: IdentityLogoutSuccess,
      error: identityErrors,
    }).annotateMerge(
      requireOpenApiRequestHeader(
        "authorization",
        "Required session token using the Bearer scheme.",
      ),
    ),
  )
  .add(
    HttpApiEndpoint.get(
      "getLogoutWithToken",
      "/v1/:token/logout",
      {
        params: {
          token: Schema.String,
        },
        payload: LogoutInput.fields,
        success: IdentityLogoutSuccess,
        error: identityErrors,
      },
    ),
  )
  .add(
    HttpApiEndpoint.post("postLogout", "/v1/logout", {
      headers: AuthorizationHeader,
      payload: legacyPostPayloads(LogoutInput),
      success: IdentityLogoutSuccess,
      error: identityErrors,
    }).annotateMerge(
      requireOpenApiRequestHeader(
        "authorization",
        "Required session token using the Bearer scheme.",
      ),
    ),
  )

export const IdentityEndpoints =
  IdentityEndpointGroup.endpoints

const json = (
  status: number,
  body: unknown,
): HttpServerResponse.HttpServerResponse =>
  HttpServerResponse.jsonUnsafe(body, { status })

const noteApiError = Effect.sync(() => {
  try {
    recordApiError()
  } catch {
    // Metrics must not replace the response being emitted.
  }
})

const validationError = () =>
  json(400, {
    ok: false,
    error: "INVALID_ARGS",
    errorCode: 400,
    description: "Validation error",
  })

const publicErrorResponse = (
  error: IdentityPublicError | SessionAuthenticationRejected,
) =>
  json(error.errorCode, {
    ok: false,
    error: error.error,
    errorCode: error.errorCode,
    description: error.description,
  })

const serverErrorResponse = () =>
  json(500, {
    ok: false,
    error: "SERVER_ERROR",
    errorCode: 500,
    description: "Server error",
  })

const reportFailure = (
  operation: string,
  cause: unknown,
) =>
  Effect.gen(function* () {
    const context = yield* HttpRequestContext
    yield* reportUnexpectedError({
      cause: Cause.fail(cause),
      context: {
        operation,
        requestId: context.requestId,
      },
    })
  })

const bodyToInput = async (
  request: Request,
): Promise<unknown> => {
  if (request.method === "GET") {
    return Object.fromEntries(new URL(request.url).searchParams)
  }

  return await parseLegacyElysiaBody(request)
}

const InvalidIdentityPayload = Symbol(
  "InvalidIdentityPayload",
)

const completeOperation = <A>(
  operation: string,
  effect: Effect.Effect<
    A,
    IdentityPublicError | IdentityOperationFailure
  >,
  success: (value: A) => unknown,
) =>
  effect.pipe(
    Effect.matchEffect({
      onFailure: (error) =>
        noteApiError.pipe(
          Effect.andThen(
            error._tag === "IdentityPublicError"
              ? Effect.succeed(publicErrorResponse(error))
              : reportFailure(
                  error.operation,
                  error.cause,
                ).pipe(
                  Effect.as(
                    error.publicError === undefined
                      ? serverErrorResponse()
                      : publicErrorResponse(error.publicError),
                  ),
                ),
          ),
        ),
      onSuccess: (value) =>
        Effect.succeed(json(200, success(value))),
    }),
    Effect.annotateLogs({
      "identity.operation": operation,
    }),
  )

const decodeAndRun = <Input, Output>(
  operation: string,
  schema: Schema.Decoder<Input>,
  rawInput: unknown,
  run: (
    input: Input,
  ) => Effect.Effect<
    Output,
    IdentityPublicError | IdentityOperationFailure
  >,
) =>
  Schema.decodeUnknownEffect(schema)(rawInput).pipe(
    Effect.matchEffect({
      onFailure: () =>
        noteApiError.pipe(
          Effect.as(validationError()),
        ),
      onSuccess: (input) =>
        completeOperation(
          operation,
          run(input),
          (result) => ({
            ok: true,
            result,
          }),
        ),
    }),
  )

const prepareRequest = (
  request: HttpServerRequest.HttpServerRequest,
) =>
  HttpServerRequest.toWeb(request).pipe(
    Effect.flatMap((webRequest) =>
      Effect.tryPromise({
        try: () => bodyToInput(webRequest),
        catch: () => InvalidIdentityPayload,
      }).pipe(
        Effect.map((input) => ({
          webRequest,
          input,
        })),
      ),
    ),
  )

export type UnauthenticatedIdentityOperation =
  | "sendSmsCode"
  | "verifySmsCode"
  | "sendEmailCode"
  | "verifyEmailCode"
  | "checkInviteCode"

export const executeUnauthenticatedIdentity = (
  operation: UnauthenticatedIdentityOperation,
  request: HttpServerRequest.HttpServerRequest,
) =>
  prepareRequest(request).pipe(
    Effect.flatMap(({ input, webRequest }) =>
      HttpRequestContext.use((requestContext) =>
        IdentityOperations.use((operations) => {
          const context = {
            ip: requestContext.clientIp,
            source: new URL(webRequest.url).pathname,
          }

          switch (operation) {
            case "sendSmsCode":
              return decodeAndRun(
                "identity.sendSmsCode",
                SendSmsCodeInput,
                input,
                (decoded) =>
                  operations.sendSmsCode(decoded, context),
              )
            case "verifySmsCode":
              return decodeAndRun(
                "identity.verifySmsCode",
                VerifySmsCodeInput,
                input,
                (decoded) =>
                  operations.verifySmsCode(decoded, context),
              )
            case "sendEmailCode":
              return decodeAndRun(
                "identity.sendEmailCode",
                SendEmailCodeInput,
                input,
                (decoded) =>
                  operations.sendEmailCode(decoded, context),
              )
            case "verifyEmailCode":
              return decodeAndRun(
                "identity.verifyEmailCode",
                VerifyEmailCodeInput,
                input,
                (decoded) =>
                  operations.verifyEmailCode(decoded, context),
              )
            case "checkInviteCode":
              return decodeAndRun(
                "identity.checkInviteCode",
                CheckInviteCodeInput,
                input,
                (decoded) =>
                  operations.checkInviteCode(decoded, context),
              )
          }
        }),
      ),
    ),
    Effect.catch((cause) =>
      cause === InvalidIdentityPayload
        ? noteApiError.pipe(Effect.as(serverErrorResponse()))
        : reportFailure(
            `identity.${operation}.request`,
            cause,
          ).pipe(Effect.as(serverErrorResponse())),
    ),
  )

export const executeIdentityLogout = (
  request: HttpServerRequest.HttpServerRequest,
  pathToken: string | undefined,
) =>
  prepareRequest(request).pipe(
    Effect.flatMap(({ input, webRequest }) =>
      Schema.decodeUnknownEffect(LogoutInput)(
        input === undefined ? {} : input,
      ).pipe(
        Effect.matchEffect({
          onFailure: () =>
            noteApiError.pipe(
              Effect.as(validationError()),
            ),
          onSuccess: () => {
            const authentication =
              normalizeToken(
                pathToken ??
                  webRequest.headers.get("authorization") ??
                  undefined,
              )
            const authenticate =
              authentication === null
                ? Effect.fail(
                    missingSessionAuthentication(),
                  )
                : SessionAuthentication.use((service) =>
                    service.authenticate(authentication),
                  )

            return authenticate.pipe(
              Effect.matchEffect({
                onFailure: (error) =>
                  noteApiError.pipe(
                    Effect.andThen(
                      error._tag ===
                          "SessionAuthenticationRejected"
                        ? Effect.succeed(
                            publicErrorResponse(error),
                          )
                        : reportFailure(
                            "identity.authenticate",
                            error.cause,
                          ).pipe(
                            Effect.as(serverErrorResponse()),
                          ),
                    ),
                  ),
                onSuccess: (identity) =>
                  HttpRequestContext.use((requestContext) =>
                    IdentityOperations.use((operations) =>
                      completeOperation(
                        "identity.logout",
                        operations.logout({
                          currentUserId: identity.userId,
                          currentSessionId: identity.sessionId,
                          ip: requestContext.clientIp,
                        }),
                        () => ({ ok: true }),
                      ),
                    ),
                  ),
              }),
            )
          },
        }),
      ),
    ),
    Effect.catch((cause) =>
      cause === InvalidIdentityPayload
        ? noteApiError.pipe(Effect.as(serverErrorResponse()))
        : reportFailure(
            "identity.logout.request",
            cause,
          ).pipe(Effect.as(serverErrorResponse())),
    ),
  )
