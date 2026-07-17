import { Cause, Effect } from "effect"
import { HttpServerRequest, HttpServerResponse } from "effect/unstable/http"
import { normalizeToken } from "@in/server/utils/auth"
import { recordApiError } from "@in/server/utils/metrics"
import { reportUnexpectedError } from "../core/errors/errorReporter"
import { HttpRequestContext } from "../core/http/requestContext"
import {
  missingSessionAuthentication,
  SessionAuthentication,
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
import { prepareV1MessagingProvidersRequest } from "./v1MessagingProvidersRequest.effect"
import { V1UploadOperations } from "./v1UploadOperations.effect"

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

const validationError = (operation: V1MessagingProvidersOperation) =>
  usesBotCompatEnvelope(operation)
    ? json(400, {
        ok: false,
        error: "INVALID_ARGS",
        error_code: 400,
        description: "Validation error",
      })
    : json(400, {
        ok: false,
        error: "INVALID_ARGS",
        errorCode: 400,
        description: "Validation error",
      })

const publicErrorResponse = (
  operation: V1MessagingProvidersOperation,
  error: V1MessagingProvidersPublicError | SessionAuthenticationRejected,
) =>
  usesBotCompatEnvelope(operation)
    ? json(error.errorCode, {
        ok: false,
        error: error.error,
        error_code: error.errorCode,
        description: error.description ?? "",
      })
    : json(error.errorCode, {
        ok: false,
        error: error.error,
        errorCode: error.errorCode,
        description: error.description,
      })

const serverErrorResponse = (operation: V1MessagingProvidersOperation) =>
  usesBotCompatEnvelope(operation)
    ? json(500, {
        ok: false,
        error: "SERVER_ERROR",
        error_code: 500,
        description: "Server error",
      })
    : json(500, {
        ok: false,
        error: "SERVER_ERROR",
        errorCode: 500,
        description: "Server error",
      })

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
              ? Effect.succeed(publicErrorResponse(operation, error))
              : reportFailure(error.operation, error.cause).pipe(
                  Effect.as(
                    error.publicError === undefined
                      ? serverErrorResponse(operation)
                      : publicErrorResponse(operation, error.publicError),
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

export const executeV1MessagingProviders = (
  operation: V1MessagingProvidersOperation,
  request: HttpServerRequest.HttpServerRequest,
  options: {
    readonly pathToken?: string | undefined
  } = {},
) =>
  prepareV1MessagingProvidersRequest(request, operation).pipe(
    Effect.flatMap(({ input, webRequest }) =>
      prepareV1MessagingProvidersOperation(
        operation,
        input,
      ).pipe(
        Effect.matchEffect({
          onFailure: () => noteApiError.pipe(Effect.as(validationError(operation))),
          onSuccess: (prepared) =>
            authenticate(webRequest, options.pathToken).pipe(
              Effect.matchEffect({
                onFailure: (error) =>
                  noteApiError.pipe(
                    Effect.andThen(
                      error._tag === "SessionAuthenticationRejected"
                        ? Effect.succeed(publicErrorResponse(operation, error))
                        : reportFailure("v1.authenticate", error.cause).pipe(
                            Effect.as(serverErrorResponse(operation)),
                          ),
                    ),
                  ),
                onSuccess: (identity) =>
                  Effect.gen(function* () {
                    const requestContext = yield* HttpRequestContext
                    const messaging = yield* V1MessagingOperations
                    const providers = yield* V1ProviderOperations
                    const uploads = yield* V1UploadOperations
                    return yield* completeOperation(
                      operation,
                      prepared.run(
                        {
                          currentUserId: identity.userId,
                          currentSessionId:
                            identity.sessionId,
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
                  }),
              }),
            ),
        }),
      ),
    ),
    Effect.catchTags({
      V1MessagingProvidersPublicError: (error) =>
        noteApiError.pipe(Effect.as(publicErrorResponse(operation, error))),
      V1MessagingProvidersRequestFailure: (error) =>
        reportFailure(error.operation, error.cause).pipe(
          Effect.andThen(noteApiError),
          Effect.as(
            usesBotCompatEnvelope(operation)
              ? validationError(operation)
              : serverErrorResponse(operation),
          ),
        ),
    }),
    Effect.catch((cause) =>
      reportFailure(`v1.${operation}.request`, cause).pipe(
        Effect.andThen(noteApiError),
        Effect.as(serverErrorResponse(operation)),
      ),
    ),
  )
