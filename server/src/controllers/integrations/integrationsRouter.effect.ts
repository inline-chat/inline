import {
  Context,
  Data,
  Duration,
  Effect,
  ErrorReporter as EffectErrorReporter,
  Schema,
} from "effect"
import {
  HttpServerRequest,
  HttpServerResponse,
} from "effect/unstable/http"
import {
  HttpApiEndpoint,
  HttpApiSchema,
  OpenApi,
} from "effect/unstable/httpapi"
import {
  SessionAuthentication,
} from "../plugins.effect"
import {
  AuxiliaryInternalServerError,
  AuxiliaryRequestParsingFailure,
  AuxiliaryRequestRejected,
  LegacyValidationError,
  decodeLegacyStringObject,
  queryRecord,
} from "../auxiliaryValidation.effect"
import type { ConnectorOAuthIdentity } from "@in/server/modules/integrations/connectorOAuthState"
import {
  canonicalConnectorCallbackScheme,
  connectorCallbackUrl,
} from "@in/server/modules/integrations/connectorCallbackScheme"
import { renderConnectorOAuthCompletionPage } from "@in/server/modules/integrations/connectorOAuthCompletionPage"

export type IntegrationProvider = "linear" | "notion"

export const IntegrationStartQuery = Schema.Struct({
  token: Schema.String,
  spaceId: Schema.String,
}).annotate({
  identifier: "IntegrationStartQuery",
})

export type IntegrationStartQuery =
  typeof IntegrationStartQuery.Type

export const IntegrationCallbackQuery = Schema.Struct({
  code: Schema.optionalKey(Schema.String),
  state: Schema.String,
  error: Schema.optionalKey(Schema.String),
}).annotate({
  identifier: "IntegrationCallbackQuery",
})

export type IntegrationCallbackQuery =
  typeof IntegrationCallbackQuery.Type

export const IntegrationErrorResponse = Schema.Struct({
  error: Schema.String,
}).annotate({
  identifier: "IntegrationErrorResponse",
})

const integrationErrorAt = (status: number) =>
  IntegrationErrorResponse.pipe(
    HttpApiSchema.status(status),
  )

const IntegrationStartInternalError = Schema.Union([
  IntegrationErrorResponse,
  Schema.Literal("Internal Server Error"),
]).pipe(
  HttpApiSchema.status(500),
).annotate({
  identifier: "IntegrationStartInternalError",
})

const IntegrationRedirect = HttpApiSchema.Empty(302)

const IntegrationCallbackHtml = Schema.String.pipe(
  HttpApiSchema.asText({
    contentType: "text/html; charset=utf-8",
  }),
).annotate({
  identifier: "IntegrationCallbackHtml",
})

const redirectDocs = OpenApi.annotations({
  transform: (operation) => {
    const response = operation["responses"]?.["302"]
    if (response !== undefined) {
      response.headers = {
        ...response.headers,
        Location: {
          description: "Redirect destination.",
          required: true,
          schema: {
            type: "string",
            format: "uri",
          },
        },
        "Set-Cookie": {
          description:
            "Short-lived integration authorization state.",
          schema: { type: "string" },
        },
      }
    }
    return operation
  },
})

const integrationErrors = [
  integrationErrorAt(400),
  integrationErrorAt(401),
  LegacyValidationError,
  IntegrationStartInternalError,
] as const

export const IntegrationEndpoints = {
  linearIntegrate: HttpApiEndpoint.get(
    "linearIntegrate",
    "/integrations/linear/integrate",
    {
      payload: IntegrationStartQuery.fields,
      success: IntegrationRedirect,
      error: integrationErrors,
    },
  ).annotateMerge(redirectDocs),
  linearCallback: HttpApiEndpoint.get(
    "linearCallback",
    "/integrations/linear/callback",
    {
      payload: IntegrationCallbackQuery.fields,
      success: IntegrationCallbackHtml,
      error: [
        integrationErrorAt(400),
        LegacyValidationError,
        AuxiliaryInternalServerError,
      ],
    },
  ),
  notionIntegrate: HttpApiEndpoint.get(
    "notionIntegrate",
    "/integrations/notion/integrate",
    {
      payload: IntegrationStartQuery.fields,
      success: IntegrationRedirect,
      error: integrationErrors,
    },
  ).annotateMerge(redirectDocs),
  notionCallback: HttpApiEndpoint.get(
    "notionCallback",
    "/integrations/notion/callback",
    {
      payload: IntegrationCallbackQuery.fields,
      success: IntegrationCallbackHtml,
      error: [
        integrationErrorAt(400),
        LegacyValidationError,
        AuxiliaryInternalServerError,
      ],
    },
  ),
} as const

export class IntegrationAuthorizationRejected extends Data.TaggedError(
  "IntegrationAuthorizationRejected",
)<{}> {
  override readonly [EffectErrorReporter.ignore] = true
}

export type IntegrationOperation =
  | "authenticate"
  | "authorize"
  | "claimState"
  | "generateState"
  | "linearAuthUrl"
  | "linearCallback"
  | "notionAuthUrl"
  | "notionCallback"
  | "responseCookies"

export class IntegrationOperationFailure extends Data.TaggedError(
  "IntegrationOperationFailure",
)<{
  readonly operation: IntegrationOperation
  readonly cause: unknown
  readonly publicResponse?:
    | HttpServerResponse.HttpServerResponse
    | undefined
}> {}

export interface IntegrationAuthUrl {
  readonly url: string | undefined
  readonly error?: string | undefined
}

export interface IntegrationCallbackResult {
  readonly ok: boolean
  readonly error?: string | undefined
}

export interface IntegrationOperationsShape {
  readonly secureCookies: boolean
  readonly authorizeAdmin: (
    spaceId: number,
    userId: number,
  ) => Effect.Effect<
    void,
    | IntegrationAuthorizationRejected
    | IntegrationOperationFailure
  >
  readonly generateState: Effect.Effect<
    string,
    IntegrationOperationFailure
  >
  readonly authUrl: (
    provider: IntegrationProvider,
    state: string,
  ) => Effect.Effect<
    IntegrationAuthUrl,
    IntegrationOperationFailure
  >
  readonly callback: (
    provider: IntegrationProvider,
    input: {
      readonly code: string
      readonly userId: number
      readonly spaceId: number | null
    },
  ) => Effect.Effect<
    IntegrationCallbackResult,
    IntegrationOperationFailure
  >
  readonly claimState: (
    provider: IntegrationProvider,
    state: string,
  ) => Effect.Effect<
    ConnectorOAuthIdentity | null,
    IntegrationOperationFailure
  >
}

export class IntegrationOperations extends Context.Service<
  IntegrationOperations,
  IntegrationOperationsShape
>()("@inline/server/auxiliary/IntegrationOperations") {}

export interface IntegrationOperationDependencies {
  readonly secureCookies: boolean
  readonly authorizeAdmin: (
    spaceId: number,
    userId: number,
  ) => Promise<unknown>
  readonly isAuthorizationRejected: (
    cause: unknown,
  ) => boolean
  readonly generateState: () => string
  readonly linearAuthUrl: (
    state: string,
  ) => IntegrationAuthUrl
  readonly notionAuthUrl: (
    state: string,
  ) => IntegrationAuthUrl
  readonly linearCallback: (input: {
    readonly code: string
    readonly userId: number
    readonly spaceId: number | null
  }) => Promise<IntegrationCallbackResult>
  readonly notionCallback: (input: {
    readonly code: string
    readonly userId: number
    readonly spaceId: number | null
  }) => Promise<IntegrationCallbackResult>
  readonly claimState: (
    provider: IntegrationProvider,
    state: string,
  ) => Promise<ConnectorOAuthIdentity | null>
}

export const makeIntegrationOperations = ({
  secureCookies,
  authorizeAdmin,
  isAuthorizationRejected,
  generateState,
  linearAuthUrl,
  notionAuthUrl,
  linearCallback,
  notionCallback,
  claimState,
}: IntegrationOperationDependencies): IntegrationOperationsShape => ({
  secureCookies,
  authorizeAdmin: (spaceId, userId) =>
    Effect.tryPromise({
      try: () => authorizeAdmin(spaceId, userId),
      catch: (cause) =>
        isAuthorizationRejected(cause)
          ? new IntegrationAuthorizationRejected()
          : new IntegrationOperationFailure({
              operation: "authorize",
              cause,
            }),
    }).pipe(Effect.asVoid),
  generateState: Effect.try({
    try: generateState,
    catch: (cause) =>
      new IntegrationOperationFailure({
        operation: "generateState",
        cause,
      }),
  }),
  authUrl: (provider, state) =>
    Effect.try({
      try: () =>
        provider === "linear"
          ? linearAuthUrl(state)
          : notionAuthUrl(state),
      catch: (cause) =>
        new IntegrationOperationFailure({
          operation:
            provider === "linear"
              ? "linearAuthUrl"
              : "notionAuthUrl",
          cause,
        }),
    }),
  callback: (provider, input) =>
    Effect.tryPromise({
      try: () =>
        provider === "linear"
          ? linearCallback(input)
          : notionCallback(input),
      catch: (cause) =>
        new IntegrationOperationFailure({
          operation:
            provider === "linear"
              ? "linearCallback"
              : "notionCallback",
          cause,
        }),
    }),
  claimState: (provider, state) =>
    Effect.tryPromise({
      try: () => claimState(provider, state),
      catch: (cause) =>
        new IntegrationOperationFailure({
          operation: "claimState",
          cause,
        }),
    }),
})

const startQueryFields = [
  { name: "token", required: true },
  { name: "spaceId", required: true },
] as const

const callbackQueryFields = [
  { name: "code", required: false },
  { name: "state", required: true },
  { name: "error", required: false },
] as const

const jsonError = (
  status: number,
  error: string,
): HttpServerResponse.HttpServerResponse =>
  HttpServerResponse.jsonUnsafe(
    { error },
    {
      status,
      headers: {
        "content-type":
          "application/json;charset=utf-8",
      },
    },
  )

const unauthorized = () =>
  jsonError(401, "Unauthorized")

const reject = (
  response: HttpServerResponse.HttpServerResponse,
) =>
  Effect.fail(
    new AuxiliaryRequestRejected({ response }),
  )

const authorizeAdmin = (
  token: string,
  spaceId: number,
  rejection: HttpServerResponse.HttpServerResponse,
) =>
  Effect.gen(function* () {
    const authentication =
      yield* SessionAuthentication
    const operations = yield* IntegrationOperations
    const identity =
      yield* authentication.authenticate(token).pipe(
        Effect.catchTags({
          SessionAuthenticationRejected: () =>
            reject(rejection),
          SessionAuthenticationFailure: (failure) =>
            Effect.fail(
              new IntegrationOperationFailure({
                operation: "authenticate",
                cause: failure.cause,
                publicResponse: rejection,
              }),
            ),
        }),
      )

    yield* operations.authorizeAdmin(
      spaceId,
      identity.userId,
    ).pipe(
      Effect.catchTags({
        IntegrationAuthorizationRejected: () =>
          reject(rejection),
        IntegrationOperationFailure: (failure) =>
          Effect.fail(
            new IntegrationOperationFailure({
              ...failure,
              publicResponse: rejection,
            }),
          ),
      }),
    )

    return identity.userId
  })

const cookieOptions = (
  secure: boolean,
  maxAge: Duration.Duration,
) => ({
  secure,
  path: "/",
  httpOnly: true,
  maxAge,
  sameSite: "lax" as const,
})

const attachCookies = (
  response: HttpServerResponse.HttpServerResponse,
  values: {
    readonly state: string
    readonly token: string
    readonly spaceId: string
  },
  secure: boolean,
  maxAge: Duration.Duration,
) =>
  HttpServerResponse.setCookies([
    [
      "state",
      values.state,
      cookieOptions(secure, maxAge),
    ],
    [
      "token",
      values.token,
      cookieOptions(secure, maxAge),
    ],
    [
      "spaceId",
      values.spaceId,
      cookieOptions(secure, maxAge),
    ],
  ])(response).pipe(
    Effect.mapError(
      (cause) =>
        new IntegrationOperationFailure({
          operation: "responseCookies",
          cause,
        }),
    ),
  )

const clearCookies = (
  response: HttpServerResponse.HttpServerResponse,
  secure: boolean,
) =>
  attachCookies(
    response,
    {
      state: "",
      token: "",
      spaceId: "",
    },
    secure,
    Duration.zero,
  )

const callbackCompletion = (
  provider: IntegrationProvider,
  suffix: string,
  scheme = canonicalConnectorCallbackScheme,
) => {
  const appUrl = connectorCallbackUrl(provider, suffix, scheme)
  const document = renderConnectorOAuthCompletionPage({
    provider,
    appUrl,
    succeeded: suffix === "success=true",
  })
  return HttpServerResponse.raw(
    new TextEncoder().encode(document),
    {
      status: 200,
      headers: {
        "cache-control": "no-store",
        "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        "content-type": "text/html; charset=utf-8",
        "referrer-policy": "no-referrer",
        "x-content-type-options": "nosniff",
      },
    },
  )
}

export const executeIntegrationStart = (
  provider: IntegrationProvider,
  request: HttpServerRequest.HttpServerRequest,
) =>
  Effect.gen(function* () {
    const webRequest =
      yield* HttpServerRequest.toWeb(request).pipe(
        Effect.mapError(
          (cause) =>
            new AuxiliaryRequestParsingFailure({
              cause,
            }),
        ),
      )
    const query = yield* decodeLegacyStringObject(
      IntegrationStartQuery,
      "query",
      queryRecord(webRequest),
      startQueryFields,
    )

    if (query.token === "") {
      return yield* reject(
        jsonError(400, "Token is required"),
      )
    }

    const spaceId = Number(query.spaceId)
    if (Number.isNaN(spaceId)) {
      return yield* reject(
        jsonError(400, "spaceId is required"),
      )
    }

    yield* authorizeAdmin(
      query.token,
      spaceId,
      unauthorized(),
    )

    const operations = yield* IntegrationOperations
    const state = yield* operations.generateState
    const auth = yield* operations.authUrl(
      provider,
      state,
    )
    const values = {
      state,
      token: query.token,
      spaceId: query.spaceId,
    }
    if (auth.url === undefined) {
      const message =
        provider === "linear"
          ? "Linear auth URL not found"
          : auth.error ??
            "Notion auth URL not found"
      return yield* attachCookies(
        jsonError(500, message),
        values,
        operations.secureCookies,
        Duration.seconds(600),
      )
    }

    return yield* attachCookies(
      HttpServerResponse.redirect(auth.url),
      values,
      operations.secureCookies,
      Duration.seconds(600),
    )
  })

export const executeIntegrationCallback = (
  provider: IntegrationProvider,
  request: HttpServerRequest.HttpServerRequest,
) =>
  Effect.gen(function* () {
    const webRequest =
      yield* HttpServerRequest.toWeb(request).pipe(
        Effect.mapError(
          (cause) =>
            new AuxiliaryRequestParsingFailure({
              cause,
            }),
        ),
      )
    const query = yield* decodeLegacyStringObject(
      IntegrationCallbackQuery,
      "query",
      queryRecord(webRequest),
      callbackQueryFields,
    )
    const operations = yield* IntegrationOperations
    const token = request.cookies["token"]
    const state = request.cookies["state"]
    const spaceIdCookie = request.cookies["spaceId"]
    const claimed = yield* operations.claimState(
      provider,
      query.state,
    )
    let callbackIdentity: ConnectorOAuthIdentity

    if (claimed) {
      callbackIdentity = claimed
      if (claimed.spaceId !== null) {
        const authRejection = yield* clearCookies(
          callbackCompletion(
            provider,
            "success=false&error=unauthorized",
            claimed.callbackScheme,
          ),
          operations.secureCookies,
        )
        yield* operations.authorizeAdmin(
          claimed.spaceId,
          claimed.userId,
        ).pipe(
          Effect.catchTags({
            IntegrationAuthorizationRejected: () =>
              reject(authRejection),
            IntegrationOperationFailure: (failure) =>
              Effect.fail(
                new IntegrationOperationFailure({
                  ...failure,
                  publicResponse: authRejection,
                }),
              ),
          }),
        )
      }
    } else {
      if (
        !token ||
        !state ||
        !spaceIdCookie
      ) {
        return yield* clearCookies(
          jsonError(400, "OAuth session expired or was already used"),
          operations.secureCookies,
        )
      }

      if (query.state !== state) {
        return yield* clearCookies(
          jsonError(400, "OAuth state did not match this browser session"),
          operations.secureCookies,
        )
      }

      const spaceId = Number(spaceIdCookie)
      if (Number.isNaN(spaceId)) {
        return yield* clearCookies(
          callbackCompletion(
            provider,
            "success=false&error=invalid_space",
          ),
          operations.secureCookies,
        )
      }

      const authRejection = yield* clearCookies(
        callbackCompletion(
          provider,
          "success=false&error=unauthorized",
        ),
        operations.secureCookies,
      )
      const userId = yield* authorizeAdmin(
        token,
        spaceId,
        authRejection,
      )
      callbackIdentity = {
        userId,
        spaceId,
        callbackScheme: canonicalConnectorCallbackScheme,
      }
    }

    if (query.error !== undefined || query.code === undefined) {
      const error = query.error === "access_denied"
        ? "authorization_cancelled"
        : query.error !== undefined
          ? "authorization_failed"
          : "missing_code"
      return yield* clearCookies(
        callbackCompletion(
          provider,
          `success=false&error=${error}`,
          callbackIdentity.callbackScheme,
        ),
        operations.secureCookies,
      )
    }

    const result = yield* operations.callback(
      provider,
      {
        code: query.code,
        userId: callbackIdentity.userId,
        spaceId: callbackIdentity.spaceId,
      },
    )

    if (!result.ok) {
      const error =
        provider === "linear"
          ? typeof result.error === "string" &&
            result.error.length > 0
            ? result.error
            : "callback_failed"
          : "callback_failed"
      return yield* clearCookies(
        callbackCompletion(
          provider,
          `success=false&error=${encodeURIComponent(error)}`,
          callbackIdentity.callbackScheme,
        ),
        operations.secureCookies,
      )
    }

    return yield* clearCookies(
      callbackCompletion(
        provider,
        "success=true",
        callbackIdentity.callbackScheme,
      ),
      operations.secureCookies,
    )
  })
