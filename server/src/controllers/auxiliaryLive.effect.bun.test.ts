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
  "AuxiliaryRouteGroupLive compatibility",
  () => {
    it("matches root and health behavior through production adapters", async () => {
      const [
        { default: Elysia },
        { root },
        { health },
      ] = await Promise.all([
        import("elysia"),
        import("./root"),
        import("./health"),
      ])
      const legacy = new Elysia()
        .use(root)
        .use(health)
      const live = await makeLiveHandler()

      try {
        const [legacyRoot, effectRoot] =
          await Promise.all([
            legacy.handle(
              new Request("http://localhost/"),
            ),
            live.handler(
              new Request("http://localhost/"),
            ),
          ])
        expect(effectRoot.status).toBe(
          legacyRoot.status,
        )
        expect(
          effectRoot.headers.get("content-type"),
        ).toBe(
          legacyRoot.headers.get("content-type"),
        )
        const effectRootBody =
          await effectRoot.text()
        const legacyRootBody =
          await legacyRoot.text()
        expect(effectRootBody).toBe(legacyRootBody)
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
          const [legacyHealth, effectHealth] =
            await Promise.all([
              legacy.handle(
                new Request(
                  `http://localhost${path}`,
                ),
              ),
              live.handler(
                new Request(
                  `http://localhost${path}`,
                ),
              ),
            ])
          const legacyBody =
            await legacyHealth.json()
          const effectBody =
            await effectHealth.json()

          expect(effectHealth.status).toBe(
            legacyHealth.status,
          )
          expect(effectBody).toMatchObject({
            ok: legacyBody.ok,
            status: legacyBody.status,
            draining: legacyBody.draining,
            checks: {
              lifecycle:
                legacyBody.checks.lifecycle,
            },
          })
        }

        const [legacyReadiness, effectReadiness] =
          await Promise.all([
            legacy.handle(
              new Request(
                "http://localhost/readyz",
              ),
            ),
            live.handler(
              new Request(
                "http://localhost/readyz",
              ),
            ),
          ])
        const legacyReadinessBody =
          await legacyReadiness.json()
        const effectReadinessBody =
          await effectReadiness.json()

        expect(effectReadiness.status).toBe(
          legacyReadiness.status,
        )
        expect(effectReadiness.status).toBe(200)
        expect(effectReadinessBody).toMatchObject({
          ok: legacyReadinessBody.ok,
          // The production adapter now reports optional-broker degradation
          // without withdrawing readiness; liveness compatibility is unchanged.
          status: "degraded",
          draining: legacyReadinessBody.draining,
          checks: {
            broker: { ok: false, error: "broker_unavailable" },
            database: {
              ok:
                legacyReadinessBody.checks.database.ok,
            },
            lifecycle:
              legacyReadinessBody.checks.lifecycle,
          },
        })
        expect(
          effectReadinessBody.checks.database.error,
        ).toBe(
          legacyReadinessBody.checks.database.error,
        )
      } finally {
        await live.dispose()
      }
    })

    it("matches legacy malformed-input and callback quirks before dependencies run", async () => {
      const [
        { default: Elysia },
        { waitlist },
        { there },
        { media },
        { integrationsRouter },
      ] = await Promise.all([
        import("elysia"),
        import("./extra/waitlist"),
        import("./extra/there"),
        import("./media"),
        import(
          "./integrations/integrationsRouter"
        ),
      ])
      const legacy = new Elysia()
        .use(waitlist)
        .use(there)
        .use(media)
        .use(integrationsRouter)
      const live = await makeLiveHandler()
      const requests = [
        new Request(
          "http://localhost/waitlist/subscribe",
          {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: "{",
          },
        ),
        new Request(
          "http://localhost/waitlist/subscribe",
          {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: "{}",
          },
        ),
        new Request(
          "http://localhost/waitlist/subscribe",
          {
            method: "POST",
            body: JSON.stringify({
              email: "not-decoded@example.com",
            }),
          },
        ),
        new Request(
          "http://localhost/api/there/signup",
          {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: "{}",
          },
        ),
        new Request("http://localhost/file"),
        new Request(
          "http://localhost/file?id=INPzxcvbnMASDFGHJKLQW12&exp=1&sig=bad",
        ),
        new Request(
          "http://localhost/integrations/linear/integrate",
        ),
        new Request(
          "http://localhost/integrations/notion/callback",
        ),
      ]

      try {
        for (const request of requests) {
          const [legacyResponse, effectResponse] =
            await Promise.all([
              legacy.handle(request.clone()),
              live.handler(request),
            ])

          expect(effectResponse.status).toBe(
            legacyResponse.status,
          )
          expect(
            effectResponse.headers.get(
              "content-type",
            ),
          ).toBe(
            legacyResponse.headers.get(
              "content-type",
            ),
          )
          const effectBody =
            await effectResponse.text()
          const legacyBody =
            await legacyResponse.text()
          if (
            new URL(request.url).pathname ===
              "/integrations/notion/callback"
          ) {
            // The replacement intentionally accepts OAuth error callbacks
            // without a code, so an entirely empty query first reports the
            // still-required state. The legacy oracle rejects code first.
            expect(
              JSON.parse(effectBody),
            ).toMatchObject({
              property: "/state",
            })
            expect(
              JSON.parse(legacyBody),
            ).toMatchObject({
              property: "/code",
            })
          } else {
            expect(effectBody).toBe(
              legacyBody,
            )
          }
        }

        for (const provider of [
          "linear",
          "notion",
        ] as const) {
          const request = new Request(
            `http://localhost/integrations/${provider}/callback?code=test-code&state=test-state`,
          )
          const [legacyResponse, effectResponse] =
            await Promise.all([
              legacy.handle(request.clone()),
              live.handler(request),
            ])

          // The replacement does not redirect an unclaimed callback into an
          // app scheme. It clears the legacy cookies and reports the expired
          // browser session directly; valid app handoffs use claimed,
          // single-use connector state and are covered by the route tests.
          const effectBody =
            await effectResponse.json()
          expect(legacyResponse.status).toBe(302)
          expect(effectBody).toEqual({
            error:
              "OAuth session expired or was already used",
          })
          expect(effectResponse.status).toBe(400)
          expect(
            legacyResponse.headers.get(
              "location",
            ),
          ).toContain(
            `${provider}?success=false&error=missing_cookie`,
          )
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
