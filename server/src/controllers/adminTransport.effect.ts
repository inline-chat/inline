import {
  Cause,
  Data,
  Effect,
  ErrorReporter as EffectErrorReporter,
  Schema,
} from "effect"
import {
  HttpServerRequest,
  HttpServerResponse,
} from "effect/unstable/http"
import {
  reportUnexpectedError,
} from "../core/errors/errorReporter"
import {
  LegacyElysiaJsonParseError,
  parseLegacyElysiaBody,
} from "../core/http/legacyElysiaBody"
import {
  omitUndefinedObjectProperties,
} from "../core/http/jsonResponseCompatibility"
import {
  UNRESOLVED_CLIENT_IP,
} from "../core/http/middleware"
import {
  HttpRequestContext,
} from "../core/http/requestContext"
import {
  applyAdminSessionCookie,
} from "./adminCookies.effect"
import {
  AdminOperationFailure,
  AdminRejected,
  type AdminOperationResult,
  type AdminRequestInfo,
} from "./adminOperations.effect"
import {
  AdminSession,
  type AdminSessionValue,
} from "./adminSecurity.effect"

export class AdminTransportRejected extends Data.TaggedError(
  "AdminTransportRejected",
)<{
  readonly response: HttpServerResponse.HttpServerResponse
}> {
  override readonly [EffectErrorReporter.ignore] = true
}

class AdminResponseContractFailure extends Data.TaggedError(
  "AdminResponseContractFailure",
)<{
  readonly operation: string
}> {}

const json = (
  status: number,
  body: unknown,
  headers?: Readonly<Record<string, string>>,
): HttpServerResponse.HttpServerResponse =>
  HttpServerResponse.jsonUnsafe(body, {
    status,
    ...(headers === undefined ? {} : { headers }),
  })

const validationResponse = (
  target: "body" | "query" | "params",
): HttpServerResponse.HttpServerResponse =>
  json(422, {
    type: "validation",
    on: target,
    property: "root",
    message: "Validation error",
    summary: "Validation error",
    expected: {},
    errors: [],
  })

const decode = <A>(
  schema: Schema.Decoder<A>,
  value: unknown,
  target: "body" | "query" | "params",
): Effect.Effect<A, AdminTransportRejected> =>
  Schema.decodeUnknownEffect(schema)(value).pipe(
    Effect.mapError(
      () =>
        new AdminTransportRejected({
          response: validationResponse(target),
        }),
    ),
  )

const toWebRequest = (
  request: HttpServerRequest.HttpServerRequest,
) =>
  HttpServerRequest.toWeb(request).pipe(
    Effect.mapError(
      (cause) =>
        new AdminOperationFailure({
          operation: "admin.request.to-web",
          cause,
        }),
    ),
  )

const requestInfo = (
  request: HttpServerRequest.HttpServerRequest,
  webRequest: Request,
): Effect.Effect<
  AdminRequestInfo,
  never,
  HttpRequestContext
> =>
  HttpRequestContext.use((context) =>
    Effect.succeed({
      ip:
        context.clientIp === UNRESOLVED_CLIENT_IP
          ? undefined
          : context.clientIp,
      origin: request.headers["origin"],
      userAgent:
        request.headers["user-agent"] ?? "",
      publicOrigin: new URL(webRequest.url).origin,
      sessionToken:
        request.cookies["inline_admin_session"],
    }),
  )

export const decodeAdminBody = <A>(
  request: HttpServerRequest.HttpServerRequest,
  schema: Schema.Decoder<A>,
) =>
  Effect.gen(function* () {
    const webRequest = yield* toWebRequest(request)
    const body = yield* Effect.tryPromise({
      try: () => parseLegacyElysiaBody(webRequest),
      catch: (cause) =>
        cause instanceof LegacyElysiaJsonParseError
          ? new AdminTransportRejected({
              response: HttpServerResponse.text(
                "Bad Request",
                { status: 400 },
              ),
            })
          : new AdminOperationFailure({
              operation: "admin.request.body",
              cause,
            }),
    })
    return {
      input: yield* decode(schema, body, "body"),
      info: yield* requestInfo(request, webRequest),
    }
  })

const searchParamsRecord = (
  request: Request,
): Record<string, unknown> => {
  const result: Record<string, unknown> = {}
  for (const [key, value] of new URL(
    request.url,
  ).searchParams) {
    const existing = result[key]
    result[key] =
      existing === undefined
        ? value
        : Array.isArray(existing)
          ? [...existing, value]
          : [existing, value]
  }
  return result
}

export const decodeAdminQuery = <A>(
  request: HttpServerRequest.HttpServerRequest,
  schema: Schema.Decoder<A>,
) =>
  Effect.gen(function* () {
    const webRequest = yield* toWebRequest(request)
    return {
      input: yield* decode(
        schema,
        searchParamsRecord(webRequest),
        "query",
      ),
      info: yield* requestInfo(request, webRequest),
    }
  })

export const adminRequestInfo = (
  request: HttpServerRequest.HttpServerRequest,
) =>
  Effect.gen(function* () {
    const webRequest = yield* toWebRequest(request)
    return yield* requestInfo(request, webRequest)
  })

const pathSegments = (
  request: HttpServerRequest.HttpServerRequest,
) =>
  request.url
    .split("?", 1)[0]!
    .split("/")
    .filter(Boolean)

export const decodeAdminPathParam = <A>(
  request: HttpServerRequest.HttpServerRequest,
  segment: number,
  schema: Schema.Decoder<A>,
  invalid: {
    readonly status: number
    readonly error: string
    readonly empty?: boolean | undefined
  },
) =>
  Schema.decodeUnknownEffect(schema)(
    pathSegments(request)[segment],
  ).pipe(
    Effect.mapError(
      () =>
        new AdminRejected({
          status: invalid.status,
          error: invalid.error,
          empty: invalid.empty,
        }),
    ),
  )

const resultResponse = (
  result: AdminOperationResult,
) => {
  if (result.kind === "raw") {
    return Effect.succeed(
      result.body === null
        ? HttpServerResponse.empty({
            status: 200,
            headers: result.headers,
          })
        : HttpServerResponse.raw(result.body, {
            status: 200,
            headers: result.headers,
          }),
    )
  }

  const response = json(200, result.body)
  return result.sessionCookie === undefined
    ? Effect.succeed(response)
    : applyAdminSessionCookie(
        result.sessionCookie,
      ).pipe(Effect.as(response))
}

const rejectedResponse = (
  rejection: AdminRejected,
): HttpServerResponse.HttpServerResponse =>
  rejection.empty
    ? HttpServerResponse.empty({
        status: rejection.status,
      })
    : json(rejection.status, {
        ok: false,
        error: rejection.error,
      })

export const completeAdminRequest = <R>(
  operation: string,
  success: Schema.Decoder<unknown> | undefined,
  effect: Effect.Effect<
    AdminOperationResult,
    | AdminRejected
    | AdminOperationFailure
    | AdminTransportRejected,
    R
  >,
) =>
  effect.pipe(
    Effect.flatMap((result) => {
      if (result.kind === "raw" || success === undefined) {
        return resultResponse(result)
      }
      return Schema.decodeUnknownEffect(success)(
        omitUndefinedObjectProperties(result.body),
      ).pipe(
        Effect.mapError(
          () =>
            new AdminOperationFailure({
              operation,
              cause:
                new AdminResponseContractFailure({
                  operation,
                }),
            }),
        ),
        Effect.flatMap((body) =>
          resultResponse({
            ...result,
            body,
          }),
        ),
      )
    }),
    Effect.catch((failure) => {
      if (failure instanceof AdminTransportRejected) {
        return Effect.succeed(failure.response)
      }
      if (failure instanceof AdminRejected) {
        return Effect.succeed(
          rejectedResponse(failure),
        )
      }

      return Effect.gen(function* () {
        const context = yield* HttpRequestContext
        yield* reportUnexpectedError({
          cause: Cause.fail(failure.cause),
          context: {
            // Adapter failures carry a more precise stable leaf operation than
            // the route name (for example, lookup vs mutation vs notification).
            operation: failure.operation,
            requestId: context.requestId,
          },
        })
        return rejectedResponse(
          failure.publicError ??
            new AdminRejected({
              status: 500,
              error: "server_error",
            }),
        )
      })
    }),
  )

export const withAdminSession = <A, E, R>(
  run: (
    session: AdminSessionValue,
  ) => Effect.Effect<A, E, R>,
) => AdminSession.use(run)
