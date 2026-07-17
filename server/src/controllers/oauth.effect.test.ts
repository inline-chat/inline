import { describe, expect, it } from "@effect/vitest"
import {
  Context,
  Effect,
  ErrorReporter as EffectErrorReporter,
  Layer,
} from "effect"
import Elysia from "elysia"
import {
  HttpRouter,
  HttpServer,
} from "effect/unstable/http"
import {
  OpenApi,
} from "effect/unstable/httpapi"
import {
  ErrorReporter,
  type ErrorReporterShape,
} from "../core/errors/errorReporter"
import {
  defineExecutableHttpApi,
  makeHttpApplication,
} from "../core/http/application"
import { RequestId } from "../core/helpers/requestId"
import {
  defineOpenApiDocument,
  makeBotApiBase,
  makePlatformApiBase,
} from "../core/http/openApi"
import {
  assertValidOpenApiDocument,
} from "../core/http/openApiValidation"
import {
  HttpRequestContext,
} from "../core/http/requestContext"
import {
  OAuthHttpFailure,
  OAuthHttpService,
  type OAuthHttpServiceShape,
} from "../modules/oauth/httpService.effect"
import {
  makeOAuthHttpService,
  type OAuthHttpHandlers,
} from "../modules/oauth/httpServiceAdapter.effect"
import {
  IdentityOperations,
  type IdentityOperationsShape,
} from "../modules/auth/identityOperations.effect"
import {
  AuthApiGroup,
  makeAuthRouteGroup,
} from "./auth.effect"
import {
  SessionAuthentication,
  type SessionAuthenticationShape,
} from "./plugins.effect"
import {
  OAuthResponseContractFailure,
  validateOAuthResponse,
} from "./oauth.effect"

const unusedIdentity = (name: string) =>
  Effect.die(
    new Error(`Unexpected identity operation: ${name}`),
  )

const identityOperations: IdentityOperationsShape = {
  sendSmsCode: () => unusedIdentity("sendSmsCode"),
  verifySmsCode: () => unusedIdentity("verifySmsCode"),
  sendEmailCode: () => unusedIdentity("sendEmailCode"),
  verifyEmailCode: () => unusedIdentity("verifyEmailCode"),
  checkInviteCode: () => unusedIdentity("checkInviteCode"),
  logout: () => unusedIdentity("logout"),
}

const sessionAuthentication: SessionAuthenticationShape = {
  authenticate: () => unusedIdentity("authenticate"),
}

const makeKernel = ({
  oauth,
  reporter = {
    report: () => Effect.void,
  },
  trustedClientIpHeader,
}: {
  readonly oauth: OAuthHttpServiceShape
  readonly reporter?: ErrorReporterShape | undefined
  readonly trustedClientIpHeader?:
    | "cf-connecting-ip"
    | "x-real-ip"
    | undefined
}) => {
  const routeGroup = makeAuthRouteGroup()
  const platformApi = makePlatformApiBase(
    "https://api.inline.chat",
  ).add(AuthApiGroup)
  const botApi = makeBotApiBase("https://api.inline.chat")
  const application = makeHttpApplication({
    platform: defineExecutableHttpApi({
      ...defineOpenApiDocument({
        api: platformApi,
        jsonPath: "/v1/reference/json",
        swaggerPath: "/v1/reference",
      }),
      handlers: routeGroup.handlers,
    }),
    bot: defineExecutableHttpApi({
      ...defineOpenApiDocument({
        api: botApi,
        jsonPath: "/bot-api-reference/json",
        swaggerPath: "/bot-api-reference",
      }),
      handlers: Layer.empty,
    }),
    middleware: {
      clientIpHeader: trustedClientIpHeader,
      isProduction: false,
    },
  }).pipe(
    Layer.provide(HttpServer.layerServices),
    Layer.provide(EffectErrorReporter.layer([])),
    Layer.provide(Layer.succeed(ErrorReporter)(reporter)),
    Layer.provide(Layer.succeed(OAuthHttpService)(oauth)),
    Layer.provide(
      Layer.merge(
        Layer.succeed(IdentityOperations)(
          identityOperations,
        ),
        Layer.succeed(SessionAuthentication)(
          sessionAuthentication,
        ),
      ),
    ),
  )
  const webHandler = HttpRouter.toWebHandler(application, {
    disableLogger: true,
  })
  const context = Context.make(HttpRequestContext, {
    clientIp: "unresolved-client",
    method: "GET",
    path: "/test",
    requestId: RequestId.make("oauth-test"),
    startedAtMillis: 0,
  }).pipe(
    Context.add(OAuthHttpService, oauth),
    Context.add(IdentityOperations, identityOperations),
    Context.add(
      SessionAuthentication,
      sessionAuthentication,
    ),
    Context.add(ErrorReporter, reporter),
  )

  return {
    dispose: webHandler.dispose,
    handler: (request: Request) =>
      webHandler.handler(request, context),
  }
}

describe("Effect OAuth routes", () => {
  it("preserves aliases, Web response metadata, and explicit client IP trust", async () => {
    let invocation:
      | {
        readonly operation: string
        readonly clientIp: string | undefined
        readonly payload: unknown
      }
      | undefined
    const kernel = makeKernel({
      trustedClientIpHeader: "x-real-ip",
      oauth: {
        execute: (operation, input) =>
          Effect.tryPromise({
            try: async () => {
              invocation = {
                operation,
                clientIp: input.clientIp,
                payload: await input.request.json(),
              }
              return new Response(
                JSON.stringify({
                  client_id: "client-1",
                  client_id_issued_at: 1_700_000_000,
                  redirect_uris: [
                    "https://client.example/callback",
                  ],
                  token_endpoint_auth_method: "none",
                  grant_types: [
                    "authorization_code",
                    "refresh_token",
                  ],
                  response_types: ["code"],
                }),
                {
                  status: 201,
                  headers: {
                    "cache-control": "no-store",
                    "content-type": "application/json",
                  },
                },
              )
            },
            catch: (cause) =>
              new OAuthHttpFailure({
                operation,
                cause,
              }),
          }),
      },
    })

    try {
      const response = await kernel.handler(
        new Request("http://inline.test/register", {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-real-ip": "203.0.113.9",
            "x-forwarded-for": "198.51.100.12",
          },
          body: JSON.stringify({
            redirect_uris: [
              "https://client.example/callback",
            ],
          }),
        }),
      )

      expect(response.status).toBe(201)
      expect(response.headers.get("cache-control")).toBe(
        "no-store",
      )
      expect(await response.json()).toMatchObject({
        client_id: "client-1",
      })
      expect(invocation).toEqual({
        operation: "register",
        clientIp: "203.0.113.9",
        payload: {
          redirect_uris: [
            "https://client.example/callback",
          ],
        },
      })
    } finally {
      await kernel.dispose()
    }
  })

  it("reports an unexpected service failure once and returns an opaque OAuth error", async () => {
    let reports = 0
    const kernel = makeKernel({
      reporter: {
        report: () =>
          Effect.sync(() => {
            reports += 1
          }),
      },
      oauth: {
        execute: (operation) =>
          Effect.fail(
            new OAuthHttpFailure({
              operation,
              cause: new Error("private database detail"),
            }),
          ),
      },
    })

    try {
      const response = await kernel.handler(
        new Request(
          "http://inline.test/.well-known/oauth-authorization-server",
        ),
      )

      expect(response.status).toBe(500)
      expect(await response.json()).toEqual({
        error: "server_error",
        error_description: "Server error",
      })
      expect(reports).toBe(1)
    } finally {
      await kernel.dispose()
    }
  })

  it("preserves authorization cookies and consent redirects", async () => {
    const kernel = makeKernel({
      oauth: {
        execute: (operation) => {
          if (operation === "authorize") {
            return Effect.succeed(
              new Response("<html>Authorize</html>", {
                headers: {
                  "cache-control": "no-store",
                  "content-type":
                    "text/html; charset=utf-8",
                  "set-cookie":
                    "inline_ar=request; Path=/oauth; HttpOnly",
                },
              }),
            )
          }
          if (operation === "consent") {
            return Effect.succeed(
              new Response(null, {
                status: 302,
                headers: {
                  location:
                    "https://client.example/callback?code=code&state=state",
                  "set-cookie":
                    "inline_ar=; Max-Age=0; Path=/oauth; HttpOnly",
                },
              }),
            )
          }
          return unusedIdentity(operation)
        },
      },
    })

    try {
      const authorize = await kernel.handler(
        new Request(
          "http://inline.test/authorize?response_type=code",
        ),
      )
      expect(authorize.status).toBe(200)
      expect(authorize.headers.get("cache-control")).toBe(
        "no-store",
      )
      expect(authorize.headers.get("set-cookie")).toContain(
        "inline_ar=request",
      )

      const consent = await kernel.handler(
        new Request(
          "http://inline.test/oauth/authorize/consent",
          {
            method: "POST",
            headers: {
              "content-type":
                "application/x-www-form-urlencoded",
            },
            body: "csrf=token&space_id=1&space_id=2",
          },
        ),
      )
      expect(consent.status).toBe(302)
      expect(consent.headers.get("location")).toBe(
        "https://client.example/callback?code=code&state=state",
      )
      expect(consent.headers.get("set-cookie")).toContain(
        "Max-Age=0",
      )
      expect(await consent.text()).toBe("")
    } finally {
      await kernel.dispose()
    }
  })

  it("rejects undeclared OAuth responses before serving them", async () => {
    const failure = await Effect.runPromise(
      Effect.flip(
        validateOAuthResponse(
          "register",
          new Response(
            JSON.stringify({
              client_id: "client-1",
              client_id_issued_at: 1_700_000_000,
              redirect_uris: [
                "https://client.example/callback",
              ],
              token_endpoint_auth_method: "none",
              grant_types: [
                "authorization_code",
                "refresh_token",
              ],
              response_types: ["code"],
              unexpected: true,
            }),
            {
              status: 202,
              headers: {
                "content-type": "application/json",
              },
            },
          ),
        ),
      ),
    )

    expect(failure).toBeInstanceOf(
      OAuthResponseContractFailure,
    )
    expect(failure).toMatchObject({
      operation: "register",
      status: 202,
    })
    const bodyFailure = await Effect.runPromise(
      Effect.flip(
        validateOAuthResponse(
          "register",
          new Response(
            JSON.stringify({ accepted: true }),
            {
              status: 201,
              headers: {
                "cache-control": "no-store",
                "content-type": "application/json",
              },
            },
          ),
        ),
      ),
    )
    expect(bodyFailure).toBeInstanceOf(
      OAuthResponseContractFailure,
    )
    const headerFailure = await Effect.runPromise(
      Effect.flip(
        validateOAuthResponse(
          "consent",
          new Response(null, {
            status: 302,
            headers: {
              "set-cookie": "inline_ar=; Max-Age=0",
            },
          }),
        ),
      ),
    )
    expect(headerFailure).toBeInstanceOf(
      OAuthResponseContractFailure,
    )

    let reports = 0
    const kernel = makeKernel({
      reporter: {
        report: () =>
          Effect.sync(() => {
            reports += 1
          }),
      },
      oauth: {
        execute: () =>
          Effect.succeed(
            new Response(
              JSON.stringify({ accepted: true }),
              {
                status: 202,
                headers: {
                  "content-type": "application/json",
                },
              },
            ),
          ),
      },
    })

    try {
      const response = await kernel.handler(
        new Request("http://inline.test/oauth/register", {
          method: "POST",
          headers: {
            "content-type": "application/json",
          },
          body: JSON.stringify({
            redirect_uris: [
              "https://client.example/callback",
            ],
          }),
        }),
      )

      expect(response.status).toBe(500)
      expect(await response.json()).toEqual({
        error: "server_error",
        error_description: "Server error",
      })
      expect(reports).toBe(1)
    } finally {
      await kernel.dispose()
    }
  })

  it("reports a private OAuth defect once while preserving its established response", async () => {
    let reports = 0
    const publicResponse = new Response(
      "<html>Code verification failed.</html>",
      {
        status: 401,
        headers: {
          "content-type": "text/html; charset=utf-8",
        },
      },
    )
    const kernel = makeKernel({
      reporter: {
        report: () =>
          Effect.sync(() => {
            reports += 1
          }),
      },
      oauth: {
        execute: (operation) =>
          Effect.fail(
            new OAuthHttpFailure({
              operation,
              cause: new Error("private provider failure"),
              publicResponse,
            }),
          ),
      },
    })

    try {
      const response = await kernel.handler(
        new Request(
          "http://inline.test/oauth/authorize/verify-email-code",
          {
            method: "POST",
            headers: {
              "content-type":
                "application/x-www-form-urlencoded",
            },
            body: "csrf=token&code=123456",
          },
        ),
      )

      expect(response.status).toBe(401)
      expect(await response.text()).toBe(
        "<html>Code verification failed.</html>",
      )
      expect(reports).toBe(1)
    } finally {
      await kernel.dispose()
    }
  })

  it("matches Elysia OAuth body parsing and malformed-body transport", async () => {
    const cases = [
      {
        name: "missing content type",
        request: () =>
          new Request("http://inline.test/revoke", {
            method: "POST",
            body: "token=opaque",
          }),
      },
      {
        name: "malformed JSON",
        request: () =>
          new Request("http://inline.test/revoke", {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: "{",
          }),
      },
      {
        name: "text",
        request: () =>
          new Request("http://inline.test/revoke", {
            method: "POST",
            headers: {
              "content-type": "text/plain",
            },
            body: "token=opaque",
          }),
      },
      {
        name: "JSON",
        request: () =>
          new Request("http://inline.test/revoke", {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({ token: "opaque" }),
          }),
      },
      {
        name: "form-urlencoded repeated field",
        request: () =>
          new Request("http://inline.test/revoke", {
            method: "POST",
            headers: {
              "content-type":
                "application/x-www-form-urlencoded",
            },
            body: "token=first&token=second",
          }),
      },
      {
        name: "multipart repeated field",
        request: () => {
          const body = new FormData()
          body.append("token", "first")
          body.append("token", "second")
          return new Request(
            "http://inline.test/revoke",
            {
              method: "POST",
              body,
            },
          )
        },
      },
      {
        name: "empty",
        request: () =>
          new Request("http://inline.test/revoke", {
            method: "POST",
          }),
      },
    ] as const

    for (const testCase of cases) {
      const legacyBodies: Array<unknown> = []
      const replacementBodies: Array<unknown> = []
      const response = () =>
        new Response(JSON.stringify({}), {
          headers: {
            "cache-control": "no-store",
            "content-type": "application/json",
          },
        })
      const legacy = new Elysia().post(
        "/revoke",
        ({ body }) => {
          legacyBodies.push(body)
          return response()
        },
      )
      const handlers: OAuthHttpHandlers = {
        metadata: () => response(),
        register: async () => response(),
        authorize: async () => response(),
        sendEmailCode: async () => response(),
        verifyEmailCode: async () => response(),
        consent: async () => response(),
        token: async () => response(),
        revoke: async (body) => {
          replacementBodies.push(body)
          return response()
        },
        introspect: async () => response(),
      }
      const kernel = makeKernel({
        oauth: makeOAuthHttpService(handlers),
      })

      try {
        const legacyResponse = await legacy.handle(
          testCase.request(),
        )
        const replacementResponse = await kernel.handler(
          testCase.request(),
        )

        expect(
          {
            status: replacementResponse.status,
            body: await replacementResponse.text(),
            invoked: replacementBodies.length,
          },
          testCase.name,
        ).toEqual({
          status: legacyResponse.status,
          body: await legacyResponse.text(),
          invoked: legacyBodies.length,
        })
        const replacementContentType =
          replacementResponse.headers.get("content-type")
        if (testCase.name === "malformed JSON") {
          expect(replacementContentType).toBeNull()
        } else {
          expect(replacementContentType).toBe(
            legacyResponse.headers.get("content-type"),
          )
        }
        expect(
          replacementBodies,
          testCase.name,
        ).toEqual(legacyBodies)
      } finally {
        await kernel.dispose()
      }
    }
  })

  it("documents every compatibility alias and form token exchange", () => {
    const api = makePlatformApiBase(
      "https://api.inline.chat",
    ).add(AuthApiGroup)
    const spec = OpenApi.fromApi(api)
    assertValidOpenApiDocument(
      spec,
      "Slice 2 auth OpenAPI",
    )

    expect(Object.keys(spec.paths).sort()).toEqual([
      "/.well-known/oauth-authorization-server",
      "/authorize",
      "/oauth/authorize",
      "/oauth/authorize/consent",
      "/oauth/authorize/send-email-code",
      "/oauth/authorize/verify-email-code",
      "/oauth/introspect",
      "/oauth/register",
      "/oauth/revoke",
      "/oauth/token",
      "/register",
      "/revoke",
      "/token",
      "/v1/checkInviteCode",
      "/v1/logout",
      "/v1/sendEmailCode",
      "/v1/sendSmsCode",
      "/v1/verifyEmailCode",
      "/v1/verifySmsCode",
      "/v1/{token}/logout",
    ])
    expect(spec.paths).toHaveProperty("/register")
    expect(spec.paths).toHaveProperty("/authorize")
    expect(spec.paths).toHaveProperty("/token")
    expect(spec.paths).toHaveProperty("/revoke")

    const tokenPost = spec.paths["/oauth/token"]?.post as
      | {
        readonly requestBody?: {
          readonly content?: Record<string, unknown>
        }
      }
      | undefined
    expect(tokenPost?.requestBody?.content).toHaveProperty(
      "application/x-www-form-urlencoded",
    )
    expect(tokenPost?.requestBody?.content).toHaveProperty(
      "application/json",
    )
    expect(tokenPost?.requestBody?.content).toHaveProperty(
      "multipart/form-data",
    )

    const identityPost = spec.paths[
      "/v1/sendEmailCode"
    ]?.post as
      | {
        readonly requestBody?: {
          readonly content?: Record<string, unknown>
        }
      }
      | undefined
    expect(identityPost?.requestBody?.content).toHaveProperty(
      "application/json",
    )
    expect(identityPost?.requestBody?.content).toHaveProperty(
      "application/x-www-form-urlencoded",
    )
    expect(identityPost?.requestBody?.content).toHaveProperty(
      "multipart/form-data",
    )

    const revokePost = spec.paths["/oauth/revoke"]?.post as
      | {
        readonly requestBody?: {
          readonly required?: boolean
        }
        readonly responses?: Record<
          string,
          {
            readonly headers?: Record<string, unknown>
          }
        >
      }
      | undefined
    expect(revokePost?.requestBody?.required).toBe(false)
    expect(
      revokePost?.responses?.["200"]?.headers,
    ).toHaveProperty("Cache-Control")
    expect(revokePost?.responses).not.toHaveProperty("420")

    const consentPost = spec.paths[
      "/oauth/authorize/consent"
    ]?.post as
      | {
        readonly responses?: Record<
          string,
          {
            readonly headers?: Record<string, unknown>
          }
        >
      }
      | undefined
    expect(
      consentPost?.responses?.["302"]?.headers,
    ).toMatchObject({
      Location: { required: true },
      "Set-Cookie": { required: true },
    })
    const consentSchema = spec.components.schemas[
      "OAuthConsentForm"
    ] as
      | {
        readonly properties?: {
          readonly space_id?: {
            readonly anyOf?: ReadonlyArray<{
              readonly type?: string
            }>
          }
        }
      }
      | undefined
    expect(
      consentSchema?.properties?.space_id?.anyOf,
    ).toContainEqual({ type: "array", items: { type: "string" } })

    const authorizeGet = spec.paths[
      "/oauth/authorize"
    ]?.get as
      | {
        readonly responses?: Record<
          string,
          {
            readonly headers?: Record<string, unknown>
          }
        >
      }
      | undefined
    expect(
      authorizeGet?.responses?.["200"]?.headers,
    ).toMatchObject({
      "Cache-Control": expect.any(Object),
      "Set-Cookie": { required: true },
    })

    const introspectPost = spec.paths[
      "/oauth/introspect"
    ]?.post as
      | {
        readonly parameters?: ReadonlyArray<{
          readonly name?: string
          readonly required?: boolean
        }>
      }
      | undefined
    expect(
      introspectPost?.parameters?.find(
        (parameter) =>
          parameter.name === "x-inline-mcp-secret",
      ),
    ).toMatchObject({ required: true })

    const logoutGet = spec.paths["/v1/logout"]?.get as
      | {
        readonly parameters?: ReadonlyArray<{
          readonly name?: string
          readonly required?: boolean
        }>
      }
      | undefined
    expect(
      logoutGet?.parameters?.find(
        (parameter) =>
          parameter.name === "authorization",
      ),
    ).toMatchObject({ required: true })
    const logoutPost = spec.paths["/v1/logout"]?.post as
      | {
        readonly parameters?: ReadonlyArray<{
          readonly name?: string
          readonly required?: boolean
        }>
      }
      | undefined
    expect(
      logoutPost?.parameters?.find(
        (parameter) =>
          parameter.name === "authorization",
      ),
    ).toMatchObject({ required: true })

    const pathLogoutGet = spec.paths[
      "/v1/{token}/logout"
    ]?.get as
      | {
        readonly parameters?: ReadonlyArray<{
          readonly name?: string
        }>
      }
      | undefined
    expect(
      pathLogoutGet?.parameters?.some(
        (parameter) =>
          parameter.name === "authorization",
      ),
    ).toBe(false)
  })
})
