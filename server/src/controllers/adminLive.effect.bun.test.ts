import {
  afterAll,
  describe,
  expect,
  it,
} from "bun:test"
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
  eq,
} from "drizzle-orm"
import {
  db,
} from "@in/server/db"
import {
  superadminSessions,
  superadminUsers,
} from "@in/server/db/schema"
import {
  generateToken,
  hashToken,
} from "@in/server/utils/auth"
import {
  setupTestLifecycle,
  testUtils,
} from "../__tests__/setup"
import {
  AdminSessionStore,
} from "./adminSecurity.effect"
import {
  AdminSessionStoreLive,
} from "./adminSecurityLive.effect"
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

describe("AdminSessionStoreLive", () => {
  setupTestLifecycle()

  it("loads and refreshes a database-backed admin session", async () => {
    const user = await testUtils.createUser(
      "effect-admin-session@example.com",
    )
    if (!user.email) {
      throw new Error("Expected test user email")
    }
    await db.insert(superadminUsers).values({
      email: user.email,
      userId: user.id,
      passwordHash: "configured",
      passwordSetAt: new Date(),
      totpEnabledAt: new Date(),
    })

    const { token, tokenHash } =
      await generateToken(user.id)
    const before = new Date(Date.now() - 60_000)
    const inserted = (
      await db
        .insert(superadminSessions)
        .values({
          userId: user.id,
          tokenHash,
          lastSeenAt: before,
          expiresAt: new Date(
            Date.now() + 24 * 60 * 60 * 1_000,
          ),
          idleExpiresAt: new Date(
            Date.now() + 24 * 60 * 60 * 1_000,
          ),
          userAgentHash: hashToken(
            "admin-live-test",
          ),
        })
        .returning()
    )[0]
    if (!inserted) {
      throw new Error("Expected admin session row")
    }

    const loaded = await Effect.runPromise(
      AdminSessionStore.use((store) =>
        store.lookup(token, "admin-live-test"),
      ).pipe(Effect.provide(AdminSessionStoreLive)),
    )
    expect(loaded).toMatchObject({
      sessionId: inserted.id,
      userId: user.id,
      email: user.email,
      passwordSet: true,
      totpEnabled: true,
    })

    const refreshed = (
      await db
        .select()
        .from(superadminSessions)
        .where(
          eq(
            superadminSessions.id,
            inserted.id,
          ),
        )
    )[0]
    if (!refreshed?.lastSeenAt) {
      throw new Error(
        "Expected refreshed last-seen timestamp",
      )
    }
    expect(refreshed.lastSeenAt.getTime()).toBeGreaterThan(
      before.getTime(),
    )
  })

  it("rejects a session whose user-agent binding changed", async () => {
    const user = await testUtils.createUser(
      "effect-admin-agent@example.com",
    )
    if (!user.email) {
      throw new Error("Expected test user email")
    }
    await db.insert(superadminUsers).values({
      email: user.email,
      userId: user.id,
    })
    const { token, tokenHash } =
      await generateToken(user.id)
    await db.insert(superadminSessions).values({
      userId: user.id,
      tokenHash,
      lastSeenAt: new Date(),
      expiresAt: new Date(
        Date.now() + 24 * 60 * 60 * 1_000,
      ),
      idleExpiresAt: new Date(
        Date.now() + 24 * 60 * 60 * 1_000,
      ),
      userAgentHash: hashToken("expected-agent"),
    })

    const loaded = await Effect.runPromise(
      AdminSessionStore.use((store) =>
        store.lookup(token, "different-agent"),
      ).pipe(Effect.provide(AdminSessionStoreLive)),
    )
    expect(loaded).toBeNull()

    const missingAgent =
      await Effect.runPromise(
        AdminSessionStore.use((store) =>
          store.lookup(token, ""),
        ).pipe(
          Effect.provide(
            AdminSessionStoreLive,
          ),
        ),
      )
    expect(missingAgent).toBeNull()
  })

  it("executes successful Auth, Management, and Metrics Live operations through HTTP", async () => {
    const user = await testUtils.createUser(
      "effect-admin-live-routes@example.com",
    )
    if (!user.email) {
      throw new Error("Expected test user email")
    }
    await db.insert(superadminUsers).values({
      email: user.email,
      userId: user.id,
      passwordHash: "configured",
      passwordSetAt: new Date(),
      totpEnabledAt: new Date(),
    })
    const { token, tokenHash } =
      await generateToken(user.id)
    const now = new Date()
    await db.insert(superadminSessions).values({
      userId: user.id,
      tokenHash,
      lastSeenAt: now,
      expiresAt: new Date(
        now.getTime() + 24 * 60 * 60 * 1_000,
      ),
      idleExpiresAt: new Date(
        now.getTime() + 24 * 60 * 60 * 1_000,
      ),
      userAgentHash: hashToken(
        "admin-live-routes",
      ),
    })

    const request = (path: string) =>
      new Request(`http://inline.test${path}`, {
        headers: {
          cookie:
            `inline_admin_session=${token}`,
          origin:
            "https://admin.inline.chat",
          "user-agent": "admin-live-routes",
        },
      })

    const me = await handle(request("/admin/me"))
    expect(me.status).toBe(200)
    expect(await me.json()).toMatchObject({
      ok: true,
      user: {
        id: user.id,
        email: user.email,
      },
    })

    const waitlist = await handle(
      request("/admin/waitlist?query=no-match"),
    )
    expect(waitlist.status).toBe(200)
    expect(await waitlist.json()).toMatchObject({
      ok: true,
      entries: [],
    })

    const technical = await handle(
      request("/admin/metrics/technical"),
    )
    expect(technical.status).toBe(200)
    expect(await technical.json()).toMatchObject({
      ok: true,
      metrics: {
        server: {
          uptimeSeconds: expect.any(Number),
        },
      },
    })
  })
})
