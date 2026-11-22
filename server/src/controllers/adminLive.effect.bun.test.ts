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
  billingSubscriptions,
  superadminSessions,
  superadminUsers,
  users,
} from "@in/server/db/schema"
import {
  generateToken,
  hashToken,
} from "@in/server/utils/auth"
import {
  resetServerConfigCacheForTests,
} from "@in/server/modules/serverConfig"
import {
  periodEnd,
} from "@in/server/modules/billing/credit"
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

  it("manages user and space billing through the live HTTP routes", async () => {
    const admin = await testUtils.createUser("effect-admin-billing@example.com")
    const [superadmin] = await db.insert(superadminUsers).values({
      email: admin.email!, userId: admin.id,
      passwordHash: "configured", passwordSetAt: new Date(), totpEnabledAt: new Date(),
    }).returning()
    const { token, tokenHash } = await generateToken(admin.id)
    const now = new Date()
    const day = 24 * 60 * 60 * 1_000
    await db.insert(superadminSessions).values({
      userId: admin.id, tokenHash, lastSeenAt: now, stepUpAt: now,
      expiresAt: new Date(now.getTime() + day), idleExpiresAt: new Date(now.getTime() + day),
      userAgentHash: hashToken("admin-billing"),
    })
    const customer = await testUtils.createUser("effect-admin-billing-customer@example.com")
    const space = (await testUtils.createSpace("Billing Space"))!
    const call = async (path: string, body?: unknown) => {
      const response = await handle(new Request(`http://inline.test${path}`, {
        method: body === undefined && !path.endsWith("/end") ? "GET" : "POST",
        headers: {
          cookie: `inline_admin_session=${token}`, origin: "https://admin.inline.chat",
          "user-agent": "admin-billing", "content-type": "application/json",
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      }))
      return { status: response.status, body: await response.json() }
    }

    expect(await call(`/admin/users/${customer.id}/billing`)).toEqual({
      status: 200,
      body: { ok: true, isPro: false, live: null, subscriptions: [], wallet: {}, walletEntries: [], orders: [] },
    })
    expect((await call("/admin/users/999999999/billing")).status).toBe(404)

    const credit = await call(`/admin/users/${customer.id}/billing/wallet`, {
      currency: "btc", amount: 250_000, kind: "btc_topup", reference: " tx-1 ",
    })
    expect(credit).toMatchObject({
      status: 200,
      body: { ok: true, entry: { currency: "btc", amount: 250_000, kind: "btc_topup", reference: "tx-1", adminId: superadmin!.id } },
    })
    expect((await call(`/admin/users/${customer.id}/billing/wallet`, {
      currency: "usd", amount: 1.5, kind: "adjustment",
    })).body).toEqual({ ok: false, error: "invalid_input" })

    const paidThrough = new Date(now.getTime() + 365 * day).toISOString()
    const plan = await call(`/admin/users/${customer.id}/billing/plan`, {
      plan: "pro", funding: "wallet", paidThrough, note: "a year of BTC",
      walletDebit: { currency: "btc", amount: 100_000 },
    })
    expect(plan).toMatchObject({
      status: 200,
      body: { ok: true, subscription: { plan: "pro", funding: "wallet", status: "active", paidThrough, endedAt: null } },
    })
    expect((await call(`/admin/users/${customer.id}/billing/plan`, {
      plan: "team", funding: "comp", paidThrough: null,
    })).body).toEqual({ ok: false, error: "invalid_input" })

    const detail = await call(`/admin/users/${customer.id}/billing`)
    expect(detail.body).toMatchObject({
      ok: true, isPro: true, live: { plan: "pro", paidThrough }, wallet: { btc: 150_000 },
    })
    expect(detail.body.walletEntries).toHaveLength(2)

    const ended = await call(`/admin/users/${customer.id}/billing/plan/end`)
    expect(ended).toMatchObject({ status: 200, body: { ok: true, subscription: { status: "canceled" } } })
    expect(await call(`/admin/users/${customer.id}/billing/plan/end`)).toEqual({
      status: 200, body: { ok: true, subscription: null },
    })

    const team = await call(`/admin/spaces/${space.id}/billing/plan`, {
      plan: "team", funding: "comp", paidThrough: null, seats: 5,
    })
    expect(team).toMatchObject({
      status: 200, body: { ok: true, subscription: { spaceId: space.id, plan: "team", seats: 5, paidThrough: null } },
    })
    expect((await call(`/admin/spaces/${space.id}/billing`)).body).toMatchObject({
      ok: true, isPro: true, live: { plan: "team" },
    })
  })

  it("records off-Stripe payments, starts credit plans and reports them with MRR on the financials overview", async () => {
    const admin = await testUtils.createUser("effect-admin-financials@example.com")
    const [superadmin] = await db.insert(superadminUsers).values({
      email: admin.email!, userId: admin.id,
      passwordHash: "configured", passwordSetAt: new Date(), totpEnabledAt: new Date(),
    }).returning()
    const { token, tokenHash } = await generateToken(admin.id)
    const now = new Date()
    const day = 24 * 60 * 60 * 1_000
    await db.insert(superadminSessions).values({
      userId: admin.id, tokenHash, lastSeenAt: now, stepUpAt: now,
      expiresAt: new Date(now.getTime() + day), idleExpiresAt: new Date(now.getTime() + day),
      userAgentHash: hashToken("admin-financials"),
    })
    const customer = await testUtils.createUser("effect-admin-financials-customer@example.com")
    await db.update(users).set({ firstName: "Fake", lastName: "Customer", username: "fakecustomer" })
      .where(eq(users.id, customer.id))
    const space = (await testUtils.createSpace("Fake Payments Space"))!
    const stripeSpace = (await testUtils.createSpace("Fake Stripe Space"))!
    const enterpriseSpace = (await testUtils.createSpace("Fake Enterprise Space"))!
    const compUser = await testUtils.createUser("effect-admin-financials-comp@example.com")
    await db.insert(billingSubscriptions).values({
      spaceId: stripeSpace.id, plan: "team", interval: "month", funding: "stripe", status: "active",
      paidThrough: new Date(now.getTime() + 30 * day), stripeSubscriptionId: "sub_fake_financials",
    })
    const call = async (path: string, body?: unknown) => {
      const response = await handle(new Request(`http://inline.test${path}`, {
        method: body === undefined ? "GET" : "POST",
        headers: {
          cookie: `inline_admin_session=${token}`, origin: "https://admin.inline.chat",
          "user-agent": "admin-financials", "content-type": "application/json",
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      }))
      return { status: response.status, body: await response.json() }
    }

    expect(await call("/admin/financials")).toEqual({
      status: 200,
      body: {
        ok: true,
        mrr: {
          mrrUsdCents: 2_000, arrUsdCents: 24_000, stripeUsdCents: 2_000, creditUsdCents: 0,
          payingPlans: 1, compPlans: 0, unpricedPlans: 0, creditMonthlyByCurrency: {},
        },
        live: [expect.objectContaining({
          spaceId: stripeSpace.id, funding: "stripe", isPro: true, spaceName: "Fake Stripe Space",
          chargeAmount: null, creditBalance: null, creditRunsOutAt: null, monthlyUsdCents: 2_000,
        })],
        balances: [], entries: [], orders: [], receivedOffStripe: {},
      },
    })

    // A BTC payment that starts a monthly plan 45 days back: it charges that period and the next.
    const occurredAt = "2026-10-01T12:00:00.000Z"
    const startAt = new Date(now.getTime() - 45 * day)
    const secondPeriod = periodEnd(startAt, "month")
    const userPaidThrough = periodEnd(secondPeriod, "month")
    const paid = await call(`/admin/users/${customer.id}/billing/payment`, {
      currency: "btc", amount: 120_000, reference: " fake-tx-1 ", occurredAt,
      plan: {
        plan: "pro", chargeAmount: 10_000, chargeInterval: "month", chargeUsdCents: 1_000,
        startAt: startAt.toISOString(), note: " paid in BTC ",
      },
    })
    expect(paid).toMatchObject({
      status: 200,
      body: {
        ok: true,
        credit: {
          userId: customer.id, currency: "btc", amount: 120_000, kind: "btc_topup", reference: "fake-tx-1",
          occurredAt, periodStart: null, adminId: superadmin!.id,
        },
        subscription: {
          userId: customer.id, plan: "pro", funding: "wallet", status: "active", note: "paid in BTC",
          paidThrough: userPaidThrough.toISOString(),
          chargeAmount: 10_000, chargeCurrency: "btc", chargeInterval: "month", chargeUsdCents: 1_000,
        },
      },
    })
    const userDetail = await call(`/admin/users/${customer.id}/billing`)
    expect(userDetail.body).toMatchObject({
      ok: true, isPro: true, wallet: { btc: 100_000 },
      live: { chargeAmount: 10_000, chargeCurrency: "btc", chargeInterval: "month", chargeUsdCents: 1_000 },
    })
    const charges = (userDetail.body.walletEntries as Array<{ kind: string; amount: number; periodStart: string | null }>)
      .filter((entry) => entry.kind === "plan_charge")
      .map((entry) => [entry.amount, entry.periodStart])
      .sort()
    expect(charges).toEqual([
      [-10_000, startAt.toISOString()],
      [-10_000, secondPeriod.toISOString()],
    ])

    const credited = await call(`/admin/spaces/${space.id}/billing/payment`, { currency: "usd", amount: 5_000 })
    expect(credited).toMatchObject({
      status: 200,
      body: { ok: true, credit: { spaceId: space.id, currency: "usd", amount: 5_000, kind: "admin_topup", occurredAt: null }, subscription: null },
    })

    for (const invalid of [
      { currency: "usd", amount: 0 },
      { currency: "usd", amount: 1.5 },
      { currency: "usd", amount: 100, occurredAt: "not-a-date" },
      { currency: "usd", amount: 100, plan: { plan: "team", chargeAmount: 100, chargeInterval: "month" } },
      { currency: "usd", amount: 100, plan: { plan: "pro", chargeAmount: 0, chargeInterval: "month" } },
      { currency: "usd", amount: 100, plan: { plan: "pro", chargeAmount: 1.5, chargeInterval: "month" } },
      { currency: "usd", amount: 100, plan: { plan: "pro", chargeAmount: 100, chargeInterval: "month", chargeUsdCents: -1 } },
      { currency: "usd", amount: 100, plan: { plan: "pro", chargeAmount: 100, chargeInterval: "month", startAt: "not-a-date" } },
    ]) {
      expect(await call(`/admin/users/${customer.id}/billing/payment`, invalid)).toEqual({
        status: 400, body: { ok: false, error: "invalid_input" },
      })
    }
    expect((await call("/admin/users/999999999/billing/payment", { currency: "usd", amount: 100 })).status).toBe(404)
    expect(await call(`/admin/spaces/${stripeSpace.id}/billing/payment`, {
      currency: "usd", amount: 2_000, plan: { plan: "business", seats: 4, chargeAmount: 2_000, chargeInterval: "month" },
    })).toEqual({ status: 409, body: { ok: false, error: "stripe_managed" } })

    const adjustment = await call(`/admin/spaces/${space.id}/billing/wallet`, {
      currency: "usd", amount: -1_000, kind: "adjustment", occurredAt: "2026-09-15T12:00:00.000Z",
    })
    expect(adjustment).toMatchObject({ status: 200, body: { ok: true, entry: { amount: -1_000, occurredAt: "2026-09-15T12:00:00.000Z" } } })
    expect((await call(`/admin/spaces/${space.id}/billing/wallet`, {
      currency: "usd", amount: 100, kind: "adjustment", occurredAt: "yesterday-ish",
    })).body).toEqual({ ok: false, error: "invalid_input" })

    // A yearly plan paid from the space's existing USD credit: one charge now, a third of the next left.
    const teamPlan = await call(`/admin/spaces/${space.id}/billing/credit-plan`, {
      plan: "team", seats: 2, chargeAmount: 3_000, chargeCurrency: "usd", chargeInterval: "year",
      chargeUsdCents: 36_000, note: " yearly from credit ",
    })
    expect(teamPlan).toMatchObject({
      status: 200,
      body: {
        ok: true,
        subscription: {
          spaceId: space.id, plan: "team", seats: 2, funding: "wallet", status: "active", note: "yearly from credit",
          chargeAmount: 3_000, chargeCurrency: "usd", chargeInterval: "year", chargeUsdCents: 36_000,
        },
      },
    })
    const teamPaidThrough = new Date(teamPlan.body.subscription.paidThrough)
    expect(teamPaidThrough.getTime()).toBeGreaterThan(now.getTime() + 364 * day)
    expect(teamPaidThrough.getTime()).toBeLessThan(now.getTime() + 367 * day)

    // Enterprise has no list price, so a plan without a USD value counts as unpriced.
    await call(`/admin/spaces/${enterpriseSpace.id}/billing/wallet`, { currency: "btc", amount: 100_000, kind: "btc_topup" })
    const enterprisePlan = await call(`/admin/spaces/${enterpriseSpace.id}/billing/credit-plan`, {
      plan: "enterprise", seats: 10, chargeAmount: 50_000, chargeCurrency: "btc", chargeInterval: "month",
    })
    expect(enterprisePlan).toMatchObject({
      status: 200, body: { ok: true, subscription: { plan: "enterprise", chargeUsdCents: null } },
    })

    for (const [path, invalid] of [
      [`/admin/spaces/${space.id}/billing/credit-plan`, { plan: "pro", chargeAmount: 100, chargeCurrency: "usd", chargeInterval: "month" }],
      [`/admin/spaces/${space.id}/billing/credit-plan`, { plan: "team", chargeAmount: 0, chargeCurrency: "usd", chargeInterval: "month" }],
      [`/admin/spaces/${space.id}/billing/credit-plan`, { plan: "team", seats: 0, chargeAmount: 100, chargeCurrency: "usd", chargeInterval: "month" }],
      [`/admin/users/${customer.id}/billing/credit-plan`, { plan: "pro", chargeAmount: 100, chargeCurrency: "btc", chargeInterval: "month", startAt: "soon" }],
    ] as const) {
      expect(await call(path, invalid)).toEqual({ status: 400, body: { ok: false, error: "invalid_input" } })
    }
    expect((await call("/admin/spaces/999999999/billing/credit-plan", {
      plan: "team", chargeAmount: 100, chargeCurrency: "usd", chargeInterval: "month",
    })).status).toBe(404)
    expect(await call(`/admin/spaces/${stripeSpace.id}/billing/credit-plan`, {
      plan: "team", chargeAmount: 100, chargeCurrency: "usd", chargeInterval: "month",
    })).toEqual({ status: 409, body: { ok: false, error: "stripe_managed" } })

    await call(`/admin/users/${compUser.id}/billing/plan`, { plan: "pro", funding: "comp", paidThrough: null })

    const overview = await call("/admin/financials")
    expect(overview.status).toBe(200)
    // Stripe team (1 seat) $20 + BTC pro $10 + yearly team $360 / 12; comps and unpriced plans add nothing.
    expect(overview.body.mrr).toEqual({
      mrrUsdCents: 6_000, arrUsdCents: 72_000, stripeUsdCents: 2_000, creditUsdCents: 4_000,
      payingPlans: 3, compPlans: 1, unpricedPlans: 1,
      creditMonthlyByCurrency: { btc: 60_000, usd: 250 },
    })
    expect(overview.body.live).toHaveLength(5)
    let userRunsOut = userPaidThrough
    for (let month = 0; month < 10; month++) userRunsOut = periodEnd(userRunsOut, "month")
    expect(overview.body.live).toContainEqual(expect.objectContaining({
      userId: customer.id, plan: "pro", funding: "wallet", paidThrough: userPaidThrough.toISOString(), isPro: true,
      chargeAmount: 10_000, chargeCurrency: "btc", chargeInterval: "month", chargeUsdCents: 1_000,
      creditBalance: 100_000, creditRunsOutAt: userRunsOut.toISOString(), monthlyUsdCents: 1_000,
      userName: "Fake Customer", username: "fakecustomer", spaceName: null,
    }))
    expect(overview.body.live).toContainEqual(expect.objectContaining({
      spaceId: space.id, plan: "team", isPro: true, creditBalance: 1_000,
      creditRunsOutAt: periodEnd(teamPaidThrough, "year", 1 / 3).toISOString(), monthlyUsdCents: 3_000,
    }))
    expect(overview.body.live).toContainEqual(expect.objectContaining({
      spaceId: enterpriseSpace.id, plan: "enterprise", isPro: true, creditBalance: 50_000, monthlyUsdCents: null,
    }))
    expect(overview.body.live).toContainEqual(expect.objectContaining({
      userId: compUser.id, funding: "comp", isPro: true, creditBalance: null, creditRunsOutAt: null, monthlyUsdCents: 0,
    }))
    expect(overview.body.balances).toHaveLength(3)
    expect(overview.body.balances).toContainEqual({
      userId: customer.id, spaceId: null, currency: "btc", balance: 100_000,
      userName: "Fake Customer", username: "fakecustomer", spaceName: null,
    })
    expect(overview.body.balances).toContainEqual({
      userId: null, spaceId: space.id, currency: "usd", balance: 1_000,
      userName: null, username: null, spaceName: "Fake Payments Space",
    })
    // User: payment and two charges; space: credit, adjustment, charge; enterprise: top-up and charge.
    expect(overview.body.entries).toHaveLength(8)
    expect(overview.body.entries).toContainEqual(expect.objectContaining({
      userId: customer.id, kind: "plan_charge", currency: "btc", amount: -10_000,
      periodStart: startAt.toISOString(), userName: "Fake Customer",
    }))
    expect(overview.body.orders).toEqual([])
    // The rejected Stripe-space payment rolled back with its plan.
    expect(overview.body.receivedOffStripe).toEqual({ btc: 220_000, usd: 5_000 })
  })
})
