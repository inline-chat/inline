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

interface AdminGuardCase {
  readonly method: "GET" | "POST"
  readonly path: string
  readonly body?: string | undefined
  readonly status: 400 | 401
  readonly text: string
  readonly contentType:
    | "json"
    | "text"
    | "empty"
}

const unauthorized = JSON.stringify({
  ok: false,
  error: "unauthorized",
})

const malformed = (
  path: string,
): AdminGuardCase => ({
  method: "POST",
  path,
  body: "{",
  status: 400,
  text: "Bad Request",
  contentType: "text",
})

const guarded = (
  method: "GET" | "POST",
  path: string,
  body?: Record<string, unknown>,
): AdminGuardCase => ({
  method,
  path,
  ...(body === undefined
    ? {}
    : { body: JSON.stringify(body) }),
  status: 401,
  text: unauthorized,
  contentType: "json",
})

const cases: readonly AdminGuardCase[] = [
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

const handle = (request: Request) =>
  webHandler.handler(
    request,
    Context.empty() as unknown as Context.Context<unknown>,
  )

const mediaType = (response: Response) =>
  response.headers
    .get("content-type")
    ?.split(";", 1)[0] ?? null

describe("Admin route guards", () => {
  it("rejects malformed and unauthenticated requests with exact status, body, and headers on all 23 routes", async () => {
    expect(cases).toHaveLength(23)

    for (const testCase of cases) {
      const response = await handle(
        new Request(`http://inline.test${testCase.path}`, {
          method: testCase.method,
          headers: {
            origin: "https://admin.inline.chat",
            "user-agent": "admin-guard-test",
            ...(testCase.body === undefined ? {} : { "content-type": "application/json" }),
          },
          body: testCase.body,
        }),
      )

      expect({
        route: `${testCase.method} ${testCase.path}`,
        status: response.status,
        text: await response.text(),
      }).toEqual({
        route: `${testCase.method} ${testCase.path}`,
        status: testCase.status,
        text: testCase.text,
      })
      expect(mediaType(response)).toBe(
        testCase.contentType === "json" ? "application/json" : testCase.contentType === "empty" ? null : "text/plain",
      )
      expect(response.headers.get("set-cookie")).toBeNull()
      expect(response.headers.get("cache-control")).toBeNull()
    }
  })
})
