import { beforeEach, describe, expect, spyOn, test } from "bun:test"
import { and, eq, isNull } from "drizzle-orm"
import { db } from "../../db"
import { billingEvents, billingOrders, billingSubscriptions, members, spaces, users } from "../../db/schema"
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

describe("billing admin payments", () => {
  setupTestLifecycle()

  test("a BTC payment for a space plan stays in BTC, nets to zero, and shows in the overview", async () => {
    const { adminFinancialsOverview, adminRecordPayment } = await import("../../modules/billing/admin")
    const space = (await testUtils.createSpace("Paying Space"))!
    const paidAt = new Date(Date.UTC(2026, 9, 15))
    const through = new Date(Date.UTC(2027, 1, 28))
    await expect(adminRecordPayment({ spaceId: space.id }, { currency: "btc", amount: 0, plan: undefined }, null)).rejects.toThrow("invalid_input")
    await expect(adminRecordPayment({ spaceId: space.id }, { currency: "btc", amount: 1, plan: { plan: "pro", paidThrough: through } }, null)).rejects.toThrow("invalid_input")

    const { subscription } = await adminRecordPayment({ spaceId: space.id }, {
      currency: "btc", amount: 2_000_000, reference: "tx test", occurredAt: paidAt,
      plan: { plan: "business", seats: 11, paidThrough: through },
    }, null)
    expect(subscription).toMatchObject({ plan: "business", funding: "wallet", seats: 11 })
    const [row] = await db.select().from(spaces).where(eq(spaces.id, space.id))
    expect(row!.isPro).toBe(true)

    const overview = await adminFinancialsOverview()
    const live = overview.live.find((sub) => sub.spaceId === space.id)
    expect(live).toMatchObject({ plan: "business", isPro: true, spaceName: "Paying Space" })
    expect(overview.balances.filter((b) => b.spaceId === space.id)).toEqual([])
    const mine = overview.entries.filter((e) => e.spaceId === space.id)
    expect(mine.map((e) => [e.kind, e.currency, e.amount]).sort()).toEqual([["btc_topup", "btc", 2_000_000], ["plan_charge", "btc", -2_000_000]])
    expect(mine.every((e) => e.occurredAt?.getTime() === paidAt.getTime())).toBe(true)
    expect(overview.receivedOffStripe["btc"]).toBe(2_000_000)
  })
})
