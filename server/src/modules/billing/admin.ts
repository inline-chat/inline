import { db } from "@in/server/db"
import { billingOrders, billingSubscriptions, billingWalletEntries, spaces, users } from "@in/server/db/schema"
import { and, desc, eq, isNull } from "drizzle-orm"
import { grantsAccess, liveSubscription, refreshProFlag, type Subject } from "./entitlements"
import { runProPushes, type ProPush } from "./notify"
import { walletBalances } from "./service"

export class BillingAdminError extends Error {
  constructor(readonly code: "not_found" | "invalid_input" | "stripe_managed") {
    super(code)
  }
}

const subjectColumns = (subject: Subject) =>
  subject.userId !== undefined ? { userId: subject.userId, spaceId: null } : { userId: null, spaceId: subject.spaceId }

const requireSubject = async (subject: Subject) => {
  const [row] = subject.userId !== undefined
    ? await db.select({ id: users.id }).from(users).where(eq(users.id, subject.userId)).limit(1)
    : await db.select({ id: spaces.id }).from(spaces).where(eq(spaces.id, subject.spaceId!)).limit(1)
  if (!row) throw new BillingAdminError("not_found")
}

/** Everything an operator needs on one screen: live plan, history, wallet and checkouts. */
export const adminBillingDetail = async (subject: Subject) => {
  await requireSubject(subject)
  const filter = (table: typeof billingSubscriptions | typeof billingWalletEntries | typeof billingOrders) =>
    subject.userId !== undefined ? eq(table.userId, subject.userId) : eq(table.spaceId, subject.spaceId!)
  const live = await liveSubscription(db, subject)
  return {
    isPro: live ? grantsAccess(live) : false,
    live,
    subscriptions: await db.select().from(billingSubscriptions).where(filter(billingSubscriptions))
      .orderBy(desc(billingSubscriptions.createdAt)).limit(50),
    wallet: await walletBalances(subject),
    walletEntries: await db.select().from(billingWalletEntries).where(filter(billingWalletEntries))
      .orderBy(desc(billingWalletEntries.createdAt)).limit(200),
    orders: await db.select().from(billingOrders).where(filter(billingOrders))
      .orderBy(desc(billingOrders.createdAt)).limit(50),
  }
}

export interface WalletEntryInput {
  readonly currency: "usd" | "btc"
  /** Minor units (cents or sats). Positive credits, negative debits. */
  readonly amount: number
  readonly kind: "legacy_import" | "btc_topup" | "admin_topup" | "plan_charge" | "refund" | "adjustment"
  readonly reference?: string | undefined
}

const validEntry = (entry: WalletEntryInput) =>
  (entry.currency === "usd" || entry.currency === "btc")
  && Number.isSafeInteger(entry.amount) && entry.amount !== 0
  && (entry.reference === undefined || entry.reference.length <= 500)

/** Appends a manual wallet entry (BTC top-up, legacy credit, correction). */
export const adminAddWalletEntry = async (subject: Subject, entry: WalletEntryInput, adminId: number | null) => {
  if (!validEntry(entry)) throw new BillingAdminError("invalid_input")
  await requireSubject(subject)
  const [row] = await db.insert(billingWalletEntries).values({
    ...subjectColumns(subject),
    currency: entry.currency,
    amount: entry.amount,
    kind: entry.kind,
    reference: entry.reference ?? null,
    adminId,
  }).returning()
  return row!
}

export interface ManualPlanInput {
  /** pro | believer | team | enterprise */
  readonly plan: "pro" | "believer" | "team" | "enterprise"
  /** comp: free or arranged outside Inline. wallet: paid from wallet credit. prepaid: paid another way. */
  readonly funding: "comp" | "wallet" | "prepaid"
  /** Null keeps it open-ended. */
  readonly paidThrough: Date | null
  readonly seats?: number | undefined
  readonly note?: string | undefined
  /** Optional wallet debit recorded with the plan, for example $100 of BTC credit for a year. */
  readonly walletDebit?: { readonly currency: "usd" | "btc"; readonly amount: number } | undefined
}

/**
 * Sets a manual plan, replacing any live comp/prepaid/wallet plan. Refuses to touch a
 * live Stripe subscription; that changes only through Stripe.
 */
export const adminSetPlan = async (subject: Subject, input: ManualPlanInput, adminId: number | null) => {
  const plans = ["pro", "believer", "team", "enterprise"]
  if (!plans.includes(input.plan) || !["comp", "wallet", "prepaid"].includes(input.funding)) throw new BillingAdminError("invalid_input")
  if ((input.plan === "team" || input.plan === "enterprise") !== (subject.spaceId !== undefined)) throw new BillingAdminError("invalid_input")
  if (input.walletDebit && !(Number.isSafeInteger(input.walletDebit.amount) && input.walletDebit.amount > 0)) throw new BillingAdminError("invalid_input")
  if (input.seats !== undefined && !(Number.isSafeInteger(input.seats) && input.seats >= 1 && input.seats <= 100_000)) throw new BillingAdminError("invalid_input")
  await requireSubject(subject)

  const pushes: ProPush[] = []
  const subscription = await db.transaction(async (tx) => {
    const now = new Date()
    const live = await liveSubscription(tx, subject, true)
    if (live?.funding === "stripe" && grantsAccess(live)) throw new BillingAdminError("stripe_managed")
    if (live) {
      await tx.update(billingSubscriptions).set({ endedAt: now, status: "replaced", updatedAt: now })
        .where(eq(billingSubscriptions.id, live.id))
    }
    const [created] = await tx.insert(billingSubscriptions).values({
      ...subjectColumns(subject),
      plan: input.plan,
      interval: "none",
      funding: input.funding,
      status: "active",
      seats: input.seats ?? 1,
      paidThrough: input.paidThrough,
      note: input.note ?? null,
    }).returning()
    if (input.walletDebit) {
      await tx.insert(billingWalletEntries).values({
        ...subjectColumns(subject),
        currency: input.walletDebit.currency,
        amount: -input.walletDebit.amount,
        kind: "plan_charge",
        reference: input.note ?? `plan ${input.plan}`,
        subscriptionId: created!.id,
        adminId,
      })
    }
    const push = await refreshProFlag(tx, subject)
    if (push) pushes.push(push)
    return created!
  })
  await runProPushes(pushes)
  return subscription
}

/** Ends a live manual plan now. Stripe plans end through Stripe. */
export const adminEndPlan = async (subject: Subject) => {
  await requireSubject(subject)
  const pushes: ProPush[] = []
  const ended = await db.transaction(async (tx) => {
    const live = await liveSubscription(tx, subject, true)
    if (!live) return null
    if (live.funding === "stripe" && grantsAccess(live)) throw new BillingAdminError("stripe_managed")
    const now = new Date()
    const [row] = await tx.update(billingSubscriptions).set({ endedAt: now, status: "canceled", updatedAt: now })
      .where(and(eq(billingSubscriptions.id, live.id), isNull(billingSubscriptions.endedAt))).returning()
    const push = await refreshProFlag(tx, subject)
    if (push) pushes.push(push)
    return row ?? null
  })
  await runProPushes(pushes)
  return ended
}
