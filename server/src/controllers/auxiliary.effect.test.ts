import { describe, expect, it } from "@effect/vitest"
import {
  Context,
  Effect,
  ErrorReporter as EffectErrorReporter,
  Layer,
} from "effect"
import {
  HttpRouter,
  HttpServer,
} from "effect/unstable/http"
import {
  OpenApi,
} from "effect/unstable/httpapi"
import {
  ErrorReporter,
  type UnexpectedErrorReport,
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
  assertValidOpenApiDocument,
} from "../core/http/openApiValidation"
import {
  ThereOperationFailure,
  ThereOperations,
} from "./extra/there.effect"
import {
  WaitlistOperationFailure,
  WaitlistOperations,
} from "./extra/waitlist.effect"
import {
  EmailUnsubscribeOperations,
} from "./extra/emailUnsubscribe.effect"
import {
  HealthOperationFailure,
  HealthOperations,
} from "./health.effect"
import type {
  HealthHttpResponse,
  LivenessHttpResponse,
} from "./healthCheck"
import {
  IntegrationAuthorizationRejected,
  IntegrationOperationFailure,
  IntegrationOperations,
} from "./integrations/integrationsRouter.effect"
import {
  MediaOperationFailure,
  MediaOperations,
  makeMediaOperations,
  type MediaRequestHeaders,
} from "./media.effect"
import {
  SessionAuthentication,
  SessionAuthenticationFailure,
  makeSessionIdentity,
  missingSessionAuthentication,
} from "./plugins.effect"
import {
  RootPageOperations,
} from "./root.effect"
import {
  AuxiliaryApiGroup,
  AuxiliaryRouteGroup,
} from "./auxiliary.effect"

type FailureMode = "none" | "expected" | "unexpected"

interface Probe {
  authenticateCalls: number
  authorizeCalls: number
  callbackCalls: number
  mediaCalls: number
  mediaHeaders: MediaRequestHeaders | undefined
  thereCalls: number
  waitlistCalls: number
  waitlistClientIp: string | undefined
  authentication: FailureMode
  authorization: FailureMode
  authUrlMissing: boolean
  callbackOperationFailure: boolean
  callbackResult: {
    ok: boolean
    error?: string
  }
  healthFailure: boolean
  health: HealthHttpResponse
  liveness: LivenessHttpResponse
  mediaFailure: boolean
  secureCookies: boolean
  thereFailure: boolean
  waitlistFailure: boolean
  unsubscribeFound: boolean
  unsubscribeSuppressed: boolean
}

const healthy = (): HealthHttpResponse => ({
  ok: true,
  status: "ok",
  timestamp: 1_784_320_000,
  draining: false,
  checks: {
    database: {
      ok: true,
      latencyMs: 2,
    },
    lifecycle: {
      ok: true,
    },
  },
})

const live = (): LivenessHttpResponse => ({
  ok: true,
  status: "ok",
  timestamp: 1_784_320_000,
  draining: false,
  checks: {
    lifecycle: {
      ok: true,
    },
  },
})

const makeProbe = (): Probe => ({
  authenticateCalls: 0,
  authorizeCalls: 0,
  callbackCalls: 0,
  mediaCalls: 0,
  mediaHeaders: undefined,
  thereCalls: 0,
  waitlistCalls: 0,
  waitlistClientIp: undefined,
  authentication: "none",
  authorization: "none",
  authUrlMissing: false,
  callbackOperationFailure: false,
  callbackResult: { ok: true },
  healthFailure: false,
  health: healthy(),
  liveness: live(),
  mediaFailure: false,
  secureCookies: false,
  thereFailure: false,
  waitlistFailure: false,
  unsubscribeFound: false,
  unsubscribeSuppressed: false,
})

const mediaSuccess = () =>
  new Response(
    new Uint8Array([1, 2, 3, 4]),
    {
      headers: {
        "content-type": "image/jpeg",
        "cache-control": "public, max-age=3600",
        "x-content-type-options": "nosniff",
      },
    },
  )

const makeHandler = (
  probe = makeProbe(),
) => {
  const reports: Array<
    UnexpectedErrorReport<unknown>
  > = []
  const dependencies = Layer.mergeAll(
    Layer.succeed(RootPageOperations, {
      document: Effect.succeed(
        "<!doctype html><p>inline test</p>",
      ),
    }),
    Layer.succeed(HealthOperations, {
      check: probe.healthFailure
        ? Effect.fail(
            new HealthOperationFailure({
              cause: new Error(
                "private health failure",
              ),
            }),
          )
        : Effect.sync(() => probe.health),
      live: Effect.sync(() => probe.liveness),
    }),
    Layer.succeed(WaitlistOperations, {
      count: probe.waitlistFailure
        ? Effect.fail(
            new WaitlistOperationFailure({
              operation: "count",
              cause: new Error(
                "private waitlist count failure",
              ),
            }),
          )
        : Effect.succeed(7),
      subscribe: (_input, clientIp) => {
        probe.waitlistCalls += 1
        probe.waitlistClientIp = clientIp
        return probe.waitlistFailure
          ? Effect.fail(
              new WaitlistOperationFailure({
                operation: "subscribe",
                cause: new Error(
                  "private waitlist failure",
                ),
              }),
            )
          : Effect.void
      },
    }),
    Layer.succeed(EmailUnsubscribeOperations, {
      lookup: () => Effect.succeed(
        probe.unsubscribeFound
          ? { emailKey: "contact-key", emailEncrypted: Buffer.from("encrypted") }
          : null,
      ),
      suppress: () => Effect.sync(() => {
        probe.unsubscribeSuppressed = true
      }),
    }),
    Layer.succeed(ThereOperations, {
      signup: () => {
        probe.thereCalls += 1
        return probe.thereFailure
          ? Effect.fail(
              new ThereOperationFailure({
                cause: new Error(
                  "private there failure",
                ),
              }),
            )
          : Effect.void
      },
    }),
    Layer.succeed(MediaOperations, {
      serveFile: (_query, headers) => {
        probe.mediaCalls += 1
        probe.mediaHeaders = headers
        return probe.mediaFailure
          ? Effect.fail(
              new MediaOperationFailure({
                operation: "storage",
                cause: new Error(
                  "private storage failure",
                ),
              }),
            )
          : Effect.succeed(mediaSuccess())
      },
    }),
    Layer.succeed(SessionAuthentication, {
      authenticate: () => {
        probe.authenticateCalls += 1
        if (probe.authentication === "expected") {
          return Effect.fail(
            missingSessionAuthentication(),
          )
        }
        if (probe.authentication === "unexpected") {
          return Effect.fail(
            new SessionAuthenticationFailure({
              cause: new Error(
                "private authentication failure",
              ),
            }),
          )
        }
        return Effect.succeed(makeSessionIdentity(42, 24))
      },
    }),
    Layer.succeed(IntegrationOperations, {
      secureCookies: probe.secureCookies,
      authorizeAdmin: () => {
        probe.authorizeCalls += 1
        if (probe.authorization === "expected") {
          return Effect.fail(
            new IntegrationAuthorizationRejected(),
          )
        }
        if (probe.authorization === "unexpected") {
          return Effect.fail(
            new IntegrationOperationFailure({
              operation: "authorize",
              cause: new Error(
                "private authorization failure",
              ),
            }),
          )
        }
        return Effect.void
      },
      generateState: Effect.succeed("state-123"),
      authUrl: (provider) =>
        Effect.succeed({
          url: probe.authUrlMissing
            ? undefined
            : `https://${provider}.example.test/authorize`,
        }),
      callback: () => {
        probe.callbackCalls += 1
        return probe.callbackOperationFailure
          ? Effect.fail(
              new IntegrationOperationFailure({
                operation: "linearCallback",
                cause: new Error(
                  "private callback failure",
                ),
              }),
            )
          : Effect.succeed(probe.callbackResult)
      },
    }),
    Layer.succeed(ErrorReporter, {
      report: (report) =>
        Effect.sync(() => {
          reports.push(report)
        }),
    }),
  )
  const platformApi = makePlatformApiBase(
    "https://api.inline.chat",
  ).add(AuxiliaryApiGroup)
  const botApi = makeBotApiBase(
    "https://api.inline.chat",
  )
  const application = makeHttpApplication({
    platform: defineExecutableHttpApi({
      ...defineOpenApiDocument({
        api: platformApi,
        jsonPath: "/v1/reference/json",
        swaggerPath: "/v1/reference",
      }),
      handlers: AuxiliaryRouteGroup.handlers.pipe(
        Layer.provide(dependencies),
      ),
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
      isProduction: false,
    },
  }).pipe(
    Layer.provide(HttpServer.layerServices),
    Layer.provide(EffectErrorReporter.layer([])),
    Layer.provide(ErrorReporter.Noop),
  )
  const webHandler = HttpRouter.toWebHandler(
    application,
    {
      disableLogger: true,
    },
  )

  return {
    dispose: webHandler.dispose,
    handler: (request: Request) =>
      webHandler.handler(request, Context.empty()),
    probe,
    reports,
  }
}

const withHandler = async (
  run: (
    test: ReturnType<typeof makeHandler>,
  ) => Promise<void>,
  probe?: Probe,
) => {
  const test = makeHandler(probe)
  try {
    await run(test)
  } finally {
    await test.dispose()
  }
}

describe("AuxiliaryRouteGroup", () => {
  it("derives the documented auxiliary surface from its executable route group", () => {
    const api = makePlatformApiBase(
      "https://api.inline.chat",
    ).add(AuxiliaryApiGroup)
    const spec = OpenApi.fromApi(api)
    assertValidOpenApiDocument(
      spec,
      "Slice 6 auxiliary OpenAPI",
    )

    expect(Object.keys(spec.paths).sort()).toEqual([
      "/",
      "/api/there/signup",
      "/email/unsubscribe/{token}",
      "/file",
      "/health",
      "/healthz",
      "/integrations/linear/callback",
      "/integrations/linear/integrate",
      "/integrations/notion/callback",
      "/integrations/notion/integrate",
      "/livez",
      "/readyz",
      "/waitlist/subscribe",
      "/waitlist/super_secret_sub_count",
      "/waitlist/verify",
    ])
    expect(
      spec.paths["/file"]?.get?.responses,
    ).toMatchObject({
      "200": {},
      "403": {},
      "404": {},
      "422": {},
      "500": {},
      "503": {},
    })
    expect(
      spec.paths["/health"]?.get?.responses,
    ).toHaveProperty("420")
    expect(
      spec.paths["/integrations/linear/integrate"]
        ?.get?.responses,
    ).not.toHaveProperty("420")
    const redirectResponse =
      spec.paths[
        "/integrations/linear/integrate"
      ]?.get?.responses["302"]
    expect(
      redirectResponse !== undefined &&
        "headers" in redirectResponse
        ? redirectResponse.headers
        : undefined,
    ).toMatchObject({
      Location: {},
      "Set-Cookie": {},
    })
  })

  it("serves root, health aliases, route quirks, and supported methods", async () => {
    await withHandler(async ({ handler }) => {
      for (const path of ["/", "//"]) {
        const response = await handler(
          new Request(`http://inline.test${path}`),
        )
        expect(response.status).toBe(200)
        expect(
          response.headers.get("content-type"),
        ).toBe("text/html; charset=utf8")
        expect(await response.text()).toBe(
          "<!doctype html><p>inline test</p>",
        )
      }

      for (
        const path of [
          "/health",
          "/health/",
          "/healthz",
          "/healthz/",
          "/livez",
          "/livez/",
        ]
      ) {
        const response = await handler(
          new Request(`http://inline.test${path}`),
        )
        expect(response.status).toBe(200)
        expect(await response.json()).toMatchObject({
          ok: true,
          status: "ok",
          draining: false,
        })
      }

      for (const path of ["/readyz", "/readyz/"]) {
        const response = await handler(
          new Request(`http://inline.test${path}`),
        )
        expect(response.status).toBe(200)
        expect(await response.json()).toMatchObject({
          ok: true,
          status: "ok",
          draining: false,
          checks: {
            database: {
              ok: true,
            },
          },
        })
      }

      const count = await handler(
        new Request(
          "http://inline.test/waitlist/super_secret_sub_count",
        ),
      )
      expect(count.status).toBe(200)
      expect(await count.json()).toBe(7)

      const verify = await handler(
        new Request(
          "http://inline.test/waitlist/verify",
          { method: "POST" },
        ),
      )
      expect(verify.status).toBe(200)
      expect(verify.headers.has("content-type")).toBe(
        false,
      )
      expect(await verify.text()).toBe("todo")

      const unsupported = await handler(
        new Request("http://inline.test/health", {
          method: "POST",
        }),
      )
      expect(unsupported.status).toBe(404)

      const wrongWaitlistMethod = await handler(
        new Request(
          "http://inline.test/waitlist/subscribe",
        ),
      )
      expect(wrongWaitlistMethod.status).toBe(404)
    })
  })

  it("requires confirmation before applying an email suppression", async () => {
    const probe = makeProbe()
    probe.unsubscribeFound = true
    const token = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUV"

    await withHandler(async ({ handler }) => {
      const confirmation = await handler(
        new Request(`http://inline.test/email/unsubscribe/${token}`),
      )
      expect(confirmation.status).toBe(200)
      expect(await confirmation.text()).toContain("Stop receiving campaign emails")
      expect(probe.unsubscribeSuppressed).toBe(false)

      const submitted = await handler(
        new Request(`http://inline.test/email/unsubscribe/${token}`, { method: "POST" }),
      )
      expect(submitted.status).toBe(200)
      expect(await submitted.text()).toContain("You are unsubscribed")
      expect(probe.unsubscribeSuppressed).toBe(true)
    }, probe)
  })

  it("preserves degraded and shutdown health responses", async () => {
    const probe = makeProbe()
    probe.health = {
      ok: false,
      status: "degraded",
      timestamp: 1_784_320_001,
      draining: true,
      checks: {
        database: {
          ok: false,
          latencyMs: 5,
          error: "database_unavailable",
        },
        lifecycle: {
          ok: false,
          error: "shutting_down",
          signal: "SIGTERM",
        },
      },
    }

    await withHandler(async ({ handler }) => {
      const response = await handler(
        new Request("http://inline.test/readyz"),
      )
      expect(response.status).toBe(503)
      expect(await response.json()).toEqual(
        probe.health,
      )
    }, probe)
  })

  it("serves liveness independently of degraded readiness", async () => {
    const probe = makeProbe()
    probe.health = {
      ...probe.health,
      ok: false,
      status: "degraded",
      checks: {
        ...probe.health.checks,
        database: {
          ok: false,
          latencyMs: 2_000,
          error: "database_unavailable",
        },
      },
    }

    await withHandler(async ({ handler }) => {
      const readiness = await handler(
        new Request("http://inline.test/readyz"),
      )
      expect(readiness.status).toBe(503)

      const liveness = await handler(
        new Request("http://inline.test/livez"),
      )
      expect(liveness.status).toBe(200)
      expect(await liveness.json()).toEqual(
        probe.liveness,
      )
    }, probe)
  })

  it("rejects malformed public inputs before side effects", async () => {
    await withHandler(async ({ handler, probe }) => {
      const malformedWaitlist = await handler(
        new Request(
          "http://inline.test/waitlist/subscribe",
          {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: "{",
          },
        ),
      )
      expect(malformedWaitlist.status).toBe(400)
      expect(
        malformedWaitlist.headers.has(
          "content-type",
        ),
      ).toBe(false)
      expect(await malformedWaitlist.text()).toBe(
        "Bad Request",
      )

      const missingEmail = await handler(
        new Request(
          "http://inline.test/waitlist/subscribe",
          {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: "{}",
          },
        ),
      )
      expect(missingEmail.status).toBe(422)
      expect(await missingEmail.json()).toMatchObject({
        type: "validation",
        on: "body",
        property: "/email",
        message: "Expected string",
      })

      const missingContentType = await handler(
        new Request(
          "http://inline.test/waitlist/subscribe",
          {
            method: "POST",
            body: JSON.stringify({
              email: "not-decoded@example.com",
            }),
          },
        ),
      )
      expect(missingContentType.status).toBe(422)
      expect(
        await missingContentType.json(),
      ).toMatchObject({
        type: "validation",
        on: "body",
        property: "root",
        message: "Expected object",
      })

      const missingThereEmail = await handler(
        new Request(
          "http://inline.test/api/there/signup",
          {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: "{}",
          },
        ),
      )
      expect(missingThereEmail.status).toBe(422)

      const missingMediaQuery = await handler(
        new Request("http://inline.test/file"),
      )
      expect(missingMediaQuery.status).toBe(422)
      expect(
        await missingMediaQuery.json(),
      ).toMatchObject({
        on: "query",
        property: "/id",
      })

      const missingIntegrationQuery = await handler(
        new Request(
          "http://inline.test/integrations/linear/integrate",
        ),
      )
      expect(missingIntegrationQuery.status).toBe(422)

      const emptyToken = await handler(
        new Request(
          "http://inline.test/integrations/linear/integrate?token=&spaceId=42",
        ),
      )
      expect(emptyToken.status).toBe(400)
      expect(await emptyToken.json()).toEqual({
        error: "Token is required",
      })

      expect(probe.waitlistCalls).toBe(0)
      expect(probe.thereCalls).toBe(0)
      expect(probe.mediaCalls).toBe(0)
      expect(probe.authenticateCalls).toBe(0)
      expect(probe.authorizeCalls).toBe(0)
    })
  })

  it("serves public writes and media without losing stream or cache semantics", async () => {
    await withHandler(async ({ handler, probe }) => {
      const waitlist = await handler(
        new Request(
          "http://inline.test/waitlist/subscribe",
          {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({
              email: "waitlist@example.com",
              extra: "ignored",
            }),
          },
        ),
      )
      expect(waitlist.status).toBe(200)
      expect(await waitlist.json()).toEqual({
        ok: true,
      })

      const there = await handler(
        new Request(
          "http://inline.test/api/there/signup",
          {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({
              email: "there@example.com",
            }),
          },
        ),
      )
      expect(there.status).toBe(200)
      expect(await there.json()).toEqual({
        ok: true,
      })

      const media = await handler(
        new Request(
          "http://inline.test/file?id=file123&exp=2000000000&sig=valid",
          {
            headers: {
              origin: "http://localhost:8001",
              range: "bytes=1-2",
            },
          },
        ),
      )
      expect(media.status).toBe(200)
      expect(media.headers.get("content-type")).toBe(
        "image/jpeg",
      )
      expect(media.headers.get("cache-control")).toBe(
        "public, max-age=3600",
      )
      expect(
        media.headers.get("x-content-type-options"),
      ).toBe("nosniff")
      expect(
        media.headers.get("access-control-allow-origin"),
      ).toBe("http://localhost:8001")
      expect(
        media.headers.get("access-control-expose-headers"),
      ).toContain("content-range")
      expect(
        Array.from(await media.bytes()),
      ).toEqual([1, 2, 3, 4])

      const mediaPreflight = await handler(
        new Request("http://inline.test/file", {
          method: "OPTIONS",
          headers: {
            origin: "http://localhost:8001",
            "access-control-request-method": "GET",
            "access-control-request-headers":
              "range, if-range, if-none-match",
          },
        }),
      )
      expect(mediaPreflight.status).toBe(204)
      expect(
        mediaPreflight.headers.get(
          "access-control-allow-headers",
        ),
      ).toContain("range")

      expect(probe.waitlistCalls).toBe(1)
      expect(probe.waitlistClientIp).toBeUndefined()
      expect(probe.thereCalls).toBe(1)
      expect(probe.mediaCalls).toBe(1)
      expect(probe.mediaHeaders).toEqual({
        range: "bytes=1-2",
        ifRange: undefined,
        ifNoneMatch: undefined,
      })
    })
  })

  it("preserves integration authentication and authorization rejection responses", async () => {
    const authenticationProbe = makeProbe()
    authenticationProbe.authentication = "expected"
    await withHandler(
      async ({ handler, probe, reports }) => {
        const response = await handler(
          new Request(
            "http://inline.test/integrations/linear/integrate?token=rejected&spaceId=42",
          ),
        )
        expect(response.status).toBe(401)
        expect(await response.json()).toEqual({
          error: "Unauthorized",
        })
        expect(probe.authenticateCalls).toBe(1)
        expect(probe.authorizeCalls).toBe(0)
        expect(reports).toHaveLength(0)
      },
      authenticationProbe,
    )

    const authorizationProbe = makeProbe()
    authorizationProbe.authorization = "expected"
    await withHandler(
      async ({ handler, probe, reports }) => {
        const response = await handler(
          new Request(
            "http://inline.test/integrations/notion/callback?code=code&state=state-123",
            {
              headers: {
                cookie:
                  "token=valid; state=state-123; spaceId=42",
              },
            },
          ),
        )
        expect(response.status).toBe(302)
        expect(response.headers.get("location")).toBe(
          "in://integrations/notion?success=false&error=unauthorized",
        )
        expect(
          response.headers.get("set-cookie"),
        ).toContain("state=; Max-Age=0")
        expect(probe.authenticateCalls).toBe(1)
        expect(probe.authorizeCalls).toBe(1)
        expect(probe.callbackCalls).toBe(0)
        expect(reports).toHaveLength(0)
      },
      authorizationProbe,
    )
  })

  it("preserves integration redirects, cookies, and callback rejection order", async () => {
    await withHandler(async ({ handler, probe }) => {
      const start = await handler(
        new Request(
          "http://inline.test/integrations/linear/integrate?token=valid&spaceId=42",
        ),
      )
      expect(start.status).toBe(302)
      expect(start.headers.get("location")).toBe(
        "https://linear.example.test/authorize",
      )
      expect(start.headers.get("set-cookie")).toContain(
        "state=state-123; Max-Age=600; Path=/; HttpOnly; SameSite=Lax",
      )
      expect(start.headers.get("set-cookie")).toContain(
        "token=valid; Max-Age=600; Path=/; HttpOnly; SameSite=Lax",
      )
      expect(probe.authenticateCalls).toBe(1)
      expect(probe.authorizeCalls).toBe(1)

      const missingCookies = await handler(
        new Request(
          "http://inline.test/integrations/notion/callback?code=code&state=state-123",
        ),
      )
      expect(missingCookies.status).toBe(302)
      expect(missingCookies.headers.get("location")).toBe(
        "in://integrations/notion?success=false&error=missing_cookie",
      )
      expect(
        missingCookies.headers.get("set-cookie"),
      ).toContain("state=; Max-Age=0")
      expect(probe.authenticateCalls).toBe(1)
      expect(probe.callbackCalls).toBe(0)

      const stateMismatch = await handler(
        new Request(
          "http://inline.test/integrations/linear/callback?code=code&state=query-state",
          {
            headers: {
              cookie:
                "token=valid; state=cookie-state; spaceId=42",
            },
          },
        ),
      )
      expect(stateMismatch.status).toBe(302)
      expect(stateMismatch.headers.get("location")).toBe(
        "in://integrations/linear?success=false&error=state_mismatch",
      )
      expect(probe.authenticateCalls).toBe(1)

      const callback = await handler(
        new Request(
          "http://inline.test/integrations/linear/callback?code=code&state=state-123",
          {
            headers: {
              cookie:
                "token=valid; state=state-123; spaceId=42",
            },
          },
        ),
      )
      expect(callback.status).toBe(302)
      expect(callback.headers.get("location")).toBe(
        "in://integrations/linear?success=true",
      )
      expect(callback.headers.get("set-cookie")).toContain(
        "spaceId=; Max-Age=0",
      )
      expect(probe.authenticateCalls).toBe(2)
      expect(probe.authorizeCalls).toBe(2)
      expect(probe.callbackCalls).toBe(1)

      probe.callbackResult = {
        ok: false,
        error: " ",
      }
      const failedCallback = await handler(
        new Request(
          "http://inline.test/integrations/linear/callback?code=code&state=state-123",
          {
            headers: {
              cookie:
                "token=valid; state=state-123; spaceId=42",
            },
          },
        ),
      )
      expect(failedCallback.status).toBe(302)
      expect(
        failedCallback.headers.get("location"),
      ).toBe(
        "in://integrations/linear?success=false&error=%20",
      )
    })
  })

  it("preserves integration cookies on URL failure and rejects empty callback cookies", async () => {
    const probe = makeProbe()
    probe.authUrlMissing = true
    probe.secureCookies = true

    await withHandler(async ({ handler, probe }) => {
      const missingUrl = await handler(
        new Request(
          "http://inline.test/integrations/notion/integrate?token=valid&spaceId=42",
        ),
      )
      expect(missingUrl.status).toBe(500)
      expect(await missingUrl.json()).toEqual({
        error: "Notion auth URL not found",
      })
      expect(
        missingUrl.headers.get("set-cookie"),
      ).toContain(
        "state=state-123; Max-Age=600; Path=/; HttpOnly; Secure; SameSite=Lax",
      )
      expect(
        missingUrl.headers.get("set-cookie"),
      ).toContain(
        "token=valid; Max-Age=600; Path=/; HttpOnly; Secure; SameSite=Lax",
      )

      const emptyToken = await handler(
        new Request(
          "http://inline.test/integrations/notion/callback?code=code&state=state-123",
          {
            headers: {
              cookie:
                "token=; state=state-123; spaceId=42",
            },
          },
        ),
      )
      expect(emptyToken.status).toBe(302)
      expect(emptyToken.headers.get("location")).toBe(
        "in://integrations/notion?success=false&error=missing_cookie",
      )
      expect(
        emptyToken.headers.get("set-cookie"),
      ).toContain(
        "state=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=Lax",
      )
      expect(probe.authenticateCalls).toBe(1)
      expect(probe.callbackCalls).toBe(0)
    }, probe)
  })

  it("reports injected dependency failures once without exposing causes", async () => {
    const authProbe = makeProbe()
    authProbe.authentication = "unexpected"
    await withHandler(
      async ({ handler, reports }) => {
        const response = await handler(
          new Request(
            "http://inline.test/integrations/linear/integrate?token=valid&spaceId=42",
          ),
        )
        expect(response.status).toBe(401)
        expect(await response.json()).toEqual({
          error: "Unauthorized",
        })
        expect(reports).toHaveLength(1)
        expect(reports[0]?.context.operation).toBe(
          "auxiliary.integrations.linear.integrate",
        )
      },
      authProbe,
    )

    const mediaProbe = makeProbe()
    mediaProbe.mediaFailure = true
    await withHandler(
      async ({ handler, reports }) => {
        const response = await handler(
          new Request(
            "http://inline.test/file?id=file123&exp=2000000000&sig=valid",
          ),
        )
        expect(response.status).toBe(500)
        expect(await response.text()).toBe(
          "Internal Server Error",
        )
        expect(reports).toHaveLength(1)
      },
      mediaProbe,
    )
  })

  it("keeps every auxiliary dependency failure opaque at the actual route boundary", async () => {
    const cases: ReadonlyArray<{
      configure: (probe: Probe) => void
      operation: string
      request: Request
    }> = [
      {
        configure: (probe) => {
          probe.healthFailure = true
        },
        operation: "auxiliary.readyz",
        request: new Request(
          "http://inline.test/readyz",
        ),
      },
      {
        configure: (probe) => {
          probe.waitlistFailure = true
        },
        operation: "auxiliary.waitlist.count",
        request: new Request(
          "http://inline.test/waitlist/super_secret_sub_count",
        ),
      },
      {
        configure: (probe) => {
          probe.waitlistFailure = true
        },
        operation: "auxiliary.waitlist.subscribe",
        request: new Request(
          "http://inline.test/waitlist/subscribe",
          {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({
              email: "failure@example.com",
            }),
          },
        ),
      },
      {
        configure: (probe) => {
          probe.thereFailure = true
        },
        operation: "auxiliary.there.signup",
        request: new Request(
          "http://inline.test/api/there/signup",
          {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({
              email: "failure@example.com",
            }),
          },
        ),
      },
      {
        configure: (probe) => {
          probe.callbackOperationFailure = true
        },
        operation:
          "auxiliary.integrations.linear.callback",
        request: new Request(
          "http://inline.test/integrations/linear/callback?code=code&state=state-123",
          {
            headers: {
              cookie:
                "token=valid; state=state-123; spaceId=42",
            },
          },
        ),
      },
    ]

    for (const testCase of cases) {
      const probe = makeProbe()
      testCase.configure(probe)
      await withHandler(
        async ({ handler, reports }) => {
          const response = await handler(
            testCase.request.clone(),
          )
          expect(response.status).toBe(500)
          expect(await response.text()).toBe(
            "Internal Server Error",
          )
          expect(reports).toHaveLength(1)
          expect(
            reports[0]?.context.operation,
          ).toBe(testCase.operation)
          const publicErrorReference =
            response.headers.get("x-request-id")
          expect(publicErrorReference).not.toBeNull()
          expect(
            reports[0]?.context.requestId,
          ).toBe(publicErrorReference)
        },
        probe,
      )
    }
  })
})

describe("makeMediaOperations", () => {
  it("rejects signatures before lookup and bounds successful cache lifetime", async () => {
    let lookups = 0
    const operations = makeMediaOperations({
      filesPathPrefix: "files",
      verify: ({ sig }) => sig === "valid",
      lookup: async () => {
        lookups += 1
        return {
          fileType: "photo",
          pathEncrypted: Buffer.from("encrypted"),
          pathIv: Buffer.from("iv"),
          pathTag: Buffer.from("tag"),
          mimeType: "image/png",
          fileSize: 4,
        }
      },
      decryptPath: () => "photo.png",
      getObject: () => ({
        exists: async () => true,
        stream: () =>
          new Blob([
            new Uint8Array([4, 3, 2, 1]),
          ]).stream(),
        slice: (start, end) => ({
          stream: () =>
            new Blob([
              new Uint8Array([4, 3, 2, 1])
                .slice(start, end),
            ]).stream(),
        }),
      }),
      nowSeconds: () => 1_000,
    })

    const forbidden = await Effect.runPromise(
      operations.serveFile({
        id: "file123",
        exp: "2000",
        sig: "bad",
      }),
    )
    expect(forbidden.status).toBe(403)
    expect(await forbidden.text()).toBe("forbidden")
    expect(lookups).toBe(0)

    const success = await Effect.runPromise(
      operations.serveFile({
        id: "file123",
        exp: "10000",
        sig: "valid",
      }),
    )
    expect(success.status).toBe(200)
    expect(success.headers.get("cache-control")).toBe(
      "public, max-age=3600",
    )
    expect(success.headers.get("content-type")).toBe(
      "image/png",
    )
    expect(success.headers.get("accept-ranges")).toBe(
      "bytes",
    )
    expect(success.headers.get("content-length")).toBe(
      "4",
    )
    expect(
      Array.from(await success.bytes()),
    ).toEqual([4, 3, 2, 1])
    expect(lookups).toBe(1)

    const partial = await Effect.runPromise(
      operations.serveFile(
        {
          id: "file123",
          exp: "10000",
          sig: "valid",
        },
        { range: "bytes=1-2" },
      ),
    )
    expect(partial.status).toBe(206)
    expect(partial.headers.get("content-range")).toBe(
      "bytes 1-2/4",
    )
    expect(partial.headers.get("content-length")).toBe(
      "2",
    )
    expect(Array.from(await partial.bytes())).toEqual([
      3,
      2,
    ])

    const unsatisfiable = await Effect.runPromise(
      operations.serveFile(
        {
          id: "file123",
          exp: "10000",
          sig: "valid",
        },
        { range: "bytes=10-" },
      ),
    )
    expect(unsatisfiable.status).toBe(416)
    expect(
      unsatisfiable.headers.get("content-range"),
    ).toBe("bytes */4")

    const notModified = await Effect.runPromise(
      operations.serveFile(
        {
          id: "file123",
          exp: "10000",
          sig: "valid",
        },
        { ifNoneMatch: '"file123-4"' },
      ),
    )
    expect(notModified.status).toBe(304)

    const staleIfRange = await Effect.runPromise(
      operations.serveFile(
        {
          id: "file123",
          exp: "10000",
          sig: "valid",
        },
        {
          range: "bytes=1-2",
          ifRange: '"stale-validator"',
        },
      ),
    )
    expect(staleIfRange.status).toBe(200)
    expect(Array.from(await staleIfRange.bytes())).toEqual([
      4,
      3,
      2,
      1,
    ])
  })

  it("streams one video slice and propagates response cancellation", async () => {
    let slice: [number, number, string | undefined] | undefined
    let cancelled = false
    const operations = makeMediaOperations({
      filesPathPrefix: "files",
      verify: () => true,
      lookup: async () => ({
        fileType: "video",
        pathEncrypted: Buffer.from("encrypted"),
        pathIv: Buffer.from("iv"),
        pathTag: Buffer.from("tag"),
        mimeType: "video/mp4",
        fileSize: 100,
      }),
      decryptPath: () => "video.mp4",
      getObject: () => ({
        exists: async () => true,
        stream: () => new Blob([new Uint8Array(100)]).stream(),
        slice: (start, end, contentType) => {
          slice = [start, end, contentType]
          return {
            stream: () =>
              new ReadableStream<Uint8Array>({
                pull: (controller) => {
                  controller.enqueue(new Uint8Array([1]))
                },
                cancel: () => {
                  cancelled = true
                },
              }),
          }
        },
      }),
      nowSeconds: () => 1_000,
    })

    const response = await Effect.runPromise(
      operations.serveFile(
        {
          id: "INVstableVideo",
          exp: "2000",
          sig: "valid",
        },
        { range: "bytes=10-19" },
      ),
    )

    expect(response.status).toBe(206)
    expect(slice).toEqual([10, 20, "video/mp4"])
    const reader = response.body!.getReader()
    await reader.read()
    await reader.cancel()
    expect(cancelled).toBe(true)
  })

  it("keeps signature and stream dependency throws in the typed media channel", async () => {
    const base = {
      filesPathPrefix: "files",
      lookup: async () => ({
        fileType: "photo",
        pathEncrypted: Buffer.from("encrypted"),
        pathIv: Buffer.from("iv"),
        pathTag: Buffer.from("tag"),
        mimeType: "image/png",
        fileSize: 4,
      }),
      decryptPath: () => "photo.png",
      nowSeconds: () => 1_000,
    } as const
    const query = {
      id: "file123",
      exp: "2000",
      sig: "valid",
    }

    const signatureFailure = await Effect.runPromise(
      makeMediaOperations({
        ...base,
        verify: () => {
          throw new Error(
            "private signature failure",
          )
        },
        getObject: () => undefined,
      }).serveFile(query).pipe(Effect.flip),
    )
    expect(signatureFailure.operation).toBe(
      "signature",
    )

    const streamFailure = await Effect.runPromise(
      makeMediaOperations({
        ...base,
        verify: () => true,
        getObject: () => ({
          exists: async () => true,
          stream: () => {
            throw new Error(
              "private stream failure",
              )
            },
          slice: () => ({
            stream: () =>
              new Blob([new Uint8Array([1])])
                .stream(),
          }),
        }),
      }).serveFile(query).pipe(Effect.flip),
    )
    expect(streamFailure.operation).toBe("storage")
  })
})
