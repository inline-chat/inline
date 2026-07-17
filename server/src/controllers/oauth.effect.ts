import {
  Cause,
  Data,
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
  OpenApi,
} from "effect/unstable/httpapi"
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
  OAuthHttpService,
  OAuthHttpFailure,
  type OAuthHttpOperation,
} from "../modules/oauth/httpService.effect"
import {
  UnixSeconds,
  WireNonNegativeInteger,
} from "../core/schema/scalars"

const OptionalString = Schema.optionalKey(Schema.String)

export const OAuthMetadata = Schema.Struct({
  issuer: Schema.String,
  authorization_endpoint: Schema.String,
  token_endpoint: Schema.String,
  registration_endpoint: Schema.String,
  revocation_endpoint: Schema.String,
  scopes_supported: Schema.Array(Schema.String),
  response_types_supported: Schema.Array(Schema.String),
  grant_types_supported: Schema.Array(Schema.String),
  token_endpoint_auth_methods_supported: Schema.Array(Schema.String),
  code_challenge_methods_supported: Schema.Array(Schema.String),
}).annotate({
  identifier: "OAuthAuthorizationServerMetadata",
})

export const OAuthRegisterInput = Schema.Struct({
  redirect_uris: Schema.Array(Schema.String),
  client_name: OptionalString,
}).annotate({
  identifier: "OAuthRegisterInput",
})

export const OAuthRegisterResult = Schema.Struct({
  client_id: Schema.String,
  client_id_issued_at: UnixSeconds,
  redirect_uris: Schema.Array(Schema.String),
  client_name: OptionalString,
  token_endpoint_auth_method: Schema.String,
  grant_types: Schema.Array(Schema.String),
  response_types: Schema.Array(Schema.String),
}).pipe(HttpApiSchema.status(201)).annotate({
  identifier: "OAuthRegisterResult",
})

const OAuthAuthorizeQuery = {
  response_type: OptionalString,
  client_id: OptionalString,
  redirect_uri: OptionalString,
  state: OptionalString,
  scope: OptionalString,
  code_challenge: OptionalString,
  code_challenge_method: OptionalString,
} as const

const OAuthEmailPayload = Schema.Struct({
  csrf: OptionalString,
  email: OptionalString,
}).annotate({
  identifier: "OAuthEmailCodeForm",
})

const OAuthVerificationPayload = Schema.Struct({
  csrf: OptionalString,
  code: OptionalString,
}).annotate({
  identifier: "OAuthEmailVerificationForm",
})

const OAuthConsentPayload = Schema.Struct({
  csrf: OptionalString,
  space_id: Schema.optionalKey(
    Schema.Union([
      Schema.String,
      Schema.Array(Schema.String),
    ]),
  ),
  allow_dms: OptionalString,
  allow_home_threads: OptionalString,
}).annotate({
  identifier: "OAuthConsentForm",
})

const OAuthTokenPayload = Schema.Struct({
  grant_type: OptionalString,
  code: OptionalString,
  client_id: OptionalString,
  redirect_uri: OptionalString,
  code_verifier: OptionalString,
  refresh_token: OptionalString,
}).annotate({
  identifier: "OAuthTokenForm",
})

const OAuthRevokePayload = Schema.Struct({
  token: OptionalString,
}).annotate({
  identifier: "OAuthRevokeForm",
})

const OAuthIntrospectPayload = Schema.Struct({
  token: OptionalString,
}).annotate({
  identifier: "OAuthIntrospectForm",
})

const oauthPayloads = <
  S extends Schema.Top & Schema.Decoder<unknown>,
>(
  schema: S,
) => [
  schema,
  schema.pipe(HttpApiSchema.asFormUrlEncoded()),
  schema.pipe(HttpApiSchema.asMultipart()),
] as const

const OAuthHtml = Schema.String.pipe(
  HttpApiSchema.asText({
    contentType: "text/html; charset=utf-8",
  }),
).annotate({
  identifier: "OAuthHtml",
})

const htmlAt = (status: number) =>
  OAuthHtml.pipe(HttpApiSchema.status(status))

const OAuthError = Schema.Struct({
  error: Schema.String,
  error_description: OptionalString,
}).annotate({
  identifier: "OAuthError",
})

const jsonErrorAt = (status: number) =>
  OAuthError.pipe(HttpApiSchema.status(status))

const OAuthTransportBadRequest = Schema.Literal(
  "Bad Request",
).pipe(
  HttpApiSchema.status(400),
  HttpApiSchema.asText(),
).annotate({
  identifier: "OAuthTransportBadRequest",
})

export const OAuthTokenResult = Schema.Struct({
  access_token: Schema.String,
  refresh_token: OptionalString,
  token_type: Schema.String,
  expires_in: WireNonNegativeInteger,
  scope: Schema.String,
}).annotate({
  identifier: "OAuthTokenResult",
})

export const OAuthIntrospectionResult = Schema.Struct({
  active: Schema.Literal(true),
  grant_id: Schema.String,
  client_id: Schema.String,
  scope: Schema.String,
  exp: UnixSeconds,
  inline_user_id: Schema.String,
  space_ids: Schema.Array(Schema.String),
  allow_dms: Schema.Boolean,
  allow_home_threads: Schema.Boolean,
  inline_token: Schema.String,
}).annotate({
  identifier: "OAuthIntrospectionResult",
})

const OAuthInactive = Schema.Struct({
  active: Schema.Literal(false),
}).pipe(HttpApiSchema.status(401)).annotate({
  identifier: "OAuthInactiveToken",
})

const OAuthEmptyObject = Schema.Struct({}).annotate({
  identifier: "OAuthEmptyObject",
})

const OAuthRedirect = HttpApiSchema.NoContent.pipe(
  HttpApiSchema.status(302),
)

const oauthJsonErrors = [
  jsonErrorAt(400),
  jsonErrorAt(401),
  jsonErrorAt(429),
  jsonErrorAt(500),
] as const

const oauthEndpointErrors = [
  OAuthTransportBadRequest,
  ...oauthJsonErrors,
] as const

const oauthHtmlErrors = [
  OAuthTransportBadRequest,
  htmlAt(400),
  htmlAt(401),
  htmlAt(429),
  htmlAt(500),
  htmlAt(502),
] as const

const cacheControlHeader = {
  description: "Response caching policy.",
  schema: { type: "string" },
} as const

const locationHeader = {
  description: "OAuth client redirect target.",
  required: true,
  schema: {
    type: "string",
    format: "uri",
  },
} as const

const retryAfterHeader = {
  description: "Whole seconds to wait before retrying.",
  required: true,
  schema: {
    type: "integer",
    minimum: 1,
  },
} as const

const setCookieHeader = {
  description: "OAuth authorization-request cookie.",
  required: true,
  schema: { type: "string" },
} as const

const oauthOperationDocs = ({
  optionalBody = false,
  responseHeaders = {},
}: {
  readonly optionalBody?: boolean | undefined
  readonly responseHeaders?: Readonly<
    Record<string, Readonly<Record<string, unknown>>>
  >
}) =>
  OpenApi.annotations({
    transform: (operation) => {
      if (
        optionalBody &&
        operation["requestBody"] !== undefined
      ) {
        operation["requestBody"].required = false
      }

      for (
        const [status, headers] of Object.entries(
          responseHeaders,
        )
      ) {
        const response = operation["responses"]?.[status]
        if (response !== undefined) {
          response.headers = {
            ...response.headers,
            ...headers,
          }
        }
      }

      return operation
    },
  })

const OAuthEndpointGroup = HttpApiGroup.make("oauth")
  .add(
    HttpApiEndpoint.get(
      "oauthMetadata",
      "/.well-known/oauth-authorization-server",
      {
        success: OAuthMetadata,
        error: jsonErrorAt(500),
      },
    ),
  )
  .add(
    HttpApiEndpoint.post(
      "oauthRegister",
      "/oauth/register",
      {
        payload: oauthPayloads(OAuthRegisterInput),
        success: OAuthRegisterResult,
        error: oauthEndpointErrors,
      },
    ).annotateMerge(
      oauthOperationDocs({
        responseHeaders: {
          "201": {
            "Cache-Control": cacheControlHeader,
          },
          "429": {
            "Retry-After": retryAfterHeader,
          },
        },
      }),
    ),
  )
  .add(
    HttpApiEndpoint.post(
      "oauthRegisterAlias",
      "/register",
      {
        payload: oauthPayloads(OAuthRegisterInput),
        success: OAuthRegisterResult,
        error: oauthEndpointErrors,
      },
    ).annotateMerge(
      oauthOperationDocs({
        responseHeaders: {
          "201": {
            "Cache-Control": cacheControlHeader,
          },
          "429": {
            "Retry-After": retryAfterHeader,
          },
        },
      }),
    ),
  )
  .add(
    HttpApiEndpoint.get("oauthAuthorize", "/oauth/authorize", {
      query: OAuthAuthorizeQuery,
      success: OAuthHtml,
      error: oauthJsonErrors,
    }).annotateMerge(
      oauthOperationDocs({
        responseHeaders: {
          "200": {
            "Cache-Control": cacheControlHeader,
            "Set-Cookie": setCookieHeader,
          },
        },
      }),
    ),
  )
  .add(
    HttpApiEndpoint.get("oauthAuthorizeAlias", "/authorize", {
      query: OAuthAuthorizeQuery,
      success: OAuthHtml,
      error: oauthJsonErrors,
    }).annotateMerge(
      oauthOperationDocs({
        responseHeaders: {
          "200": {
            "Cache-Control": cacheControlHeader,
            "Set-Cookie": setCookieHeader,
          },
        },
      }),
    ),
  )
  .add(
    HttpApiEndpoint.post(
      "oauthSendEmailCode",
      "/oauth/authorize/send-email-code",
      {
        payload: oauthPayloads(OAuthEmailPayload),
        success: OAuthHtml,
        error: oauthHtmlErrors,
      },
    ).annotateMerge(
      oauthOperationDocs({
        responseHeaders: {
          "200": {
            "Cache-Control": cacheControlHeader,
          },
          "429": {
            "Retry-After": retryAfterHeader,
          },
        },
      }),
    ),
  )
  .add(
    HttpApiEndpoint.post(
      "oauthVerifyEmailCode",
      "/oauth/authorize/verify-email-code",
      {
        payload: oauthPayloads(
          OAuthVerificationPayload,
        ),
        success: OAuthHtml,
        error: oauthHtmlErrors,
      },
    ).annotateMerge(
      oauthOperationDocs({
        responseHeaders: {
          "200": {
            "Cache-Control": cacheControlHeader,
          },
          "429": {
            "Retry-After": retryAfterHeader,
          },
        },
      }),
    ),
  )
  .add(
    HttpApiEndpoint.post(
      "oauthConsent",
      "/oauth/authorize/consent",
      {
        payload: oauthPayloads(OAuthConsentPayload),
        success: [OAuthHtml, OAuthRedirect],
        error: oauthHtmlErrors,
      },
    ).annotateMerge(
      oauthOperationDocs({
        responseHeaders: {
          "302": {
            Location: locationHeader,
            "Set-Cookie": setCookieHeader,
          },
        },
      }),
    ),
  )
  .add(
    HttpApiEndpoint.post(
      "oauthToken",
      "/oauth/token",
      {
        payload: oauthPayloads(OAuthTokenPayload),
        success: OAuthTokenResult,
        error: oauthEndpointErrors,
      },
    ).annotateMerge(
      oauthOperationDocs({
        responseHeaders: {
          "200": {
            "Cache-Control": cacheControlHeader,
          },
          "429": {
            "Retry-After": retryAfterHeader,
          },
        },
      }),
    ),
  )
  .add(
    HttpApiEndpoint.post(
      "oauthTokenAlias",
      "/token",
      {
        payload: oauthPayloads(OAuthTokenPayload),
        success: OAuthTokenResult,
        error: oauthEndpointErrors,
      },
    ).annotateMerge(
      oauthOperationDocs({
        responseHeaders: {
          "200": {
            "Cache-Control": cacheControlHeader,
          },
          "429": {
            "Retry-After": retryAfterHeader,
          },
        },
      }),
    ),
  )
  .add(
    HttpApiEndpoint.post(
      "oauthRevoke",
      "/oauth/revoke",
      {
        payload: oauthPayloads(OAuthRevokePayload),
        success: OAuthEmptyObject,
        error: oauthEndpointErrors,
      },
    ).annotateMerge(
      oauthOperationDocs({
        optionalBody: true,
        responseHeaders: {
          "200": {
            "Cache-Control": cacheControlHeader,
          },
        },
      }),
    ),
  )
  .add(
    HttpApiEndpoint.post(
      "oauthRevokeAlias",
      "/revoke",
      {
        payload: oauthPayloads(OAuthRevokePayload),
        success: OAuthEmptyObject,
        error: oauthEndpointErrors,
      },
    ).annotateMerge(
      oauthOperationDocs({
        optionalBody: true,
        responseHeaders: {
          "200": {
            "Cache-Control": cacheControlHeader,
          },
        },
      }),
    ),
  )
  .add(
    HttpApiEndpoint.post("oauthIntrospect", "/oauth/introspect", {
      payload: oauthPayloads(OAuthIntrospectPayload),
      headers: {
        "x-inline-mcp-secret":
          Schema.optionalKey(Schema.String),
      },
      success: OAuthIntrospectionResult,
      error: [
        OAuthTransportBadRequest,
        jsonErrorAt(400),
        jsonErrorAt(401),
        OAuthInactive,
        jsonErrorAt(500),
      ],
    }).annotateMerge(
      requireOpenApiRequestHeader(
        "x-inline-mcp-secret",
        "Required shared secret for the internal MCP boundary.",
      ),
    ),
  )

export const OAuthEndpoints = OAuthEndpointGroup.endpoints

type OAuthResponseMediaType =
  | "application/json"
  | "text/html"
  | "none"

interface OAuthResponseVariant {
  readonly status: number
  readonly mediaType: OAuthResponseMediaType
  readonly schema?: Schema.Decoder<unknown> | undefined
  readonly requiredHeaders?: ReadonlyArray<string> | undefined
}

const jsonVariant = (
  status: number,
  schema: Schema.Decoder<unknown>,
  requiredHeaders?: ReadonlyArray<string>,
): OAuthResponseVariant => ({
  status,
  mediaType: "application/json",
  schema,
  requiredHeaders,
})

const htmlVariant = (
  status: number,
  requiredHeaders?: ReadonlyArray<string>,
): OAuthResponseVariant => ({
  status,
  mediaType: "text/html",
  schema: OAuthHtml,
  requiredHeaders,
})

const badRequestVariant: OAuthResponseVariant = {
  status: 400,
  mediaType: "none",
  schema: Schema.Literal("Bad Request"),
}

const oauthErrorVariants = [
  jsonVariant(400, OAuthError),
  jsonVariant(401, OAuthError),
  jsonVariant(429, OAuthError, ["retry-after"]),
  jsonVariant(500, OAuthError),
] as const

const oauthHtmlErrorVariants = [
  htmlVariant(400),
  htmlVariant(401),
  htmlVariant(429, ["retry-after"]),
  htmlVariant(500),
  htmlVariant(502),
] as const

const oauthResponseContracts: Readonly<
  Record<
    OAuthHttpOperation,
    ReadonlyArray<OAuthResponseVariant>
  >
> = {
  metadata: [
    jsonVariant(200, OAuthMetadata),
  ],
  register: [
    jsonVariant(201, OAuthRegisterResult, [
      "cache-control",
    ]),
    badRequestVariant,
    ...oauthErrorVariants,
  ],
  authorize: [
    htmlVariant(200, [
      "cache-control",
      "set-cookie",
    ]),
    ...oauthErrorVariants,
  ],
  sendEmailCode: [
    htmlVariant(200, ["cache-control"]),
    badRequestVariant,
    ...oauthHtmlErrorVariants,
  ],
  verifyEmailCode: [
    htmlVariant(200, ["cache-control"]),
    badRequestVariant,
    ...oauthHtmlErrorVariants,
  ],
  consent: [
    {
      status: 302,
      mediaType: "none",
      requiredHeaders: ["location", "set-cookie"],
    },
    badRequestVariant,
    ...oauthHtmlErrorVariants,
  ],
  token: [
    jsonVariant(200, OAuthTokenResult, [
      "cache-control",
    ]),
    badRequestVariant,
    ...oauthErrorVariants,
  ],
  revoke: [
    jsonVariant(200, OAuthEmptyObject, [
      "cache-control",
    ]),
    badRequestVariant,
    ...oauthErrorVariants,
  ],
  introspect: [
    jsonVariant(200, OAuthIntrospectionResult),
    badRequestVariant,
    jsonVariant(400, OAuthError),
    jsonVariant(
      401,
      Schema.Union([OAuthError, OAuthInactive]),
    ),
    jsonVariant(500, OAuthError),
  ],
}

export class OAuthResponseContractFailure extends Data.TaggedError(
  "OAuthResponseContractFailure",
)<{
  readonly operation: OAuthHttpOperation
  readonly status: number
  readonly cause: unknown
}> {}

const normalizedMediaType = (
  response: Response,
): string | undefined =>
  response.headers
    .get("content-type")
    ?.split(";", 1)[0]
    ?.trim()
    .toLowerCase()

const variantMatchesMediaType = (
  variant: OAuthResponseVariant,
  mediaType: string | undefined,
): boolean =>
  variant.mediaType === "none"
    ? mediaType === undefined
    : variant.mediaType === mediaType

export const validateOAuthResponse = (
  operation: OAuthHttpOperation,
  response: Response,
) =>
  Effect.gen(function* () {
    const mediaType = normalizedMediaType(response)
    const variant = oauthResponseContracts[operation].find(
      (candidate) =>
        candidate.status === response.status &&
        variantMatchesMediaType(candidate, mediaType),
    )

    if (variant === undefined) {
      return yield* Effect.fail(
        new OAuthResponseContractFailure({
          operation,
          status: response.status,
          cause: new Error(
            `Undeclared OAuth response status/media type: ${response.status} ${mediaType ?? "<none>"}`,
          ),
        }),
      )
    }

    for (const header of variant.requiredHeaders ?? []) {
      if (!response.headers.get(header)?.trim()) {
        return yield* Effect.fail(
          new OAuthResponseContractFailure({
            operation,
            status: response.status,
            cause: new Error(
              `OAuth response omitted required ${header} header`,
            ),
          }),
        )
      }
    }

    const body = yield* Effect.tryPromise({
      try: async () => {
        const copy = response.clone()
        if (variant.mediaType === "application/json") {
          return await copy.json()
        }
        return await copy.text()
      },
      catch: (cause) =>
        new OAuthResponseContractFailure({
          operation,
          status: response.status,
          cause,
        }),
    })

    if (variant.schema !== undefined) {
      yield* Schema.decodeUnknownEffect(
        variant.schema,
        {
          onExcessProperty: "error",
        },
      )(body).pipe(
        Effect.mapError((cause) =>
          new OAuthResponseContractFailure({
            operation,
            status: response.status,
            cause,
          }),
        ),
      )
    } else if (body !== "") {
      return yield* Effect.fail(
        new OAuthResponseContractFailure({
          operation,
          status: response.status,
          cause: new Error(
            "OAuth no-content response contained a body",
          ),
        }),
      )
    }

    return response
  })

const webResponseToEffect = (
  response: Response,
): HttpServerResponse.HttpServerResponse => {
  const options = {
    status: response.status,
    statusText: response.statusText,
    headers: Object.fromEntries(response.headers),
  }

  return response.body === null
    ? HttpServerResponse.empty(options)
    : HttpServerResponse.raw(response.body, options)
}

const serverError = (): HttpServerResponse.HttpServerResponse =>
  HttpServerResponse.jsonUnsafe(
    {
      error: "server_error",
      error_description: "Server error",
    },
    {
      status: 500,
      headers: {
        "cache-control": "no-store",
      },
    },
  )

export const executeOAuth = (
  operation: OAuthHttpOperation,
  request: HttpServerRequest.HttpServerRequest,
) =>
  Effect.gen(function* () {
    const webRequest = yield* HttpServerRequest.toWeb(request)
    const context = yield* HttpRequestContext
    const service = yield* OAuthHttpService
    const response = yield* service.execute(operation, {
      request: webRequest,
      clientIp: context.clientIp,
    })
    return webResponseToEffect(
      yield* validateOAuthResponse(
        operation,
        response,
      ),
    )
  }).pipe(
    Effect.catch((failure) =>
      Effect.gen(function* () {
        const context = yield* HttpRequestContext
        yield* reportUnexpectedError({
          cause: Cause.fail(
            failure instanceof OAuthHttpFailure
              ? failure.cause
              : failure,
          ),
          context: {
            operation: `oauth.${operation}`,
            requestId: context.requestId,
          },
        })

        if (
          failure instanceof OAuthHttpFailure &&
          failure.publicResponse !== undefined
        ) {
          const response = yield* validateOAuthResponse(
            operation,
            failure.publicResponse,
          ).pipe(
            Effect.catch(() => Effect.succeed(undefined)),
          )
          if (response !== undefined) {
            return webResponseToEffect(response)
          }
        }

        return serverError()
      }),
    ),
  )
