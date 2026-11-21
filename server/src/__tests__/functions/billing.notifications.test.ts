import { beforeEach, describe, expect, spyOn, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "../../db"
import { billingEvents, billingOrders, billingSubscriptions, members, spaces, users } from "../../db/schema"
import { checkoutService, type CheckoutConfig } from "../../modules/billing/checkoutClient"
import { applyNotification, createCheckout, parseNotification, setCheckoutConfigForTests, sweepBilling } from "../../modules/billing/service"
import { setupTestLifecycle, testUtils } from "../setup"

const config: CheckoutConfig = {
  baseUrl: "https://checkout.example", appId: "inline", live: false,
  apiToken: "t".repeat(40), webhookSecret: "s".repeat(40), plans: ["sandbox-test", "team-monthly", "pro-monthly"],
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

    // Replacing keeps one live row.
    await adminSetPlan({ userId: user.id }, { plan: "believer", funding: "prepaid", paidThrough: null }, null)
    detail = await adminBillingDetail({ userId: user.id })
    expect(detail.live).toMatchObject({ plan: "believer", paidThrough: null })
    expect(detail.subscriptions.filter((sub) => sub.endedAt === null)).toHaveLength(1)

    await adminEndPlan({ userId: user.id })
    ;[row] = await db.select().from(users).where(eq(users.id, user.id))
    expect(row!.isPro).toBe(false)
  })
})
