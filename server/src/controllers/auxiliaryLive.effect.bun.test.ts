import { describe, expect, it } from "bun:test"
import {
  Context,
  ErrorReporter as EffectErrorReporter,
  Layer,
} from "effect"
import {
  HttpRouter,
  HttpServer,
} from "effect/unstable/http"
import {
  ErrorReporter,
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
  AuxiliaryApiGroup,
} from "./auxiliary.effect"
import {
  setupTestLifecycle,
} from "../__tests__/setup"

setupTestLifecycle()

const makeLiveHandler = async () => {
  const AuxiliaryRouteGroupLive = await import(
    "./auxiliaryLive.effect"
  ).then((module) => module.AuxiliaryRouteGroupLive)
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
      handlers: AuxiliaryRouteGroupLive,
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
  }
}

describe(
  "AuxiliaryRouteGroupLive",
  () => {
    it("serves root and health through production adapters", async () => {
      const live = await makeLiveHandler()

      try {
        const effectRoot = await live.handler(
          new Request("http://localhost/"),
        )
        expect(effectRoot.status).toBe(200)
        expect(
          effectRoot.headers.get("content-type"),
        ).toBe("text/html; charset=utf8")
        const effectRootBody =
          await effectRoot.text()
        // The uptime monitor matches this marker and the page's exact layout.
        expect(effectRootBody).toContain(
          "inline server is running",
        )
        expect(effectRootBody).toContain(
          "              padding: 0; \n",
        )
        expect(effectRootBody).toContain(
          "            }\n              \n          </style>",
        )

        for (const path of [
          "/health",
          "/healthz",
          "/livez",
        ]) {
          const effectHealth = await live.handler(
            new Request(
              `http://localhost${path}`,
            ),
          )
          expect(effectHealth.status).toBe(200)
          expect(await effectHealth.json()).toMatchObject({
            ok: true,
            status: "ok",
            draining: false,
            checks: {
              lifecycle: { ok: true },
            },
          })
        }

        const effectReadiness = await live.handler(
          new Request(
            "http://localhost/readyz",
          ),
        )
        const effectReadinessBody =
          await effectReadiness.json()

        expect(effectReadiness.status).toBe(200)
        expect(effectReadinessBody).toMatchObject({
          ok: true,
          // The production adapter reports optional-broker degradation
          // without withdrawing readiness.
          status: "degraded",
          draining: false,
          checks: {
            broker: { ok: false, error: "broker_unavailable" },
            database: { ok: true },
            lifecycle: { ok: true },
          },
        })
        expect(
          effectReadinessBody.checks.database.error,
        ).toBeUndefined()
      } finally {
        await live.dispose()
      }
    })

    it("keeps the legacy malformed-input and callback responses before dependencies run", async () => {
      const live = await makeLiveHandler()
      const json = { "content-type": "application/json" }
      const validation = (on: "body" | "query", property: string) => ({
        status: 422,
        contentType: "application/json",
        json: { type: "validation", on, property },
      })
      const cases = [
        {
          request: new Request("http://localhost/waitlist/subscribe", { method: "POST", headers: json, body: "{" }),
          expected: { status: 400, contentType: null, text: "Bad Request" },
        },
        {
          request: new Request("http://localhost/waitlist/subscribe", { method: "POST", headers: json, body: "{}" }),
          expected: validation("body", "/email"),
        },
        {
          // No content type: the body is not decoded as JSON.
          request: new Request("http://localhost/waitlist/subscribe", {
            method: "POST",
            body: JSON.stringify({ email: "not-decoded@example.com" }),
          }),
          expected: validation("body", "root"),
        },
        {
          request: new Request("http://localhost/api/there/signup", { method: "POST", headers: json, body: "{}" }),
          expected: validation("body", "/email"),
        },
        {
          request: new Request("http://localhost/file"),
          expected: validation("query", "/id"),
        },
        {
          request: new Request("http://localhost/file?id=INPzxcvbnMASDFGHJKLQW12&exp=1&sig=bad"),
          expected: { status: 403, contentType: null, text: "forbidden" },
        },
        {
          request: new Request("http://localhost/integrations/linear/integrate"),
          expected: validation("query", "/token"),
        },
        {
          // OAuth error callbacks may omit the code, so the empty query first
          // reports the still-required state.
          request: new Request("http://localhost/integrations/notion/callback"),
          expected: validation("query", "/state"),
        },
      ] as const

      try {
        for (const { request, expected } of cases) {
          const response = await live.handler(request)
          const route = `${request.method} ${request.url}`
          expect({ route, status: response.status }).toEqual({ route, status: expected.status })
          expect(response.headers.get("content-type")).toBe(expected.contentType)
          if ("json" in expected) {
            expect(await response.json()).toMatchObject(expected.json)
          } else {
            expect(await response.text()).toBe(expected.text)
          }
        }

        for (const provider of [
          "linear",
          "notion",
        ] as const) {
          const effectResponse = await live.handler(
            new Request(
              `http://localhost/integrations/${provider}/callback?code=test-code&state=test-state`,
            ),
          )

          // An unclaimed callback is not redirected into an app scheme. It
          // clears the browser cookies and reports the expired session
          // directly; valid app handoffs use claimed, single-use connector
          // state and are covered by the route tests.
          expect(effectResponse.status).toBe(400)
          expect(await effectResponse.json()).toEqual({
            error:
              "OAuth session expired or was already used",
          })
          expect(
            effectResponse.headers.get(
              "location",
            ),
          ).toBeNull()
          expect(
            effectResponse.headers.get(
              "set-cookie",
            ),
          ).toContain(
            "state=; Max-Age=0",
          )
        }
      } finally {
        await live.dispose()
      }
    })
  },
)
