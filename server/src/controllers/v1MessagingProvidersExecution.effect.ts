import { Cause, Effect } from "effect"
import { HttpServerRequest, HttpServerResponse } from "effect/unstable/http"
import { normalizeToken } from "@in/server/utils/auth"
import { recordApiError } from "@in/server/utils/metrics"
import { reportUnexpectedError } from "../core/errors/errorReporter"
import { HttpRequestContext } from "../core/http/requestContext"
import {
  missingSessionAuthentication,
  SessionAuthentication,
  type SessionIdentity,
  type SessionAuthenticationRejected,
} from "./plugins.effect"
import {
  V1MessagingOperations,
} from "./v1MessagingOperations.effect"
import type {
  V1MessagingProvidersOperationError,
  V1MessagingProvidersPublicError,
} from "./v1MessagingProvidersErrors.effect"
import { V1ProviderOperations } from "./v1ProviderOperations.effect"
import type { V1MessagingProvidersOperation } from "./v1MessagingProvidersContracts.effect"
import {
  prepareV1MessagingProvidersOperation,
} from "./v1MessagingProvidersDispatch.effect"
import {
  prepareV1MessagingProvidersRequest,
  toV1MessagingProvidersWebRequest,
} from "./v1MessagingProvidersRequest.effect"
import {
  V1UploadAdmission,
} from "./v1UploadAdmission.effect"
import { V1UploadOperations } from "./v1UploadOperations.effect"
import {
  validateV1UploadRequestHeaders,
} from "./v1UploadRequest.effect"

const json = (status: number, body: unknown): HttpServerResponse.HttpServerResponse =>
  HttpServerResponse.jsonUnsafe(body, { status })

const noteApiError = Effect.sync(() => {
  try {
    recordApiError()
  } catch {
    // Metrics must not replace the response being emitted.
  }
})

const usesBotCompatEnvelope = (operation: V1MessagingProvidersOperation): boolean =>
  operation === "sendMessage20250509"

const validationError = () =>
  json(400, {
    ok: false,
    error: "INVALID_ARGS",
    errorCode: 400,
    description: "Validation error",
  })

const publicErrorResponse = (
  error: V1MessagingProvidersPublicError | SessionAuthenticationRejected,
) =>
  json(error.errorCode, {
    ok: false,
    error: error.error,
    errorCode: error.errorCode,
    description: error.description,
  })

const operationPublicErrorResponse = (
  operation: V1MessagingProvidersOperation,
  error: V1MessagingProvidersPublicError,
) =>
  usesBotCompatEnvelope(operation)
    ? json(error.errorCode, {
        ok: false,
        error: error.error,
        error_code: error.errorCode,
        description:
          error.description ?? "",
      })
    : publicErrorResponse(error)

const serverErrorResponse = () =>
  json(500, {
    ok: false,
    error: "SERVER_ERROR",
    errorCode: 500,
    description: "Server error",
  })

const operationServerErrorResponse = (
  operation: V1MessagingProvidersOperation,
) =>
  usesBotCompatEnvelope(operation)
    ? json(500, {
        ok: false,
        error: "SERVER_ERROR",
        error_code: 500,
        description: "Server error",
      })
    : serverErrorResponse()

const reportFailure = (operation: string, cause: unknown) =>
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

const completeOperation = <A>(
  operation: V1MessagingProvidersOperation,
  effect: Effect.Effect<
    A,
    V1MessagingProvidersOperationError
  >,
  success: (value: A) => unknown,
) =>
  effect.pipe(
    Effect.matchEffect({
      onFailure: (error) =>
        noteApiError.pipe(
          Effect.andThen(
            error._tag === "V1MessagingProvidersPublicError"
              ? Effect.succeed(operationPublicErrorResponse(operation, error))
              : reportFailure(error.operation, error.cause).pipe(
                  Effect.as(
                    error.publicError === undefined
                      ? operationServerErrorResponse(operation)
                      : operationPublicErrorResponse(operation, error.publicError),
                  ),
                ),
          ),
        ),
      onSuccess: (value) => Effect.succeed(json(200, success(value))),
    }),
    Effect.annotateLogs({ "v1.operation": `v1.${operation}` }),
  )

const authenticate = (request: Request, pathToken: string | undefined) => {
  const token = normalizeToken(pathToken ?? request.headers.get("authorization") ?? undefined)
  return token === null
    ? Effect.fail(missingSessionAuthentication())
    : SessionAuthentication.use((service) => service.authenticate(token))
}

const authenticationFailureResponse = (
  error:
    | SessionAuthenticationRejected
    | {
      readonly _tag:
        "SessionAuthenticationFailure"
      readonly cause: unknown
    },
) =>
  noteApiError.pipe(
    Effect.andThen(
      error._tag ===
          "SessionAuthenticationRejected"
        ? Effect.succeed(
            publicErrorResponse(error),
          )
        : reportFailure(
            "v1.authenticate",
            error.cause,
          ).pipe(
            Effect.as(
              serverErrorResponse(),
            ),
          ),
    ),
  )

const runPreparedOperation = (
  operation:
    V1MessagingProvidersOperation,
  rawInput: unknown,
  webRequest: Request,
  identity?: SessionIdentity,
  pathToken?: string,
) =>
  prepareV1MessagingProvidersOperation(
    operation,
    rawInput,
  ).pipe(
    Effect.matchEffect({
      onFailure: () =>
        noteApiError.pipe(
          Effect.as(validationError()),
        ),
      onSuccess: (prepared) => {
        const run = (
          authenticated:
            SessionIdentity,
        ) =>
          Effect.gen(function* () {
            const requestContext =
              yield* HttpRequestContext
            const messaging =
              yield* V1MessagingOperations
            const providers =
              yield* V1ProviderOperations
            const uploads =
              yield* V1UploadOperations
            return yield* completeOperation(
              operation,
              prepared.run(
                {
                  currentUserId:
                    authenticated.userId,
                  currentSessionId:
                    authenticated.sessionId,
                  ip:
                    requestContext.clientIp,
                },
                {
                  messaging,
                  providers,
                  uploads,
                },
              ),
              prepared.success,
            )
          })

        return identity === undefined
          ? authenticate(
              webRequest,
              pathToken,
            ).pipe(
              Effect.matchEffect({
                onFailure:
                  authenticationFailureResponse,
                onSuccess: run,
              }),
            )
          : run(identity)
      },
    }),
  )

const runAuthenticatedUpload = (
  request:
    HttpServerRequest.HttpServerRequest,
  webRequest: Request,
  identity: SessionIdentity,
) =>
  V1UploadAdmission.use(
    (admission) =>
      admission.withPermit(
        prepareV1MessagingProvidersRequest(
          request,
          "uploadFile",
          webRequest,
        ).pipe(
          Effect.flatMap(
            ({ input }) =>
              runPreparedOperation(
                "uploadFile",
                input,
                webRequest,
                identity,
              ),
          ),
        ),
      ),
  )

export const executeV1MessagingProviders = (
  operation: V1MessagingProvidersOperation,
  request: HttpServerRequest.HttpServerRequest,
  options: {
    readonly pathToken?: string | undefined
  } = {},
) =>
  (
    operation === "uploadFile"
      ? validateV1UploadRequestHeaders(
          request,
        ).pipe(
          Effect.andThen(
            toV1MessagingProvidersWebRequest(
              request,
            ),
          ),
          Effect.flatMap((webRequest) =>
            authenticate(
              webRequest,
              options.pathToken,
            ).pipe(
              Effect.matchEffect({
                onFailure:
                  authenticationFailureResponse,
                onSuccess: (identity) =>
                  runAuthenticatedUpload(
                    request,
                    webRequest,
                    identity,
                  ),
              }),
            ),
          ),
        )
      : prepareV1MessagingProvidersRequest(
          request,
          operation,
        ).pipe(
          Effect.flatMap(
            ({ input, webRequest }) =>
              runPreparedOperation(
                operation,
                input,
                webRequest,
                undefined,
                options.pathToken,
              ),
          ),
        )
  ).pipe(
    Effect.catchTags({
      V1MessagingProvidersPublicError: (error) =>
        noteApiError.pipe(
          Effect.as(
            publicErrorResponse(error),
          ),
        ),
      V1MessagingProvidersRequestFailure: (error) =>
        reportFailure(error.operation, error.cause).pipe(
          Effect.andThen(noteApiError),
          Effect.as(serverErrorResponse()),
        ),
    }),
    Effect.catch((cause) =>
      reportFailure(`v1.${operation}.request`, cause).pipe(
        Effect.andThen(noteApiError),
        Effect.as(serverErrorResponse()),
      ),
    ),
  )
