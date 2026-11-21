import { randomBytes } from "node:crypto"
import { db } from "@in/server/db"
import {
  billingEvents,
  billingOrders,
  billingSubscriptions,
  billingWalletEntries,
  members,
  users,
  type DbBillingOrder,
  type DbBillingSubscription,
} from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { Log } from "@in/server/utils/log"
import { and, desc, eq, gt, inArray, isNull, or, sql } from "drizzle-orm"
import { findPlan, prepaidEnd, type CatalogPlan } from "./catalog"
import {
  checkoutService,
  CheckoutServiceError,
  loadCheckoutConfig,
  type CheckoutConfig,
  type CheckoutSubscriptionInfo,
} from "./checkoutClient"
import {
  endedStripeStatuses,
  expireLapsedSubscriptions,
  grantsAccess,
  liveSubscription,
  refreshProFlag,
  subjectKey,
  subjectOf,
  type Subject,
} from "./entitlements"
import { runProPushes, type ProPush } from "./notify"

const log = new Log("billing")

let cachedConfig: CheckoutConfig | null | undefined
export const checkoutConfig = (): CheckoutConfig | null => {
  if (cachedConfig === undefined) cachedConfig = loadCheckoutConfig()
  return cachedConfig
}
/** Tests only. */
export const setCheckoutConfigForTests = (config: CheckoutConfig | null | undefined) => {
  cachedConfig = config
}

export class BillingError extends Error {
  constructor(readonly code:
    | "billing_unavailable"
    | "unknown_plan"
    | "not_space_admin"
    | "already_subscribed"
    | "no_subscription"
    | "not_payer"
    | "checkout_in_progress"
    | "checkout_failed") {
    super(code)
  }
}

// MARK: - Notifications from the checkout service

/** The JSON body the checkout service signs and forwards for each Stripe event. */
export interface CheckoutNotification {
  readonly id: string
  readonly type: string
  readonly created: number
  readonly livemode: boolean
  readonly appId: string
  readonly orderId: string
  readonly plan: string
  readonly objectId: string
  readonly checkoutSessionId?: string | null
  readonly subscriptionId?: string | null
  readonly paymentIntentId?: string | null
  readonly status?: string | null
  readonly paymentStatus?: string | null
  readonly amountRefunded?: number | null
  /** False for a partial refund. Absent from older service builds, treated as full. */
  readonly fullyRefunded?: boolean | null
}

export const parseNotification = (body: string): CheckoutNotification | null => {
  let value: unknown
  try {
    value = JSON.parse(body)
  } catch {
    return null
  }
  if (!value || typeof value !== "object") return null
  const event = value as Record<string, unknown>
  const isString = (key: string) => typeof event[key] === "string" && (event[key] as string).length > 0
  if (!isString("id") || !isString("type") || !isString("appId") || !isString("orderId") || !isString("plan")) return null
  if (typeof event["livemode"] !== "boolean") return null
  return event as unknown as CheckoutNotification
}

export type NotificationOutcome = "applied" | "duplicate" | "ignored"

const paidStatuses = new Set(["paid", "no_payment_required"])

/**
 * Applies one checkout notification exactly once. Subscription events reconcile against
 * the service's current subscription state, so order of arrival doesn't matter.
 */
export const applyNotification = async (config: CheckoutConfig, event: CheckoutNotification): Promise<NotificationOutcome> => {
  if (event.appId !== config.appId || event.livemode !== config.live) return "ignored"

  // Read current Stripe state before the transaction; never hold a row lock across the network.
  const subscriptionId = event.subscriptionId ?? null
  const remote = subscriptionId ? await checkoutService.getSubscription(config, subscriptionId) : null

  const pushes: ProPush[] = []
  const outcome = await db.transaction(async (tx) => {
    const inserted = await tx.insert(billingEvents)
      .values({ id: event.id, orderId: event.orderId, type: event.type })
      .onConflictDoNothing()
      .returning({ id: billingEvents.id })
    if (inserted.length === 0) return "duplicate" as const

    const [order] = await tx.select().from(billingOrders).where(eq(billingOrders.id, event.orderId)).for("update")
    const plan = findPlan(event.plan)
    if (!order || !plan || order.planCode !== event.plan) {
      log.warn("billing notification for unknown order", { event: event.id, type: event.type })
      return "ignored" as const
    }
    const subject = subjectOf(order)
    const now = new Date()

    switch (event.type) {
      case "checkout.session.completed":
      case "checkout.session.async_payment_succeeded": {
        if (!paidStatuses.has(event.paymentStatus ?? "")) break
        await tx.update(billingOrders).set({
          status: "paid",
          checkoutSessionId: event.checkoutSessionId ?? order.checkoutSessionId,
          stripeSubscriptionId: subscriptionId ?? order.stripeSubscriptionId,
          paymentIntentId: event.paymentIntentId ?? order.paymentIntentId,
          updatedAt: now,
        }).where(eq(billingOrders.id, order.id))
        if (plan.mode === "payment") await grantPrepaid(tx, order, plan, now)
        break
      }
      case "checkout.session.async_payment_failed":
        await tx.update(billingOrders).set({ status: "failed", updatedAt: now }).where(eq(billingOrders.id, order.id))
        break
      case "checkout.session.expired":
        await tx.update(billingOrders).set({ status: "expired", updatedAt: now })
          .where(and(eq(billingOrders.id, order.id), eq(billingOrders.status, "pending")))
        break
      case "charge.refunded":
        // A partial refund (goodwill credit) keeps the plan; a full refund ends it.
        if (event.fullyRefunded === false) break
        await tx.update(billingOrders).set({ status: "refunded", updatedAt: now }).where(eq(billingOrders.id, order.id))
        if (plan.mode === "payment") await revokePrepaid(tx, order, now)
        break
    }

    if (remote) await reconcileStripeSubscription(tx, order, plan, remote, now)
    const push = await refreshProFlag(tx, subject)
    if (push) pushes.push(push)
    return "applied" as const
  })

  await runProPushes(pushes)
  return outcome
}

const grantPrepaid = async (tx: Transaction, order: DbBillingOrder, plan: CatalogPlan, now: Date) => {
  const subject = subjectOf(order)
  const live = await liveSubscription(tx, subject, true)
  if (live) {
    // Extends whatever is live from its current end; an open-ended comp stays open-ended.
    if (live.paidThrough) {
      const from = new Date(Math.max(live.paidThrough.getTime(), now.getTime()))
      await tx.update(billingSubscriptions)
        .set({ paidThrough: prepaidEnd(plan, from), ...(live.funding === "prepaid" ? { plan: plan.plan } : {}), updatedAt: now })
        .where(eq(billingSubscriptions.id, live.id))
    }
    await tx.update(billingOrders).set({ subscriptionId: live.id }).where(eq(billingOrders.id, order.id))
    return
  }
  const [created] = await tx.insert(billingSubscriptions).values({
    userId: order.userId,
    spaceId: order.spaceId,
    plan: plan.plan,
    interval: plan.interval,
    funding: "prepaid",
    status: "active",
    seats: order.quantity,
    paidThrough: prepaidEnd(plan, now),
    payerUserId: order.buyerUserId,
    livemode: order.livemode,
    note: `order ${order.id}`,
  }).returning({ id: billingSubscriptions.id })
  await tx.update(billingOrders).set({ subscriptionId: created!.id }).where(eq(billingOrders.id, order.id))
}

const revokePrepaid = async (tx: Transaction, order: DbBillingOrder, now: Date) => {
  if (!order.subscriptionId) return
  await tx.update(billingSubscriptions).set({ endedAt: now, status: "refunded", updatedAt: now })
    .where(and(
      eq(billingSubscriptions.id, order.subscriptionId),
      eq(billingSubscriptions.funding, "prepaid"),
      isNull(billingSubscriptions.endedAt),
    ))
}

const reconcileStripeSubscription = async (
  tx: Transaction,
  order: DbBillingOrder,
  plan: CatalogPlan,
  remote: CheckoutSubscriptionInfo,
  now: Date,
) => {
  if (remote.orderId && remote.orderId !== order.id) {
    log.warn("billing subscription order mismatch", { subscription: remote.id })
    return
  }
  const subject = subjectOf(order)
  const ended = endedStripeStatuses.has(remote.status)
  const values = {
    status: remote.status,
    seats: remote.quantity ?? order.quantity,
    paidThrough: remote.currentPeriodEnd ? new Date(remote.currentPeriodEnd * 1000) : null,
    cancelAtPeriodEnd: remote.cancelAtPeriodEnd,
    updatedAt: now,
  }

  const [existing] = await tx.select().from(billingSubscriptions)
    .where(eq(billingSubscriptions.stripeSubscriptionId, remote.id)).for("update")

  if (existing) {
    const revive = !ended && existing.endedAt !== null && existing.status !== "replaced"
      && grantsAccess({ ...existing, ...values, endedAt: null })
    if (revive) await endOtherLive(tx, subject, existing.id, now)
    await tx.update(billingSubscriptions).set({
      ...values,
      endedAt: ended ? (existing.endedAt ?? now) : revive ? null : existing.endedAt,
    }).where(eq(billingSubscriptions.id, existing.id))
    await linkOrder(tx, order, existing.id, remote.id)
    return
  }

  if (ended) return
  // Until Stripe reports a paid subscription (for example still incomplete during 3D Secure),
  // keep any live comp or prepaid plan and park this row as ended; it revives once paid.
  const access = grantsAccess({ funding: "stripe", ...values, endedAt: null })
  const otherLive = await liveSubscription(tx, subject, true)
  if (access) await endOtherLive(tx, subject, null, now)
  const [created] = await tx.insert(billingSubscriptions).values({
    userId: order.userId,
    spaceId: order.spaceId,
    plan: plan.plan,
    interval: plan.interval,
    funding: "stripe",
    payerUserId: order.buyerUserId,
    stripeSubscriptionId: remote.id,
    livemode: order.livemode,
    ...values,
    endedAt: !access && otherLive ? now : null,
  }).returning({ id: billingSubscriptions.id })
  await linkOrder(tx, order, created!.id, remote.id)
}

/** A paid Stripe plan replaces a comp or prepaid period; a second Stripe plan is logged for a refund. */
const endOtherLive = async (tx: Transaction, subject: Subject, keepId: number | null, now: Date) => {
  const live = await liveSubscription(tx, subject, true)
  if (!live || live.id === keepId) return
  if (live.funding === "stripe") log.error("billing duplicate stripe subscription", { subject: subjectKey(subject), kept: keepId, replaced: live.id })
  await tx.update(billingSubscriptions).set({ endedAt: now, status: "replaced", updatedAt: now })
    .where(eq(billingSubscriptions.id, live.id))
}

const linkOrder = (tx: Transaction, order: DbBillingOrder, subscriptionId: number, stripeSubscriptionId: string) =>
  tx.update(billingOrders).set({ subscriptionId, stripeSubscriptionId })
    .where(eq(billingOrders.id, order.id))

// MARK: - Checkout

export const isSpaceAdmin = async (userId: number, spaceId: number) => {
  const [member] = await db.select({ role: members.role }).from(members)
    .where(and(eq(members.userId, userId), eq(members.spaceId, spaceId))).limit(1)
  return member?.role === "owner" || member?.role === "admin"
}

/** Billable seats: human members who haven't deleted their account. */
export const countSeats = async (spaceId: number) => {
  const [row] = await db.select({ count: sql<number>`count(*)::int` }).from(members)
    .innerJoin(users, eq(users.id, members.userId))
    .where(and(eq(members.spaceId, spaceId), sql`${users.bot} is not true`, sql`${users.deleted} is not true`))
  return Math.max(1, row?.count ?? 1)
}

export const availablePlans = (config: CheckoutConfig | null = checkoutConfig()) =>
  config ? config.plans.map(findPlan).filter((plan): plan is CatalogPlan => !!plan && (!plan.testOnly || !config.live)) : []

const newOrderId = () => `ord_${randomBytes(12).toString("base64url")}`
const reusableOrderMs = 20 * 60 * 60 * 1000
/** Stripe Checkout sessions stay open for 24 hours. */
const openSessionMs = 24 * 60 * 60 * 1000

export const createCheckout = async (input: { userId: number; planCode: string; spaceId?: number }) => {
  const config = checkoutConfig()
  if (!config) throw new BillingError("billing_unavailable")
  const plan = availablePlans(config).find((candidate) => candidate.code === input.planCode)
  if (!plan) throw new BillingError("unknown_plan")
  if ((plan.subject === "space") !== (input.spaceId !== undefined)) throw new BillingError("unknown_plan")
  if (input.spaceId !== undefined && !(await isSpaceAdmin(input.userId, input.spaceId))) throw new BillingError("not_space_admin")

  const subject: Subject = input.spaceId !== undefined ? { spaceId: input.spaceId } : { userId: input.userId }
  const live = await liveSubscription(db, subject)
  // One live plan per subject: cancel a Stripe subscription before buying anything else.
  if (live?.funding === "stripe" && grantsAccess(live)) throw new BillingError("already_subscribed")

  const quantity = plan.perSeat && input.spaceId !== undefined ? await countSeats(input.spaceId) : 1
  const [buyer] = await db.select({ email: users.email }).from(users).where(eq(users.id, input.userId)).limit(1)

  // One open checkout per subject, so two admins (or monthly then yearly) can't both pay.
  // Repeated taps reuse the identical attempt; the same buyer switching plans closes the old one.
  const pending = await db.select().from(billingOrders).where(and(
    eq(billingOrders.status, "pending"),
    eq(billingOrders.livemode, config.live),
    input.spaceId !== undefined ? eq(billingOrders.spaceId, input.spaceId) : eq(billingOrders.userId, input.userId),
    gt(billingOrders.createdAt, new Date(Date.now() - openSessionMs)),
  )).orderBy(desc(billingOrders.createdAt))
  let recent: DbBillingOrder | undefined
  for (const order of pending) {
    const identical = order.buyerUserId === input.userId && order.planCode === plan.code && order.quantity === quantity
    if (identical && !recent && order.createdAt.getTime() > Date.now() - reusableOrderMs) {
      recent = order
      continue
    }
    if (!order.checkoutSessionId) continue
    if (order.buyerUserId !== input.userId) throw new BillingError("checkout_in_progress")
    const closed = await checkoutService.expireSession(config, order.checkoutSessionId).catch(() => null)
    if (closed?.status !== "expired") throw new BillingError("checkout_in_progress")
    await db.update(billingOrders).set({ status: "expired", updatedAt: new Date() })
      .where(and(eq(billingOrders.id, order.id), eq(billingOrders.status, "pending")))
  }
  if (recent?.checkoutUrl) return { url: recent.checkoutUrl, orderId: recent.id }

  const orderId = recent?.id ?? newOrderId()
  if (!recent) {
    await db.insert(billingOrders).values({
      id: orderId,
      buyerUserId: input.userId,
      userId: input.spaceId === undefined ? input.userId : null,
      spaceId: input.spaceId ?? null,
      planCode: plan.code,
      quantity,
      status: "pending",
      livemode: config.live,
    })
  }

  try {
    const session = await checkoutService.createSession(config, {
      orderId,
      plan: plan.code,
      quantity,
      ...(buyer?.email ? { customerEmail: buyer.email } : {}),
    })
    if (!session.url) throw new CheckoutServiceError(502, "missing_url")
    await db.update(billingOrders).set({ checkoutSessionId: session.id, checkoutUrl: session.url, updatedAt: new Date() })
      .where(eq(billingOrders.id, orderId))
    return { url: session.url, orderId }
  } catch (cause) {
    log.error("billing checkout failed", { order: orderId, code: cause instanceof CheckoutServiceError ? cause.code : "unknown" })
    throw new BillingError("checkout_failed")
  }
}

export const createPortal = async (input: { userId: number; spaceId?: number }) => {
  const config = checkoutConfig()
  if (!config) throw new BillingError("billing_unavailable")
  const subject: Subject = input.spaceId !== undefined ? { spaceId: input.spaceId } : { userId: input.userId }
  const live = await liveSubscription(db, subject)
  if (!live?.stripeSubscriptionId || live.funding !== "stripe") throw new BillingError("no_subscription")
  if (live.payerUserId !== input.userId) throw new BillingError("not_payer")
  const portal = await checkoutService.createPortal(config, live.stripeSubscriptionId)
  return { url: portal.url }
}

// MARK: - Status

export interface SubjectBilling {
  readonly subscription: DbBillingSubscription | null
  readonly isPro: boolean
  /** Balances in minor units; only currencies with entries appear. */
  readonly wallet: { readonly usd?: number; readonly btc?: number }
}

export const walletBalances = async (subject: Subject) => {
  const rows = await db.select({
    currency: billingWalletEntries.currency,
    balance: sql<string>`sum(${billingWalletEntries.amount})`,
  }).from(billingWalletEntries)
    .where(subject.userId !== undefined ? eq(billingWalletEntries.userId, subject.userId) : eq(billingWalletEntries.spaceId, subject.spaceId!))
    .groupBy(billingWalletEntries.currency)
  const wallet: { usd?: number; btc?: number } = {}
  for (const row of rows) {
    if (row.currency === "usd" || row.currency === "btc") wallet[row.currency] = Number(row.balance)
  }
  return wallet
}

export const subjectBilling = async (subject: Subject): Promise<SubjectBilling> => {
  const subscription = await liveSubscription(db, subject)
  return {
    subscription,
    isPro: subscription ? grantsAccess(subscription) : false,
    wallet: await walletBalances(subject),
  }
}

/** Spaces where the user can buy or manage a plan. */
export const manageableSpaceIds = async (userId: number) => {
  const rows = await db.select({ spaceId: members.spaceId }).from(members)
    .where(and(eq(members.userId, userId), or(eq(members.role, "owner"), eq(members.role, "admin"))))
  return rows.map((row) => row.spaceId)
}

// MARK: - Periodic work

/** Ends lapsed periods and refreshes derived flags. Safe to run on any server. */
export const sweepBilling = async () => {
  const pushes: ProPush[] = []
  await db.transaction(async (tx) => {
    for (const subject of await expireLapsedSubscriptions(tx)) {
      const push = await refreshProFlag(tx, subject)
      if (push) pushes.push(push)
    }
  })
  await runProPushes(pushes)
  return pushes.length
}

/** Pushes current human member counts to Stripe for live per-seat space plans. */
export const syncSeats = async () => {
  const config = checkoutConfig()
  if (!config) return 0
  const live = await db.select().from(billingSubscriptions).where(and(
    isNull(billingSubscriptions.endedAt),
    eq(billingSubscriptions.funding, "stripe"),
    eq(billingSubscriptions.livemode, config.live),
    sql`${billingSubscriptions.spaceId} is not null`,
    inArray(billingSubscriptions.status, ["active", "trialing", "past_due"]),
  ))
  let updated = 0
  for (const subscription of live) {
    const seats = await countSeats(subscription.spaceId!)
    if (seats === subscription.seats || !subscription.stripeSubscriptionId) continue
    try {
      const remote = await checkoutService.setSubscriptionQuantity(config, subscription.stripeSubscriptionId, seats)
      await db.update(billingSubscriptions).set({ seats: remote.quantity ?? seats, updatedAt: new Date() })
        .where(eq(billingSubscriptions.id, subscription.id))
      updated += 1
    } catch (cause) {
      log.error("billing seat sync failed", { subscription: subscription.id, code: cause instanceof CheckoutServiceError ? cause.code : "unknown" })
    }
  }
  return updated
}
