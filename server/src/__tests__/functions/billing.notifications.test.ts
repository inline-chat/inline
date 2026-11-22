import { beforeEach, describe, expect, spyOn, test } from "bun:test"
import { and, eq, isNull } from "drizzle-orm"
import { db } from "../../db"
import { billingEvents, billingOrders, billingSubscriptions, billingWalletEntries, members, spaces, users } from "../../db/schema"
import { checkoutService, type CheckoutConfig } from "../../modules/billing/checkoutClient"
import { applyNotification, createCheckout, parseNotification, setCheckoutConfigForTests, sweepBilling } from "../../modules/billing/service"
import { setupTestLifecycle, testUtils } from "../setup"

const config: CheckoutConfig = {
  baseUrl: "https://checkout.example", appId: "inline", live: false,
  apiToken: "t".repeat(40), webhookSecret: "s".repeat(40), plans: ["sandbox-test", "team-monthly", "team-yearly", "pro-monthly"],
}

const event = (overrides: Record<string, unknown>) => ({
  id: `evt_${Math.random().toString(36).slice(2)}`, created: 1, livemode: false, appId: "inline", objectId: "obj",
  checkoutSessionId: null, subscriptionId: null, paymentIntentId: null, status: null, paymentStatus: null, amountRefunded: null,
  ...overrides,
}) as any

describe("billing notifications", () => {
  setupTestLifecycle()
  let buyer: any
  let space: any

  beforeEach(async () => {
    setCheckoutConfigForTests(config)
    buyer = await testUtils.createUser("billing-buyer@example.com")
    space = await testUtils.createSpace("Billing Space")
    await db.insert(members).values({ userId: buyer.id, spaceId: space.id, role: "owner" })
  })

  const startCheckout = async (plan: string, spaceId?: number) => {
    const create = spyOn(checkoutService, "createSession").mockImplementation(async (_c, input) => ({
      id: `cs_test_${input.orderId}`, url: `https://checkout.stripe.com/${input.orderId}`, status: "open", paymentStatus: "unpaid",
      subscriptionId: null, paymentIntentId: null, orderId: input.orderId, plan: input.plan,
    }))
    const result = await createCheckout({ userId: buyer.id, planCode: plan, ...(spaceId ? { spaceId } : {}) })
    const input = create.mock.calls[0]?.[1]
    create.mockRestore()
    return { ...result, input }
  }

  test("a signed one-time payment grants the right space once, and a replay is a no-op", async () => {
    const { orderId, url, input } = await startCheckout("sandbox-test", space.id) as any
    expect(url).toContain(orderId)
    expect(input).toMatchObject({ plan: "sandbox-test", quantity: 1, customerEmail: "billing-buyer@example.com" })

    const other = (await testUtils.createSpace("Other Space"))!
    const paid = event({ id: "evt_paid", type: "checkout.session.completed", orderId, plan: "sandbox-test", checkoutSessionId: `cs_test_${orderId}`, paymentStatus: "paid" })
    expect(await applyNotification(config, paid)).toBe("applied")
    expect(await applyNotification(config, paid)).toBe("duplicate")

    const [granted] = await db.select().from(spaces).where(eq(spaces.id, space.id))
    const [untouched] = await db.select().from(spaces).where(eq(spaces.id, other.id))
    expect(granted!.isPro).toBe(true)
    expect(untouched!.isPro).toBe(false)
    const subs = await db.select().from(billingSubscriptions).where(eq(billingSubscriptions.spaceId, space.id))
    expect(subs).toHaveLength(1)
    expect(subs[0]).toMatchObject({ funding: "prepaid", plan: "team", endedAt: null })
    const days = (subs[0]!.paidThrough!.getTime() - Date.now()) / 86_400_000
    expect(days).toBeGreaterThan(29.9)
    expect(days).toBeLessThan(30.1)
    expect((await db.select().from(billingEvents)).map((row) => row.id)).toEqual(["evt_paid"])

    const refund = event({ type: "charge.refunded", orderId, plan: "sandbox-test", amountRefunded: 100 })
    expect(await applyNotification(config, refund)).toBe("applied")
    const [revoked] = await db.select().from(spaces).where(eq(spaces.id, space.id))
    expect(revoked!.isPro).toBe(false)
  })

  test("wrong app, wrong mode and unknown orders change nothing", async () => {
    const { orderId } = await startCheckout("sandbox-test", space.id)
    const paid = { type: "checkout.session.completed", orderId, plan: "sandbox-test", paymentStatus: "paid" }
    expect(await applyNotification(config, event({ ...paid, appId: "noor" }))).toBe("ignored")
    expect(await applyNotification(config, event({ ...paid, livemode: true }))).toBe("ignored")
    expect(await applyNotification(config, event({ ...paid, orderId: "ord_missing" }))).toBe("ignored")
    expect(await applyNotification(config, event({ ...paid, paymentStatus: "unpaid" }))).toBe("applied")
    const [row] = await db.select().from(spaces).where(eq(spaces.id, space.id))
    expect(row!.isPro).toBe(false)
  })

  test("repeated checkout taps reuse the pending order", async () => {
    const first = await startCheckout("sandbox-test", space.id)
    const second = await startCheckout("sandbox-test", space.id)
    expect(second.orderId).toBe(first.orderId)
    expect(second.input).toBeUndefined()
    expect(await db.select().from(billingOrders)).toHaveLength(1)
  })

  test("non-admins can't buy for a space", async () => {
    const stranger = await testUtils.createUser("billing-stranger@example.com")
    await db.insert(members).values({ userId: stranger.id, spaceId: space.id, role: "member" })
    await expect(createCheckout({ userId: stranger.id, planCode: "team-monthly", spaceId: space.id })).rejects.toThrow("not_space_admin")
    await expect(createCheckout({ userId: buyer.id, planCode: "team-monthly" })).rejects.toThrow("unknown_plan")
  })

  test("subscription events reconcile current Stripe state regardless of order", async () => {
    const { orderId, input } = await startCheckout("team-monthly", space.id) as any
    expect(input.quantity).toBe(1)
    const periodEnd = Math.floor(Date.now() / 1000) + 30 * 86_400
    let remote = { id: "sub_1", status: "active", cancelAtPeriodEnd: false, currentPeriodEnd: periodEnd, quantity: 1, orderId, plan: "team-monthly" }
    const get = spyOn(checkoutService, "getSubscription").mockImplementation(async () => remote)

    // An update can arrive before checkout.session.completed.
    await applyNotification(config, event({ type: "customer.subscription.updated", orderId, plan: "team-monthly", subscriptionId: "sub_1" }))
    await applyNotification(config, event({ type: "checkout.session.completed", orderId, plan: "team-monthly", subscriptionId: "sub_1", paymentStatus: "paid" }))
    let [row] = await db.select().from(spaces).where(eq(spaces.id, space.id))
    expect(row!.isPro).toBe(true)
    const [sub] = await db.select().from(billingSubscriptions).where(eq(billingSubscriptions.stripeSubscriptionId, "sub_1"))
    expect(sub).toMatchObject({ funding: "stripe", status: "active", payerUserId: buyer.id })
    expect(sub!.paidThrough!.getTime()).toBe(periodEnd * 1000)
    await expect(createCheckout({ userId: buyer.id, planCode: "team-monthly", spaceId: space.id })).rejects.toThrow("already_subscribed")

    remote = { ...remote, status: "canceled" }
    await applyNotification(config, event({ type: "customer.subscription.deleted", orderId, plan: "team-monthly", subscriptionId: "sub_1" }))
    ;[row] = await db.select().from(spaces).where(eq(spaces.id, space.id))
    expect(row!.isPro).toBe(false)
    get.mockRestore()
  })

  test("an unpaid Stripe subscription doesn't end a comp until Stripe reports it paid", async () => {
    await db.insert(billingSubscriptions).values({ spaceId: space.id, plan: "team", interval: "none", funding: "comp", status: "active" })
    await db.update(spaces).set({ isPro: true }).where(eq(spaces.id, space.id))
    const { orderId } = await startCheckout("team-monthly", space.id) as any
    const periodEnd = Math.floor(Date.now() / 1000) + 30 * 86_400
    let remote = { id: "sub_3ds", status: "incomplete", cancelAtPeriodEnd: false, currentPeriodEnd: periodEnd, quantity: 1, orderId, plan: "team-monthly" }
    const get = spyOn(checkoutService, "getSubscription").mockImplementation(async () => remote)

    await applyNotification(config, event({ type: "customer.subscription.created", orderId, plan: "team-monthly", subscriptionId: "sub_3ds" }))
    let live = await db.select().from(billingSubscriptions).where(and(eq(billingSubscriptions.spaceId, space.id), isNull(billingSubscriptions.endedAt)))
    expect(live.map((row) => row.funding)).toEqual(["comp"])
    let [row] = await db.select().from(spaces).where(eq(spaces.id, space.id))
    expect(row!.isPro).toBe(true)

    remote = { ...remote, status: "active" }
    await applyNotification(config, event({ type: "customer.subscription.updated", orderId, plan: "team-monthly", subscriptionId: "sub_3ds" }))
    live = await db.select().from(billingSubscriptions).where(and(eq(billingSubscriptions.spaceId, space.id), isNull(billingSubscriptions.endedAt)))
    expect(live.map((sub) => sub.funding)).toEqual(["stripe"])
    ;[row] = await db.select().from(spaces).where(eq(spaces.id, space.id))
    expect(row!.isPro).toBe(true)
    get.mockRestore()
  })

  test("one open checkout per space: another admin is refused, the same buyer switching plans closes the old one", async () => {
    const first = await startCheckout("team-monthly", space.id)
    const admin = await testUtils.createUser("billing-second-admin@example.com")
    await db.insert(members).values({ userId: admin.id, spaceId: space.id, role: "admin" })
    await expect(createCheckout({ userId: admin.id, planCode: "team-yearly", spaceId: space.id })).rejects.toThrow("checkout_in_progress")

    const expire = spyOn(checkoutService, "expireSession").mockImplementation(async (_c, id) => ({
      id, url: null, status: "expired", paymentStatus: "unpaid", subscriptionId: null, paymentIntentId: null,
    }))
    const second = await startCheckout("team-yearly", space.id)
    expect(expire.mock.calls.map((call) => call[1])).toEqual([`cs_test_${first.orderId}`])
    expect(second.orderId).not.toBe(first.orderId)
    const [old] = await db.select().from(billingOrders).where(eq(billingOrders.id, first.orderId))
    expect(old!.status).toBe("expired")
    expire.mockRestore()
  })

  test("a partial refund keeps a one-time plan", async () => {
    const { orderId } = await startCheckout("sandbox-test", space.id)
    await applyNotification(config, event({ type: "checkout.session.completed", orderId, plan: "sandbox-test", paymentStatus: "paid" }))
    await applyNotification(config, event({ type: "charge.refunded", orderId, plan: "sandbox-test", amountRefunded: 500, fullyRefunded: false }))
    const [row] = await db.select().from(spaces).where(eq(spaces.id, space.id))
    expect(row!.isPro).toBe(true)
    const [order] = await db.select().from(billingOrders).where(eq(billingOrders.id, orderId))
    expect(order!.status).toBe("paid")
  })

  test("a lapsed prepaid period expires in the sweep", async () => {
    await db.insert(billingSubscriptions).values({ userId: buyer.id, plan: "pro", interval: "none", funding: "comp", status: "active", paidThrough: new Date(Date.now() - 1000) })
    await db.update(users).set({ isPro: true }).where(eq(users.id, buyer.id))
    expect(await sweepBilling()).toBe(1)
    const [row] = await db.select().from(users).where(eq(users.id, buyer.id))
    expect(row!.isPro).toBe(false)
  })

  test("parseNotification rejects malformed bodies", () => {
    expect(parseNotification("nope")).toBeNull()
    expect(parseNotification(JSON.stringify({ id: "evt", type: "x", appId: "inline", orderId: "o", plan: "p" }))).toBeNull()
    expect(parseNotification(JSON.stringify({ id: "evt", type: "x", appId: "inline", orderId: "o", plan: "p", livemode: false }))).not.toBeNull()
  })
})

describe("billing admin", () => {
  setupTestLifecycle()

  test("manual plans, wallet credit and debits", async () => {
    const { adminAddWalletEntry, adminBillingDetail, adminEndPlan, adminSetPlan } = await import("../../modules/billing/admin")
    const user = await testUtils.createUser("billing-admin@example.com")
    await adminAddWalletEntry({ userId: user.id }, { currency: "btc", amount: 250_000, kind: "legacy_import", reference: "spreadsheet" }, null)
    await adminAddWalletEntry({ userId: user.id }, { currency: "usd", amount: 10_000, kind: "btc_topup", reference: "tx abc" }, null)
    await expect(adminSetPlan({ userId: user.id }, { plan: "team", funding: "comp", paidThrough: null }, null)).rejects.toThrow("invalid_input")

    const year = new Date(Date.now() + 365 * 86_400_000)
    await adminSetPlan({ userId: user.id }, { plan: "pro", funding: "wallet", paidThrough: year, walletDebit: { currency: "usd", amount: 10_000 } }, null)
    let detail = await adminBillingDetail({ userId: user.id })
    expect(detail.isPro).toBe(true)
    expect(detail.wallet).toEqual({ usd: 0, btc: 250_000 })
    let [row] = await db.select().from(users).where(eq(users.id, user.id))
    expect(row!.isPro).toBe(true)
    expect(row!.badge).toBe("pro")

    // Replacing keeps one live row.
    await adminSetPlan({ userId: user.id }, { plan: "believer", funding: "prepaid", paidThrough: null }, null)
    detail = await adminBillingDetail({ userId: user.id })
    expect(detail.live).toMatchObject({ plan: "believer", paidThrough: null })
    expect(detail.subscriptions.filter((sub) => sub.endedAt === null)).toHaveLength(1)
    ;[row] = await db.select().from(users).where(eq(users.id, user.id))
    expect(row!.badge).toBe("believer")

    await adminEndPlan({ userId: user.id })
    ;[row] = await db.select().from(users).where(eq(users.id, user.id))
    expect(row!.isPro).toBe(false)
    expect(row!.badge).toBeNull()
  })
})

describe("billing credit plans", () => {
  setupTestLifecycle()

  const day = (y: number, m: number, d: number) => new Date(Date.UTC(y, m - 1, d))

  test("periods add whole months in UTC and clamp to month end", async () => {
    const { periodEnd } = await import("../../modules/billing/credit")
    expect(periodEnd(day(2026, 11, 1), "month").toISOString()).toBe("2026-12-01T00:00:00.000Z")
    expect(periodEnd(day(2027, 1, 31), "month").toISOString()).toBe("2027-02-28T00:00:00.000Z")
    expect(periodEnd(day(2026, 11, 1), "year").toISOString()).toBe("2027-11-01T00:00:00.000Z")
    const half = periodEnd(day(2026, 11, 1), "month", 0.5)
    expect(half.toISOString()).toBe("2026-11-16T00:00:00.000Z")
  })

  test("BTC credit is kept as a balance and each month draws its USD price at that month's rate", async () => {
    const { adminRecordPayment, adminFinancialsOverview } = await import("../../modules/billing/admin")
    const { setBtcUsdForTests } = await import("../../modules/billing/btcPrice")
    const space = (await testUtils.createSpace("Credit Space"))!
    const subject = { spaceId: space.id }
    const entries = async () => db.select().from(billingWalletEntries).where(eq(billingWalletEntries.spaceId, space.id))
    const charges = async () => (await entries()).filter((e) => e.kind === "plan_charge").sort((a, b) => a.periodStart!.getTime() - b.periodStart!.getTime())
    const balance = async () => (await entries()).reduce((total, e) => total + e.amount, 0)
    const live = async () => (await db.select().from(billingSubscriptions)
      .where(and(eq(billingSubscriptions.spaceId, space.id), isNull(billingSubscriptions.endedAt))))[0]

    // BTC falls month by month; the current price is $60k.
    const byMonth: Record<string, number> = { "2026-11": 75_000, "2026-12": 70_000, "2027-01": 60_000, "2027-02": 50_000 }
    setBtcUsdForTests((date) => (date ? byMonth[date.toISOString().slice(0, 7)] ?? null : 60_000))
    try {
      // 0.02 BTC paid Nov 1; Business for 11 seats at $330 a month, priced in USD.
      await adminRecordPayment(subject, {
        currency: "btc", amount: 2_000_000, reference: "fake-tx", occurredAt: day(2026, 11, 1), usdCents: 150_000,
        plan: { plan: "business", seats: 11, chargeInterval: "month", chargeUsdCents: 33_000, startAt: day(2026, 11, 1) },
      }, null)
      let sub = await live()
      expect(sub).toMatchObject({ plan: "business", funding: "wallet", seats: 11, chargeAmount: null, chargeCurrency: "btc", chargeUsdCents: 33_000 })
      const first = (await charges())[0]!
      expect(first.amount).toBe(-440_000) // $330 at $75k on Nov 1
      expect(first.usdCents).toBe(-33_000)
      expect(first.periodStart!.toISOString()).toBe("2026-11-01T00:00:00.000Z")
      expect(await balance()).toBe(2_000_000 - (await charges()).reduce((t, c) => t - c.amount, 0))

      // Catch up to mid-February: Dec at $70k, Jan at $60k, then Feb at $50k only partly covered.
      await sweepBilling(day(2027, 2, 10))
      const all = await charges()
      expect(all.map((c) => -c.amount)).toEqual([440_000, 471_429, 550_000, 538_571])
      expect(all.at(-1)!.usdCents).toBe(-Math.round(33_000 * (538_571 / 660_000)))
      expect(await balance()).toBe(0)
      sub = await live()
      expect(sub!.paidThrough!.toISOString().slice(0, 10)).toBe("2027-02-23")
      let [row] = await db.select().from(spaces).where(eq(spaces.id, space.id))
      expect(row!.isPro).toBe(true)

      // Re-running never double-charges; once the paid period passes with no credit, the plan lapses.
      await sweepBilling(day(2027, 2, 10))
      expect(await charges()).toHaveLength(4)
      await sweepBilling(day(2027, 2, 25))
      ;[row] = await db.select().from(spaces).where(eq(spaces.id, space.id))
      expect(row!.isPro).toBe(false)
      expect((await adminFinancialsOverview()).live.find((l) => l.spaceId === space.id)).toBeUndefined()
    } finally {
      setBtcUsdForTests(null)
    }
  })

  test("without a BTC rate, a USD-priced period waits instead of charging", async () => {
    const { adminAddWalletEntry, adminStartCreditPlan } = await import("../../modules/billing/admin")
    const { setBtcUsdForTests } = await import("../../modules/billing/btcPrice")
    const space = (await testUtils.createSpace("No Rate Space"))!
    await adminAddWalletEntry({ spaceId: space.id }, { currency: "btc", amount: 1_000_000, kind: "btc_topup", reference: "fake" }, null)
    setBtcUsdForTests(() => null)
    try {
      // Starting needs the first period's rate.
      await expect(adminStartCreditPlan({ spaceId: space.id }, { plan: "team", seats: 2, chargeCurrency: "btc", chargeInterval: "month" }, null))
        .rejects.toThrow("rate_unavailable")
      setBtcUsdForTests(() => 50_000)
      const sub = await adminStartCreditPlan({ spaceId: space.id }, { plan: "team", seats: 2, chargeCurrency: "btc", chargeInterval: "month" }, null)
      expect(sub.chargeUsdCents).toBe(4_000)
      const firstEnd = sub.paidThrough!.getTime()
      // A renewal with no rate waits: paid-through stays, nothing is charged.
      setBtcUsdForTests(() => null)
      await sweepBilling(new Date(firstEnd - 60_000))
      const [live] = await db.select().from(billingSubscriptions).where(eq(billingSubscriptions.id, sub.id))
      expect(live!.paidThrough!.getTime()).toBe(firstEnd)
      const after = await db.select().from(billingWalletEntries).where(eq(billingWalletEntries.spaceId, space.id))
      expect(after.filter((e) => e.kind === "plan_charge").map((e) => e.amount)).toEqual([-80_000])
    } finally {
      setBtcUsdForTests(null)
    }
  })

  test("a top-up lets a live credit plan keep renewing, and MRR counts Stripe and credit plans", async () => {
    const { adminAddWalletEntry, adminFinancialsOverview, adminRecordPayment, adminStartCreditPlan } = await import("../../modules/billing/admin")
    const { sweepBilling } = await import("../../modules/billing/service")
    const space = (await testUtils.createSpace("Top-up Space"))!
    const now = new Date()
    await adminAddWalletEntry({ spaceId: space.id }, { currency: "usd", amount: 6_000, kind: "admin_topup", reference: "fake" }, null)
    const sub = await adminStartCreditPlan({ spaceId: space.id }, {
      plan: "team", seats: 3, chargeAmount: 6_000, chargeCurrency: "usd", chargeInterval: "month",
    }, null, now)
    expect(sub.chargeUsdCents).toBe(6_000) // list price: 3 seats x $20
    await expect(adminStartCreditPlan({ spaceId: space.id }, {
      plan: "team", seats: 3, chargeAmount: 6_000, chargeCurrency: "usd", chargeInterval: "month", startAt: new Date(Date.now() + 86_400_000),
    }, null)).rejects.toThrow("invalid_input")
    const firstEnd = sub.paidThrough!.getTime()
    // No credit left: the next sweep near period end can't renew.
    await sweepBilling(new Date(firstEnd - 60_000))
    let [live] = await db.select().from(billingSubscriptions).where(eq(billingSubscriptions.id, sub.id))
    expect(live!.paidThrough!.getTime()).toBe(firstEnd)
    // A payment without a plan tops up and the live plan catches up when due.
    await adminRecordPayment({ spaceId: space.id }, { currency: "usd", amount: 6_000, reference: "fake" }, null)
    await sweepBilling(new Date(firstEnd - 60_000))
    ;[live] = await db.select().from(billingSubscriptions).where(eq(billingSubscriptions.id, sub.id))
    expect(live!.paidThrough!.getTime()).toBeGreaterThan(firstEnd)

    // A Stripe Team plan: 4 seats x $20.
    const stripeSpace = (await testUtils.createSpace("Stripe Space"))!
    await db.insert(billingSubscriptions).values({ spaceId: stripeSpace.id, plan: "team", interval: "month", funding: "stripe", status: "active", seats: 4, paidThrough: new Date(Date.now() + 20 * 86_400_000) })
    const overview = await adminFinancialsOverview()
    const ours = overview.live.filter((l) => l.spaceId === space.id || l.spaceId === stripeSpace.id)
    expect(ours.map((l) => l.monthlyUsdCents).sort()).toEqual([6_000, 8_000])
    expect(overview.mrr.mrrUsdCents).toBeGreaterThanOrEqual(14_000)
    expect(overview.mrr.arrUsdCents).toBe(overview.mrr.mrrUsdCents * 12)
    expect(overview.live.find((l) => l.spaceId === space.id)?.creditBalance).toBe(0)
  })
})
