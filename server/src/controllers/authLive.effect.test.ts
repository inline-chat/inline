import { describe, expect, it } from "@effect/vitest"
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
  AuthApiGroup,
} from "./auth.effect"
const makeLiveHandler = async () => {
  const {
    AuthRouteGroupLive,
  } = await import("./authLive.effect")
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
      handlers: AuthRouteGroupLive,
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
  const webHandler = HttpRouter.toWebHandler(application, {
    disableLogger: true,
  })

  return {
    dispose: webHandler.dispose,
    handler: (request: Request) =>
      webHandler.handler(request, Context.empty()),
  }
}

const describeWithBun =
  process.versions.bun === undefined
    ? describe.skip
    : describe

describeWithBun("AuthRouteGroupLive", () => {
  it("preserves transport and auth rejection boundaries through production adapters", async () => {
    const live = await makeLiveHandler()

    try {
      const malformedIdentity = await live.handler(
        new Request("http://inline.test/v1/sendEmailCode", {
          method: "POST",
          headers: {
            "content-type": "application/json",
          },
          body: "{",
        }),
      )
      expect(malformedIdentity.status).toBe(500)
      expect(await malformedIdentity.json()).toMatchObject({
        ok: false,
        error: "SERVER_ERROR",
      })

      const malformedOAuth = await live.handler(
        new Request("http://inline.test/oauth/register", {
          method: "POST",
          headers: {
            "content-type": "application/json",
          },
          body: "{",
        }),
      )
      expect(malformedOAuth.status).toBe(400)
      expect(malformedOAuth.headers.has("content-type")).toBe(
        false,
      )
      expect(await malformedOAuth.text()).toBe("Bad Request")

      const missingSession = await live.handler(
        new Request("http://inline.test/v1/logout"),
      )
      expect(missingSession.status).toBe(401)
      expect(await missingSession.json()).toMatchObject({
        ok: false,
        error: "UNAUTHORIZED",
      })

      const missingMcpSecret = await live.handler(
        new Request("http://inline.test/oauth/introspect", {
          method: "POST",
          headers: {
            "content-type":
              "application/x-www-form-urlencoded",
          },
          body: "token=not-a-real-token",
        }),
      )
      expect(missingMcpSecret.status).toBe(401)
      expect(await missingMcpSecret.json()).toEqual({
        error: "unauthorized",
      })
    } finally {
      await live.dispose()
    }
  })
})
