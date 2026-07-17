import {
  afterAll,
  describe,
  expect,
  it,
} from "bun:test"
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
  admin as legacyAdmin,
} from "./admin"
import {
  AdminApiGroup,
} from "./admin.effect"
import {
  AdminRouteGroupLive,
} from "./adminLive.effect"
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

interface AdminParityCase {
  readonly method: "GET" | "POST"
  readonly path: string
  readonly body?: string | undefined
  readonly status: 400 | 401
  readonly text: string
  readonly contentType:
    | "json"
    | "legacy-empty-effect-text"
    | "empty"
}

const unauthorized = JSON.stringify({
  ok: false,
  error: "unauthorized",
})

const malformed = (
  path: string,
): AdminParityCase => ({
  method: "POST",
  path,
  body: "{",
  status: 400,
  text: "Bad Request",
  contentType: "legacy-empty-effect-text",
})

const guarded = (
  method: "GET" | "POST",
  path: string,
  body?: Record<string, unknown>,
): AdminParityCase => ({
  method,
  path,
  ...(body === undefined
    ? {}
    : { body: JSON.stringify(body) }),
  status: 401,
  text: unauthorized,
  contentType: "json",
})

const cases: readonly AdminParityCase[] = [
  malformed("/admin/auth/send-email-code"),
  malformed("/admin/auth/verify-email-code"),
  malformed("/admin/auth/login"),
  guarded("POST", "/admin/auth/set-password", {
    password: "valid",
  }),
  guarded("GET", "/admin/auth/totp/setup"),
  guarded("POST", "/admin/auth/totp/verify", {
    code: "123456",
  }),
  guarded("POST", "/admin/auth/step-up", {
    password: "valid",
    totpCode: "123456",
  }),
  guarded("POST", "/admin/auth/logout"),
  guarded("GET", "/admin/me"),
  guarded("GET", "/admin/metrics/technical"),
  guarded("GET", "/admin/metrics/app"),
  guarded("GET", "/admin/metrics/overview"),
  guarded(
    "GET",
    "/admin/metrics/active-users?period=today",
  ),
  guarded("GET", "/admin/waitlist"),
  guarded("GET", "/admin/spaces"),
  guarded("GET", "/admin/users"),
  {
    ...guarded(
      "GET",
      "/admin/users/1/avatar",
    ),
    text: "",
    contentType: "empty",
  },
  guarded("GET", "/admin/users/1"),
  guarded("GET", "/admin/invites"),
  guarded("POST", "/admin/invites/generate", {
    count: 1,
  }),
  guarded("POST", "/admin/users/1/invites", {
    count: 1,
  }),
  guarded(
    "POST",
    "/admin/users/1/sessions/2/revoke",
  ),
  guarded("POST", "/admin/users/1/update", {
    firstName: "Inline",
  }),
]

const platformApi = makePlatformApiBase(
  "https://api.inline.chat",
).add(AdminApiGroup)

const application = makeHttpApplication({
  platform: defineExecutableHttpApi({
    ...defineOpenApiDocument({
      api: platformApi,
      jsonPath: "/v1/reference/json",
      swaggerPath: "/v1/reference",
    }),
    handlers: AdminRouteGroupLive,
  }),
  bot: defineExecutableHttpApi({
    ...defineOpenApiDocument({
      api: makeBotApiBase(
        "https://api.inline.chat",
      ),
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
  { disableLogger: true },
)

afterAll(() => webHandler.dispose())

const replacementHandle = (request: Request) =>
  webHandler.handler(
    request,
    Context.empty() as unknown as Context.Context<unknown>,
  )

const mediaType = (response: Response) =>
  response.headers
    .get("content-type")
    ?.split(";", 1)[0] ?? null

describe("Admin legacy/Effect differential", () => {
  it("matches guarded status, body, meaningful headers, and cookies on all 23 routes", async () => {
    expect(cases).toHaveLength(23)

    for (const testCase of cases) {
      const request = () =>
        new Request(
          `http://inline.test${testCase.path}`,
          {
            method: testCase.method,
            headers: {
              origin: "https://admin.inline.chat",
              "user-agent":
                "admin-differential-test",
              ...(testCase.body === undefined
                ? {}
                : {
                    "content-type":
                      "application/json",
                  }),
            },
            body: testCase.body,
          },
        )
      const legacy =
        await legacyAdmin.handle(request())
      const replacement =
        await replacementHandle(request())

      expect({
        route: `${testCase.method} ${testCase.path}`,
        legacy: {
          status: legacy.status,
          text: await legacy.text(),
        },
        replacement: {
          status: replacement.status,
          text: await replacement.text(),
        },
      }).toMatchObject({
        legacy: {
          status: testCase.status,
          text: testCase.text,
        },
        replacement: {
          status: testCase.status,
          text: testCase.text,
        },
      })

      if (testCase.contentType === "json") {
        expect({
          legacy: mediaType(legacy),
          replacement: mediaType(replacement),
        }).toEqual({
          legacy: "application/json",
          replacement: "application/json",
        })
      } else if (
        testCase.contentType === "empty"
      ) {
        expect({
          legacy: mediaType(legacy),
          replacement: mediaType(replacement),
        }).toEqual({
          legacy: null,
          replacement: null,
        })
      } else {
        // Equivalent normalization: the legacy plain-text body omitted its
        // media type; Effect declares that same body as text/plain.
        expect({
          legacy: mediaType(legacy),
          replacement: mediaType(replacement),
        }).toEqual({
          legacy: null,
          replacement: "text/plain",
        })
      }

      for (const header of [
        "set-cookie",
        "cache-control",
      ]) {
        expect(legacy.headers.get(header)).toBeNull()
        expect(
          replacement.headers.get(header),
        ).toBeNull()
      }
    }
  })
})
