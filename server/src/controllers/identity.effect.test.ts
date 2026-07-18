import { describe, expect, it } from "@effect/vitest"
import {
  Context,
  Effect,
  ErrorReporter as EffectErrorReporter,
  Layer,
  Schema,
} from "effect"
import { ConnectionError_Reason } from "@inline-chat/protocol/core"
import Elysia, { t } from "elysia"
import {
  HttpRouter,
  HttpServer,
} from "effect/unstable/http"
import {
  ErrorReporter,
  type ErrorReporterShape,
} from "../core/errors/errorReporter"
import {
  defineExecutableHttpApi,
  makeHttpApplication,
} from "../core/http/application"
import {
  defineOpenApiDocument,
  makeBotApiBase,
  makePlatformApiBase,
} from "../core/http/openApi"
import {
  HttpRequestContext,
} from "../core/http/requestContext"
import { RequestId } from "../core/helpers/requestId"
import {
  IdentityOperationFailure,
  IdentityOperations,
  IdentityPublicError,
  type IdentityOperationsShape,
} from "../modules/auth/identityOperations.effect"
import {
  LoginSessionResult,
} from "../modules/auth/identitySchemas.effect"
import {
  OAuthHttpService,
  type OAuthHttpServiceShape,
} from "../modules/oauth/httpService.effect"
import {
  SessionAuthentication,
  SessionAuthenticationFailure,
  SessionAuthenticationRejected,
  makeSessionIdentity,
  type SessionAuthenticationShape,
} from "./plugins.effect"
import {
  AuthApiGroup,
  makeAuthRouteGroup,
} from "./auth.effect"

const unused = (name: string) =>
  Effect.die(new Error(`Unexpected identity operation: ${name}`))

const loginResult = Schema.decodeUnknownSync(
  LoginSessionResult,
)({
  userId: 42,
  token: "42:session",
  user: {
    id: 42,
    date: 1_700_000_000,
  },
})

const makeOperations = (
  overrides: Partial<IdentityOperationsShape> = {},
): IdentityOperationsShape => ({
  sendSmsCode: () => unused("sendSmsCode"),
  verifySmsCode: () => unused("verifySmsCode"),
  sendEmailCode: () => unused("sendEmailCode"),
  verifyEmailCode: () => unused("verifyEmailCode"),
  checkInviteCode: () => unused("checkInviteCode"),
  logout: () => unused("logout"),
  ...overrides,
})

const makeKernel = ({
  errorReporter = {
    report: () => Effect.void,
  },
  operations,
  sessionAuthentication = {
    authenticate: () =>
      Effect.succeed(makeSessionIdentity(42, 7)),
  },
  trustedClientIpHeader,
}: {
  readonly errorReporter?: ErrorReporterShape | undefined
  readonly operations: IdentityOperationsShape
  readonly sessionAuthentication?: SessionAuthenticationShape | undefined
  readonly trustedClientIpHeader?:
    | "cf-connecting-ip"
    | "x-real-ip"
    | undefined
}) => {
  const oauth: OAuthHttpServiceShape = {
    execute: () => unused("oauth"),
  }
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
    Layer.provide(
      Layer.succeed(ErrorReporter, errorReporter),
    ),
    Layer.provide(
      Layer.merge(
        Layer.succeed(IdentityOperations)(operations),
        Layer.merge(
          Layer.succeed(SessionAuthentication)(
            sessionAuthentication,
          ),
          Layer.succeed(OAuthHttpService)(oauth),
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
    requestId: RequestId.make("identity-test"),
    startedAtMillis: 0,
  }).pipe(
    Context.add(IdentityOperations, operations),
    Context.add(
      SessionAuthentication,
      sessionAuthentication,
    ),
    Context.add(OAuthHttpService, oauth),
    Context.add(ErrorReporter, errorReporter),
  )

  return {
    dispose: webHandler.dispose,
    handler: (request: Request) =>
      webHandler.handler(request, context),
  }
}

describe("Effect identity routes", () => {
  it("serves every GET and POST unauthenticated identity variant", async () => {
    const calls: Array<string> = []
    const operations = makeOperations({
      sendSmsCode: () => {
        calls.push("sendSmsCode")
        return Effect.succeed({
          existingUser: true,
          needsInviteCode: false,
          phoneNumber: "+12025550123",
          formattedPhoneNumber: "+1 202 555 0123",
        })
      },
      verifySmsCode: () => {
        calls.push("verifySmsCode")
        return Effect.succeed(loginResult)
      },
      sendEmailCode: () => {
        calls.push("sendEmailCode")
        return Effect.succeed({
          existingUser: true,
          needsInviteCode: false,
          challengeToken: "challenge",
        })
      },
      verifyEmailCode: () => {
        calls.push("verifyEmailCode")
        return Effect.succeed(loginResult)
      },
      checkInviteCode: () => {
        calls.push("checkInviteCode")
        return Effect.succeed({ valid: true })
      },
    })
    const kernel = makeKernel({ operations })
    const cases = [
      {
        path: "/v1/sendSmsCode",
        input: { phoneNumber: "+12025550123" },
      },
      {
        path: "/v1/verifySmsCode",
        input: {
          phoneNumber: "+12025550123",
          code: "123456",
        },
      },
      {
        path: "/v1/sendEmailCode",
        input: { email: "identity@example.com" },
      },
      {
        path: "/v1/verifyEmailCode",
        input: {
          email: "identity@example.com",
          code: "123456",
        },
      },
      {
        path: "/v1/checkInviteCode",
        input: { inviteCode: "ABC123" },
      },
    ] as const

    try {
      for (const testCase of cases) {
        const query = new URLSearchParams(testCase.input)
        const getResponse = await kernel.handler(
          new Request(
            `http://inline.test${testCase.path}?${query}`,
          ),
        )
        const postResponse = await kernel.handler(
          new Request(
            `http://inline.test${testCase.path}`,
            {
              method: "POST",
              headers: {
                "content-type": "application/json",
              },
              body: JSON.stringify(testCase.input),
            },
          ),
        )

        expect(getResponse.status).toBe(200)
        expect(postResponse.status).toBe(200)
      }

      expect(calls.sort()).toEqual([
        "checkInviteCode",
        "checkInviteCode",
        "sendEmailCode",
        "sendEmailCode",
        "sendSmsCode",
        "sendSmsCode",
        "verifyEmailCode",
        "verifyEmailCode",
        "verifySmsCode",
        "verifySmsCode",
      ])
    } finally {
      await kernel.dispose()
    }
  })

  it("decodes the legacy POST shape and trusts only the configured IP header", async () => {
    let received:
      | {
        readonly input: unknown
        readonly context: unknown
      }
      | undefined
    const kernel = makeKernel({
      trustedClientIpHeader: "cf-connecting-ip",
      operations: makeOperations({
        sendSmsCode: (input, context) => {
          received = { input, context }
          return Effect.succeed({
            existingUser: true,
            needsInviteCode: false,
            phoneNumber: "+12025550123",
            formattedPhoneNumber: "+1 202 555 0123",
          })
        },
      }),
    })

    try {
      const response = await kernel.handler(
        new Request("http://inline.test/v1/sendSmsCode", {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "cf-connecting-ip": "203.0.113.8",
            "x-forwarded-for": "198.51.100.7",
          },
          body: JSON.stringify({
            phoneNumber: "+12025550123",
            clientType: "web",
          }),
        }),
      )

      expect(response.status).toBe(200)
      expect(await response.json()).toEqual({
        ok: true,
        result: {
          existingUser: true,
          needsInviteCode: false,
          phoneNumber: "+12025550123",
          formattedPhoneNumber: "+1 202 555 0123",
        },
      })
      expect(received).toEqual({
        input: {
          phoneNumber: "+12025550123",
          clientType: "web",
        },
        context: {
          ip: "203.0.113.8",
          source: "/v1/sendSmsCode",
        },
      })
    } finally {
      await kernel.dispose()
    }
  })

  it("returns the legacy validation envelope before invoking an operation", async () => {
    let calls = 0
    const kernel = makeKernel({
      operations: makeOperations({
        sendEmailCode: () => {
          calls += 1
          return Effect.succeed({
            existingUser: false,
            needsInviteCode: true,
          })
        },
      }),
    })

    try {
      const response = await kernel.handler(
        new Request("http://inline.test/v1/sendEmailCode", {
          method: "POST",
          headers: {
            "content-type": "application/json",
          },
          body: JSON.stringify({}),
        }),
      )

      expect(response.status).toBe(400)
      expect(await response.json()).toEqual({
        ok: false,
        error: "INVALID_ARGS",
        errorCode: 400,
        description: "Validation error",
      })
      expect(calls).toBe(0)

      const malformedResponse = await kernel.handler(
        new Request("http://inline.test/v1/sendEmailCode", {
          method: "POST",
          headers: {
            "content-type": "application/json",
          },
          body: "{",
        }),
      )
      expect(malformedResponse.status).toBe(500)
      expect(await malformedResponse.json()).toEqual({
        ok: false,
        error: "SERVER_ERROR",
        errorCode: 500,
        description: "Server error",
      })
      expect(calls).toBe(0)
    } finally {
      await kernel.dispose()
    }
  })

  it("matches Elysia body parsing before stateful email work", async () => {
    const [
      { handleError },
      { makeUnauthApiRoute },
    ] = await Promise.all([
      import("./apiErrorHandler"),
      import("./unauthApiRoute"),
    ])
    const LegacySendEmailCodeInput = t.Object({
      email: t.String(),
      deviceId: t.Optional(t.String()),
      clientType: t.Optional(t.String()),
      clientVersion: t.Optional(t.String()),
      osVersion: t.Optional(t.String()),
      deviceName: t.Optional(t.String()),
    })
    const LegacySendEmailCodeResponse = t.Object({
      existingUser: t.Boolean(),
      needsInviteCode: t.Boolean(),
      challengeToken: t.Optional(t.String()),
    })
    const cases = [
      {
        name: "missing content type",
        request: () =>
          new Request(
            "http://inline.test/v1/sendEmailCode",
            {
              method: "POST",
              body: JSON.stringify({
                email: "identity@example.com",
              }),
            },
          ),
      },
      {
        name: "malformed JSON",
        request: () =>
          new Request(
            "http://inline.test/v1/sendEmailCode",
            {
              method: "POST",
              headers: {
                "content-type": "application/json",
              },
              body: "{",
            },
          ),
      },
      {
        name: "text",
        request: () =>
          new Request(
            "http://inline.test/v1/sendEmailCode",
            {
              method: "POST",
              headers: {
                "content-type": "text/plain",
              },
              body: JSON.stringify({
                email: "identity@example.com",
              }),
            },
          ),
      },
      {
        name: "JSON",
        request: () =>
          new Request(
            "http://inline.test/v1/sendEmailCode",
            {
              method: "POST",
              headers: {
                "content-type": "application/json",
              },
              body: JSON.stringify({
                email: "identity@example.com",
              }),
            },
          ),
      },
      {
        name: "form-urlencoded",
        request: () =>
          new Request(
            "http://inline.test/v1/sendEmailCode",
            {
              method: "POST",
              headers: {
                "content-type":
                  "application/x-www-form-urlencoded",
              },
              body: "email=identity%40example.com",
            },
          ),
      },
      {
        name: "multipart",
        request: () => {
          const body = new FormData()
          body.set("email", "identity@example.com")
          return new Request(
            "http://inline.test/v1/sendEmailCode",
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
          new Request(
            "http://inline.test/v1/sendEmailCode",
            {
              method: "POST",
            },
          ),
      },
      {
        name: "repeated form field",
        request: () =>
          new Request(
            "http://inline.test/v1/sendEmailCode",
            {
              method: "POST",
              headers: {
                "content-type":
                  "application/x-www-form-urlencoded",
              },
              body:
                "email=identity%40example.com&email=other%40example.com",
            },
          ),
      },
    ] as const

    for (const testCase of cases) {
      let legacyCalls = 0
      let replacementCalls = 0
      const legacy = new Elysia()
        .use(handleError)
        .group("/v1", (app) =>
          app.use(
            makeUnauthApiRoute(
              "/sendEmailCode",
              LegacySendEmailCodeInput,
              LegacySendEmailCodeResponse,
              async () => {
                legacyCalls += 1
                return {
                  existingUser: false,
                  needsInviteCode: true,
                }
              },
            ),
          ),
        )
      const kernel = makeKernel({
        operations: makeOperations({
          sendEmailCode: () => {
            replacementCalls += 1
            return Effect.succeed({
              existingUser: false,
              needsInviteCode: true,
            })
          },
        }),
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
            calls: replacementCalls,
          },
          testCase.name,
        ).toEqual({
          status: legacyResponse.status,
          body: await legacyResponse.text(),
          calls: legacyCalls,
        })
      } finally {
        await kernel.dispose()
      }
    }
  })

  it("gives a logout path token precedence over the Authorization header", async () => {
    let authenticatedToken: string | undefined
    let logoutContext: unknown
    const kernel = makeKernel({
      operations: makeOperations({
        logout: (context) => {
          logoutContext = context
          return Effect.void
        },
      }),
      sessionAuthentication: {
        authenticate: (token) => {
          authenticatedToken = token
          return Effect.succeed(
            makeSessionIdentity(loginResult.userId, 7),
          )
        },
      },
    })

    try {
      const response = await kernel.handler(
        new Request(
          "http://inline.test/v1/42%3Apath-token/logout",
          {
            headers: {
              authorization: "Bearer 42:header-token",
            },
          },
        ),
      )

      expect(response.status).toBe(200)
      expect(await response.json()).toEqual({ ok: true })
      expect(authenticatedToken).toBe("42:path-token")
      expect(logoutContext).toEqual({
        currentUserId: 42,
        currentSessionId: 7,
        ip: "unresolved-client",
      })
    } finally {
      await kernel.dispose()
    }
  })

  it("preserves logout authentication variants and reports only defects", async () => {
    const reports: Array<unknown> = []
    let logoutCalls = 0
    const kernel = makeKernel({
      errorReporter: {
        report: (report) =>
          Effect.sync(() => {
            reports.push(report)
          }),
      },
      operations: makeOperations({
        logout: () => {
          logoutCalls += 1
          return Effect.void
        },
      }),
      sessionAuthentication: {
        authenticate: (token) => {
          if (token === "42:revoked") {
            return Effect.fail(
              new SessionAuthenticationRejected({
                error: "SESSION_REVOKED",
                errorCode: 401,
                description:
                  "The authorization has been invalidated.",
                connectionReason:
                  ConnectionError_Reason.SESSION_REVOKED,
              }),
            )
          }
          if (token === "42:deleted") {
            return Effect.fail(
              new SessionAuthenticationRejected({
                error: "USER_DEACTIVATED",
                errorCode: 401,
                description:
                  "The user has been deleted/deactivated",
                connectionReason:
                  ConnectionError_Reason.UNAUTHORIZED,
              }),
            )
          }
          if (token === "42:defect") {
            return Effect.fail(
              new SessionAuthenticationFailure({
                cause: new Error("database unavailable"),
              }),
            )
          }
          return Effect.succeed(makeSessionIdentity(42, 7))
        },
      },
    })

    const request = (
      authorization?: string,
      method = "GET",
    ) =>
      new Request("http://inline.test/v1/logout", {
        method,
        headers: authorization === undefined
          ? method === "POST"
            ? { "content-type": "application/json" }
            : undefined
          : {
              authorization,
              ...(method === "POST"
                ? { "content-type": "application/json" }
                : {}),
            },
        ...(method === "POST"
          ? { body: "{}" }
          : {}),
      })

    try {
      for (const [authorization, expectedError] of [
        [undefined, "UNAUTHORIZED"],
        ["Bearer", "UNAUTHORIZED"],
        ["Bearer 42:revoked", "SESSION_REVOKED"],
        ["Bearer 42:deleted", "USER_DEACTIVATED"],
      ] as const) {
        const response = await kernel.handler(
          request(authorization),
        )
        expect(response.status).toBe(401)
        expect(await response.json()).toMatchObject({
          ok: false,
          error: expectedError,
          errorCode: 401,
        })
      }

      const emptyPost =
        await kernel.handler(
          new Request(
            "http://inline.test/v1/logout",
            { method: "POST" },
          ),
        )
      expect(emptyPost.status).toBe(401)
      expect(
        await emptyPost.json(),
      ).toMatchObject({
        error: "UNAUTHORIZED",
        errorCode: 401,
      })

      const postResponse = await kernel.handler(
        request("Bearer 42:valid", "POST"),
      )
      expect(postResponse.status).toBe(200)
      expect(await postResponse.json()).toEqual({ ok: true })

      const defectResponse = await kernel.handler(
        request("Bearer 42:defect"),
      )
      expect(defectResponse.status).toBe(500)
      expect(await defectResponse.text()).not.toContain(
        "database unavailable",
      )
      expect(reports).toHaveLength(1)
      expect(logoutCalls).toBe(1)
    } finally {
      await kernel.dispose()
    }
  })

  it("reports an identity operation failure once and preserves its public response", async () => {
    const reports: Array<unknown> = []
    const privateCause = new Error("provider unavailable")
    const kernel = makeKernel({
      errorReporter: {
        report: (report) =>
          Effect.sync(() => {
            reports.push(report)
          }),
      },
      operations: makeOperations({
        sendEmailCode: () =>
          Effect.fail(
            new IdentityOperationFailure({
              operation: "identity.sendEmailCode",
              cause: privateCause,
              publicError: new IdentityPublicError({
                error: "INTERNAL",
                errorCode: 500,
                description:
                  "Internal server error happened",
              }),
            }),
          ),
      }),
    })

    try {
      const response = await kernel.handler(
        new Request(
          "http://inline.test/v1/sendEmailCode?email=identity%40example.com",
        ),
      )

      expect(response.status).toBe(500)
      expect(await response.json()).toEqual({
        ok: false,
        error: "INTERNAL",
        errorCode: 500,
        description: "Internal server error happened",
      })
      expect(reports).toHaveLength(1)
      expect(reports[0]).toMatchObject({
        context: {
          operation: "identity.sendEmailCode",
          requestId: expect.any(String),
        },
      })
    } finally {
      await kernel.dispose()
    }
  })
})
