import {
  afterAll,
  afterEach,
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
  resetServerConfigCacheForTests,
} from "@in/server/modules/serverConfig"
import {
  setupTestLifecycle,
  testUtils,
} from "../__tests__/setup"
import {
  AdminSessionStore,
} from "./adminSecurity.effect"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { generateTotpCode, generateTotpSecret } from "@in/server/utils/totp"
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
  afterEach(resetServerConfigCacheForTests)

  it("creates a password and TOTP session and resets failures through the live HTTP route", async () => {
    const user = await testUtils.createUser("admin-password-security@example.test")
    const password = "synthetic admin password"
    const secret = generateTotpSecret()
    const sealed = encrypt(secret)
    await db.insert(superadminUsers).values({
      email: user.email!, userId: user.id,
      passwordHash: await Bun.password.hash(password, { algorithm: "bcrypt", cost: 4 }),
      passwordSetAt: new Date(), totpEnabledAt: new Date(),
      totpSecretEncrypted: sealed.encrypted, totpSecretIv: sealed.iv, totpSecretTag: sealed.authTag,
      failedLoginAttempts: 2, lastLoginAttemptAt: new Date(),
    })
    const response = await handle(new Request("http://inline.test/admin/auth/login", {
      method: "POST", headers: {
        origin: "https://admin.inline.chat", "content-type": "application/json", "user-agent": "security-test",
      },
      body: JSON.stringify({ email: user.email, password, totpCode: generateTotpCode(secret) }),
    }))
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ ok: true })
    expect(response.headers.get("set-cookie")).toContain("inline_admin_session=")
    const [account] = await db.select().from(superadminUsers).where(eq(superadminUsers.userId, user.id))
    expect(account!.failedLoginAttempts).toBe(0)
    const created = await db.select().from(superadminSessions).where(eq(superadminSessions.userId, user.id))
    expect(created).toHaveLength(1)
    expect(created[0]!.stepUpAt).not.toBeNull()
  })

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
      stepUpAt: now,
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

    const request = (path: string, init?: RequestInit) =>
      new Request(`http://inline.test${path}`, {
        ...init,
        headers: {
          cookie:
            `inline_admin_session=${token}`,
          origin:
            "https://admin.inline.chat",
          "user-agent": "admin-live-routes",
          ...init?.headers,
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

    for (const path of ["/admin/metrics/app", "/admin/metrics/overview"]) {
      const response = await handle(request(path))
      expect(response.status).toBe(200)
      expect(await response.json()).toMatchObject({
        ok: true,
        metrics: {
          reportingTimeZone: "UTC",
          asOf: expect.any(String),
          dailyActivity: expect.arrayContaining([
            expect.objectContaining({
              date: expect.any(String),
              activeUsers: expect.any(Number),
              newUsers: expect.any(Number),
              messages: expect.any(Number),
              threads: expect.any(Number),
            }),
          ]),
        },
      })
    }

    const initialConfig = await handle(
      request("/admin/server-config"),
    )
    expect(initialConfig.status).toBe(200)
    expect(await initialConfig.json()).toMatchObject({
      ok: true,
      settings: expect.arrayContaining([
        expect.objectContaining({
          key: "auth.signup_mode",
          databaseVersion: null,
        }),
      ]),
    })

    const updatedConfig = await handle(
      request("/admin/server-config", {
        method: "PUT",
        headers: {
          "content-type": "application/json",
        },
        body: JSON.stringify({
          key: "auth.signup_mode",
          value: "disabled",
          expectedVersion: null,
        }),
      }),
    )
    expect(updatedConfig.status).toBe(200)
    expect(await updatedConfig.json()).toMatchObject({
      ok: true,
      setting: {
        key: "auth.signup_mode",
        value: "disabled",
        source: "database",
        databaseValue: "disabled",
        databaseVersion: 1,
      },
    })

    const reserve = await handle(
      request("/admin/reserved-usernames", {
        method: "POST",
        headers: {
          "content-type": "application/json",
        },
        body: JSON.stringify({ username: " @LaunchWord " }),
      }),
    )
    expect(reserve.status).toBe(200)
    expect(await reserve.json()).toEqual({
      ok: true,
      usernames: [{
        username: "launchword",
        createdAt: expect.any(String),
      }],
    })

    const duplicateReserve = await handle(
      request("/admin/reserved-usernames", {
        method: "POST",
        headers: {
          "content-type": "application/json",
        },
        body: JSON.stringify({ username: "LAUNCHWORD" }),
      }),
    )
    expect(duplicateReserve.status).toBe(200)
    expect((await duplicateReserve.json()).usernames).toHaveLength(1)

    const builtInReserve = await handle(
      request("/admin/reserved-usernames", {
        method: "POST",
        headers: {
          "content-type": "application/json",
        },
        body: JSON.stringify({ username: "inline" }),
      }),
    )
    expect(builtInReserve.status).toBe(400)
    expect(await builtInReserve.json()).toEqual({
      ok: false,
      error: "built_in_reservation",
    })

    const reservedList = await handle(
      request("/admin/reserved-usernames"),
    )
    expect(reservedList.status).toBe(200)
    expect(await reservedList.json()).toMatchObject({
      ok: true,
      usernames: [{ username: "launchword" }],
    })

    const unreserve = await handle(
      request("/admin/reserved-usernames", {
        method: "DELETE",
        headers: {
          "content-type": "application/json",
        },
        body: JSON.stringify({ username: "@LaunchWord" }),
      }),
    )
    expect(unreserve.status).toBe(200)
    expect(await unreserve.json()).toEqual({
      ok: true,
      usernames: [],
    })
  })
})
