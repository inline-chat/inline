import { db } from "@in/server/db"
import { billingOrders, billingSubscriptions, billingWalletEntries, spaces, users } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { and, desc, eq, isNull, sql } from "drizzle-orm"
import { plansBySubject, type BillingPlan } from "./catalog"
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
  /** When the money moved, if not now. */
  readonly occurredAt?: Date | undefined
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
    occurredAt: entry.occurredAt ?? null,
    adminId,
  }).returning()
  return row!
}

export interface RecordPaymentInput {
  readonly currency: "usd" | "btc"
  /** Positive minor units received (cents or sats). Kept in the currency it was paid in; never converted. */
  readonly amount: number
  /** Transaction hash, invoice number or other note. */
  readonly reference?: string | undefined
  readonly occurredAt?: Date | undefined
  /** The plan this payment pays for. The whole amount is charged to it, so the balance nets to zero. */
  readonly plan?: {
    readonly plan: BillingPlan
    readonly seats?: number | undefined
    readonly paidThrough: Date | null
    readonly note?: string | undefined
  } | undefined
}

/**
 * Records an off-Stripe payment (BTC, bank transfer) in one transaction: the credit, and
 * optionally the plan it buys with a matching charge. Amounts stay in their own currency.
 */
export const adminRecordPayment = async (subject: Subject, input: RecordPaymentInput, adminId: number | null) => {
  if ((input.currency !== "usd" && input.currency !== "btc") || !Number.isSafeInteger(input.amount) || input.amount <= 0) {
    throw new BillingAdminError("invalid_input")
  }
  if (input.reference !== undefined && input.reference.length > 500) throw new BillingAdminError("invalid_input")
  const plan = input.plan
  if (plan) validatePlan(subject, { ...plan, funding: "wallet" })
  await requireSubject(subject)

  const pushes: ProPush[] = []
  const result = await db.transaction(async (tx) => {
    const kind = input.currency === "btc" ? "btc_topup" : "admin_topup"
    const [credit] = await tx.insert(billingWalletEntries).values({
      ...subjectColumns(subject),
      currency: input.currency,
      amount: input.amount,
      kind,
      reference: input.reference ?? null,
      occurredAt: input.occurredAt ?? null,
      adminId,
    }).returning()
    if (!plan) return { credit: credit!, subscription: null }

    const subscription = await replaceWithManualPlan(tx, subject, {
      plan: plan.plan, funding: "wallet", paidThrough: plan.paidThrough, seats: plan.seats, note: plan.note,
    })
    await tx.insert(billingWalletEntries).values({
      ...subjectColumns(subject),
      currency: input.currency,
      amount: -input.amount,
      kind: "plan_charge",
      reference: input.reference ?? null,
      occurredAt: input.occurredAt ?? null,
      subscriptionId: subscription.id,
      adminId,
    })
    const push = await refreshProFlag(tx, subject)
    if (push) pushes.push(push)
    return { credit: credit!, subscription }
  })
  await runProPushes(pushes)
  return result
}

export interface ManualPlanInput {
  readonly plan: BillingPlan
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
const validatePlan = (subject: Subject, input: Pick<ManualPlanInput, "plan" | "funding" | "seats">) => {
  const allowed = plansBySubject[subject.spaceId !== undefined ? "space" : "user"]
  if (!allowed.includes(input.plan) || !["comp", "wallet", "prepaid"].includes(input.funding)) throw new BillingAdminError("invalid_input")
  if (input.seats !== undefined && !(Number.isSafeInteger(input.seats) && input.seats >= 1 && input.seats <= 100_000)) throw new BillingAdminError("invalid_input")
}

/** Ends the live manual plan (never a paid Stripe one) and starts the new one. */
const replaceWithManualPlan = async (
  tx: Transaction,
  subject: Subject,
  input: Pick<ManualPlanInput, "plan" | "funding" | "paidThrough" | "seats" | "note">,
) => {
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
  return created!
}

export const adminSetPlan = async (subject: Subject, input: ManualPlanInput, adminId: number | null) => {
  validatePlan(subject, input)
  if (input.walletDebit && !(Number.isSafeInteger(input.walletDebit.amount) && input.walletDebit.amount > 0)) throw new BillingAdminError("invalid_input")
  await requireSubject(subject)

  const pushes: ProPush[] = []
  const subscription = await db.transaction(async (tx) => {
    const created = await replaceWithManualPlan(tx, subject, input)
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

/**
 * Everything for the admin Financials page: live plans, non-zero balances, recent ledger
 * entries and checkouts, with subject names. Admin-only; never exposed to clients.
 */
export const adminFinancialsOverview = async () => {
  const subjectName = (userTable: typeof users, spaceTable: typeof spaces) => ({
    userName: sql<string | null>`nullif(trim(concat_ws(' ', ${userTable.firstName}, ${userTable.lastName})), '')`,
    username: userTable.username,
    spaceName: spaceTable.name,
  })
  const live = await db.select({ subscription: billingSubscriptions, ...subjectName(users, spaces) })
    .from(billingSubscriptions)
    .leftJoin(users, eq(users.id, billingSubscriptions.userId))
    .leftJoin(spaces, eq(spaces.id, billingSubscriptions.spaceId))
    .where(isNull(billingSubscriptions.endedAt))
    .orderBy(desc(billingSubscriptions.updatedAt))
    .limit(500)
  const balances = await db.select({
    userId: billingWalletEntries.userId,
    spaceId: billingWalletEntries.spaceId,
    currency: billingWalletEntries.currency,
    balance: sql<string>`sum(${billingWalletEntries.amount})`,
    ...subjectName(users, spaces),
  }).from(billingWalletEntries)
    .leftJoin(users, eq(users.id, billingWalletEntries.userId))
    .leftJoin(spaces, eq(spaces.id, billingWalletEntries.spaceId))
    .groupBy(billingWalletEntries.userId, billingWalletEntries.spaceId, billingWalletEntries.currency, users.firstName, users.lastName, users.username, spaces.name)
    .having(sql`sum(${billingWalletEntries.amount}) <> 0`)
  const entries = await db.select({ entry: billingWalletEntries, ...subjectName(users, spaces) })
    .from(billingWalletEntries)
    .leftJoin(users, eq(users.id, billingWalletEntries.userId))
    .leftJoin(spaces, eq(spaces.id, billingWalletEntries.spaceId))
    .orderBy(desc(billingWalletEntries.createdAt))
    .limit(200)
  const orders = await db.select({ order: billingOrders, ...subjectName(users, spaces) })
    .from(billingOrders)
    .leftJoin(users, eq(users.id, sql`coalesce(${billingOrders.userId}, ${billingOrders.buyerUserId})`))
    .leftJoin(spaces, eq(spaces.id, billingOrders.spaceId))
    .orderBy(desc(billingOrders.createdAt))
    .limit(100)
  const received = await db.select({
    currency: billingWalletEntries.currency,
    total: sql<string>`sum(${billingWalletEntries.amount})`,
  }).from(billingWalletEntries)
    .where(sql`${billingWalletEntries.amount} > 0 and ${billingWalletEntries.kind} in ('btc_topup', 'admin_topup', 'legacy_import')`)
    .groupBy(billingWalletEntries.currency)
  return {
    live: live.map((row) => ({ ...row.subscription, isPro: grantsAccess(row.subscription), userName: row.userName, username: row.username, spaceName: row.spaceName })),
    balances: balances.map((row) => ({ ...row, balance: Number(row.balance) })),
    entries: entries.map((row) => ({ ...row.entry, userName: row.userName, username: row.username, spaceName: row.spaceName })),
    orders: orders.map((row) => ({ ...row.order, userName: row.userName, username: row.username, spaceName: row.spaceName })),
    receivedOffStripe: Object.fromEntries(received.map((row) => [row.currency, Number(row.total)])),
  }
}
