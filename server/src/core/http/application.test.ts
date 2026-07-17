import { describe, expect, it } from "@effect/vitest"
import {
  Context,
  Effect,
  ErrorReporter as EffectErrorReporter,
  Layer,
  Option,
  Schema,
} from "effect"
import {
  HttpRouter,
  HttpServer,
} from "effect/unstable/http"
import {
  HttpApiBuilder,
  HttpApiEndpoint,
  HttpApiGroup,
} from "effect/unstable/httpapi"
import { RequestId } from "../helpers/requestId"
import {
  defineExecutableHttpApi,
  makeHttpApplication,
} from "./application"
import {
  parseTrustedClientIpHeader,
} from "./middleware"
import {
  defineOpenApiDocument,
  makeBotApiBase,
  makePlatformApiBase,
  PLATFORM_API_ID,
} from "./openApi"
import {
  defineHttpRouteGroup,
} from "./routeGroup"
import {
  httpRateLimitErrorBody,
  type HttpRateLimiterOptions,
} from "./rateLimit"
import {
  HttpRequestContext,
  type HttpRequestContextShape,
} from "./requestContext"

const ProbeResponse = Schema.Struct({
  clientIp: Schema.String,
  method: Schema.String,
  path: Schema.String,
  requestId: Schema.String,
  startedAtMillis: Schema.Number,
})

const ProbeGroup = HttpApiGroup.make("kernelProbe").add(
  HttpApiEndpoint.get("getProbe", "/v1/probe", {
    success: ProbeResponse,
  }),
)

const makeKernelApplication = ({
  generateRequestId,
  isProduction = false,
  nowMillis = () => 1_234,
  probeDefect,
  rateLimit,
  clientIpHeader,
}: {
  readonly clientIpHeader?: "cf-connecting-ip" | "x-real-ip" | undefined
  readonly generateRequestId?: (() => RequestId) | undefined
  readonly isProduction?: boolean | undefined
  readonly nowMillis?: (() => number) | undefined
  readonly probeDefect?: Error | undefined
  readonly rateLimit?: HttpRateLimiterOptions | undefined
} = {}) => {
  const platformApi = makePlatformApiBase("https://api.inline.chat").add(
    ProbeGroup,
  )
  const botApi = makeBotApiBase("https://api.inline.chat")
  const handlers = HttpApiBuilder.group(
    platformApi,
    "kernelProbe",
    (groupHandlers) =>
      groupHandlers.handle(
        "getProbe",
        () =>
          probeDefect === undefined
            ? HttpRequestContext.use((context) =>
              Effect.succeed({
                  clientIp: context.clientIp,
                  method: context.method,
                  path: context.path,
                  requestId: context.requestId,
                  startedAtMillis: context.startedAtMillis,
                }),
              )
            : Effect.die(probeDefect),
      ),
  )
  const routeGroup = defineHttpRouteGroup({
    apiId: PLATFORM_API_ID,
    document: "platform",
    group: ProbeGroup,
    handlers,
  })
  return makeHttpApplication({
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
      clientIpHeader,
      generateRequestId,
      isProduction,
      nowMillis,
      rateLimit,
    },
  })
}

const makeKernel = ({
  effectReporter,
  ...options
}: {
  readonly clientIpHeader?: "cf-connecting-ip" | "x-real-ip" | undefined
  readonly effectReporter?: EffectErrorReporter.ErrorReporter | undefined
  readonly generateRequestId?: (() => RequestId) | undefined
  readonly isProduction?: boolean | undefined
  readonly nowMillis?: (() => number) | undefined
  readonly probeDefect?: Error | undefined
  readonly rateLimit?: HttpRateLimiterOptions | undefined
} = {}) => {
  const application = makeKernelApplication(options).pipe(
    Layer.provide(HttpServer.layerServices),
    Layer.provide(
      EffectErrorReporter.layer(
        effectReporter === undefined ? [] : [effectReporter],
      ),
    ),
  )

  const webHandler = HttpRouter.toWebHandler(application, {
    disableLogger: true,
  })
  const testHostContext = Context.empty()

  return {
    dispose: webHandler.dispose,
    handler: (request: Request) =>
      webHandler.handler(request, testHostContext),
  }
}

describe("Effect HTTP kernel", () => {
  it("accepts only explicit single-address proxy headers", () => {
    expect(parseTrustedClientIpHeader(undefined)).toBeUndefined()
    expect(parseTrustedClientIpHeader(" x-real-ip ")).toBe("x-real-ip")
    expect(parseTrustedClientIpHeader("CF-Connecting-IP")).toBe(
      "cf-connecting-ip",
    )
    expect(() => {
      parseTrustedClientIpHeader("x-forwarded-for")
    }).toThrow("INLINE_TRUSTED_CLIENT_IP_HEADER")
  })

  it("provides isolated request context and compatibility headers", async () => {
    const kernel = makeKernel()

    try {
      const response = await kernel.handler(
        new Request("http://inline.test/v1/probe?secret=not-context", {
          headers: {
            "x-request-id": "request-42",
          },
        }),
      )

      expect(response.status).toBe(200)
      expect(await response.json()).toEqual({
        clientIp: "unresolved-client",
        method: "GET",
        path: "/v1/probe",
        requestId: "request-42",
        startedAtMillis: 1_234,
      })
      expect(response.headers.get("x-request-id")).toBe("request-42")
      expect(response.headers.get("x-content-type-options")).toBe("nosniff")
      expect(response.headers.get("x-frame-options")).toBe("SAMEORIGIN")
      expect(response.headers.has("strict-transport-security")).toBe(false)
    } finally {
      await kernel.dispose()
    }
  })

  it("does not share generated request IDs across concurrent requests", async () => {
    let nextId = 0
    const kernel = makeKernel({
      generateRequestId: () => RequestId.make(`generated-${++nextId}`),
    })

    try {
      const [first, second] = await Promise.all([
        kernel.handler(new Request("http://inline.test/v1/probe")),
        kernel.handler(new Request("http://inline.test/v1/probe")),
      ])
      const firstBody = await first.json() as {
        readonly requestId: string
      }
      const secondBody = await second.json() as {
        readonly requestId: string
      }

      expect(new Set([firstBody.requestId, secondBody.requestId])).toEqual(
        new Set(["generated-1", "generated-2"]),
      )
    } finally {
      await kernel.dispose()
    }
  })

  it("applies CORS and production security headers to preflight responses", async () => {
    const kernel = makeKernel({
      generateRequestId: () => RequestId.make("preflight-1"),
      isProduction: true,
    })

    try {
      const response = await kernel.handler(
        new Request("http://inline.test/v1/probe", {
          method: "OPTIONS",
          headers: {
            "access-control-request-headers": "authorization",
            "access-control-request-method": "GET",
            origin: "https://app.inline.chat",
          },
        }),
      )

      expect(response.status).toBe(204)
      expect(response.headers.get("access-control-allow-origin")).toBe(
        "https://app.inline.chat",
      )
      expect(response.headers.get("access-control-allow-credentials")).toBe(
        "true",
      )
      expect(response.headers.get("strict-transport-security")).toBe(
        "max-age=31536000; includeSubDomains",
      )
      expect(response.headers.get("x-request-id")).toBe("preflight-1")
    } finally {
      await kernel.dispose()
    }
  })

  it("keeps fallback responses inside the global middleware boundary", async () => {
    const kernel = makeKernel({
      generateRequestId: () => RequestId.make("fallback-1"),
    })

    try {
      const response = await kernel.handler(
        new Request("http://inline.test/not-yet-migrated"),
      )

      expect(response.status).toBe(404)
      expect(response.headers.get("x-request-id")).toBe("fallback-1")
      expect(response.headers.get("referrer-policy")).toBe("no-referrer")
    } finally {
      await kernel.dispose()
    }
  })

  it("preserves the bounded legacy rate-limit contract", async () => {
    const kernel = makeKernel({
      generateRequestId: () => RequestId.make("rate-limit-request"),
      rateLimit: {
        max: 2,
        windowMillis: 60_000,
      },
      clientIpHeader: "x-real-ip",
    })
    const request = () =>
      new Request("http://inline.test/v1/probe", {
        headers: {
          origin: "https://app.inline.chat",
          "x-real-ip": "192.0.2.20",
        },
      })

    try {
      const first = await kernel.handler(request())
      const second = await kernel.handler(request())
      const exceeded = await kernel.handler(request())

      expect(first.status).toBe(200)
      expect(first.headers.get("ratelimit-limit")).toBe("2")
      expect(first.headers.get("ratelimit-remaining")).toBe("1")
      expect(second.status).toBe(200)
      expect(second.headers.get("ratelimit-remaining")).toBe("0")

      expect(exceeded.status).toBe(420)
      expect(exceeded.headers.get("ratelimit-limit")).toBe("2")
      expect(exceeded.headers.get("ratelimit-remaining")).toBe("0")
      expect(exceeded.headers.get("ratelimit-reset")).toBe("60")
      expect(exceeded.headers.get("retry-after")).toBe("60")
      expect(exceeded.headers.get("access-control-allow-origin")).toBe(
        "https://app.inline.chat",
      )
      expect(await exceeded.json()).toEqual(httpRateLimitErrorBody)
    } finally {
      await kernel.dispose()
    }
  })

  it("trusts only the configured validated proxy address header", async () => {
    const kernel = makeKernel({
      clientIpHeader: "x-real-ip",
      rateLimit: {
        max: 1,
        windowMillis: 60_000,
      },
    })

    try {
      const first = await kernel.handler(
        new Request("http://inline.test/v1/probe", {
          headers: {
            "cf-connecting-ip": "198.51.100.10",
            "x-forwarded-for": "198.51.100.11",
            "x-real-ip": "192.0.2.20",
          },
        }),
      )
      const exceeded = await kernel.handler(
        new Request("http://inline.test/v1/probe", {
          headers: {
            "cf-connecting-ip": "198.51.100.12",
            "x-forwarded-for": "198.51.100.13",
            "x-real-ip": "192.0.2.20",
          },
        }),
      )

      expect(first.status).toBe(200)
      expect(exceeded.status).toBe(420)
    } finally {
      await kernel.dispose()
    }
  })

  it("uses one stable fallback when the configured proxy header is invalid", async () => {
    const kernel = makeKernel({
      clientIpHeader: "x-real-ip",
      rateLimit: {
        max: 1,
        windowMillis: 60_000,
      },
    })

    try {
      const first = await kernel.handler(
        new Request("http://inline.test/v1/probe", {
          headers: {
            "x-real-ip": "attacker-selected-a",
          },
        }),
      )
      const exceeded = await kernel.handler(
        new Request("http://inline.test/v1/probe", {
          headers: {
            "x-real-ip": "attacker-selected-b",
          },
        }),
      )

      expect(first.status).toBe(200)
      expect(exceeded.status).toBe(420)
    } finally {
      await kernel.dispose()
    }
  })

  it("serves executable platform and Bot OpenAPI surfaces", async () => {
    const kernel = makeKernel({
      generateRequestId: () => RequestId.make("docs-1"),
    })

    try {
      const platformResponse = await kernel.handler(
        new Request("http://inline.test/v1/reference/json"),
      )
      const platformSpec = await platformResponse.json() as {
        readonly info: {
          readonly contact: {
            readonly email: string
          }
          readonly termsOfService: string
          readonly title: string
        }
        readonly openapi: string
        readonly paths: Record<string, {
          readonly get?: {
            readonly responses?: Record<string, unknown>
          }
        }>
        readonly servers: ReadonlyArray<{
          readonly url: string
        }>
      }

      expect(platformResponse.status).toBe(200)
      expect(platformResponse.headers.get("cache-control")).toBe("no-store")
      expect(platformSpec.openapi).toBe("3.1.0")
      expect(platformSpec.info.title).toBe("Inline HTTP API Docs")
      expect(platformSpec.info.contact.email).toBe("hi@inline.chat")
      expect(platformSpec.info.termsOfService).toBe(
        "https://inline.chat/terms",
      )
      expect(platformSpec.paths["/v1/probe"]).toBeDefined()
      expect(
        platformSpec.paths["/v1/probe"]?.get?.responses?.["420"],
      ).toMatchObject({
        headers: {
          "Retry-After": {
            required: true,
          },
        },
      })
      expect(platformSpec.servers).toEqual([
        {
          description: "Production API server",
          url: "https://api.inline.chat",
        },
      ])

      const botResponse = await kernel.handler(
        new Request("http://inline.test/bot-api-reference/json"),
      )
      const botSpec = await botResponse.json() as {
        readonly info: {
          readonly description: string
          readonly title: string
        }
        readonly paths: Record<string, unknown>
      }

      expect(botResponse.status).toBe(200)
      expect(botSpec.info.title).toBe("Inline Bot HTTP API Docs")
      expect(botSpec.info.description).toContain("Authorization: Bearer")
      expect(botSpec.info.description).toContain("Targeting: use `chat_id`")
      expect(botSpec.info.description).toContain("### Quick check")
      expect(botSpec.paths).toEqual({})

      const swaggerResponse = await kernel.handler(
        new Request("http://inline.test/v1/reference"),
      )
      expect(swaggerResponse.status).toBe(200)
      expect(swaggerResponse.headers.get("content-type")).toContain("text/html")
      expect(await swaggerResponse.text()).toContain("Inline HTTP API Docs")
    } finally {
      await kernel.dispose()
    }
  })

  it("reports a defect once with request correlation and returns an opaque 500", async () => {
    const reports: Array<{
      readonly error: string
      readonly request: Option.Option<HttpRequestContextShape>
    }> = []
    const reporter = EffectErrorReporter.make(({ error, fiber }) => {
      reports.push({
        error: error.message,
        request: Context.getOption(fiber.context, HttpRequestContext),
      })
    })
    const kernel = makeKernel({
      effectReporter: reporter,
      generateRequestId: () => RequestId.make("failure-1"),
      probeDefect: new Error("private-provider-detail"),
      rateLimit: {
        max: 1,
      },
    })

    try {
      const response = await kernel.handler(
        new Request("http://inline.test/v1/probe"),
      )
      const retriedResponse = await kernel.handler(
        new Request("http://inline.test/v1/probe"),
      )

      expect(response.status).toBe(500)
      expect(retriedResponse.status).toBe(500)
      expect(response.headers.get("x-request-id")).toBe("failure-1")
      expect(await response.text()).not.toContain("private-provider-detail")
      expect(reports).toHaveLength(1)
      expect(reports[0]?.error).toContain("private-provider-detail")
      expect(
        Option.getOrUndefined(reports[0]?.request ?? Option.none())?.requestId,
      ).toBe("failure-1")
    } finally {
      await kernel.dispose()
    }
  })
})
