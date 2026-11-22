import { db } from "@in/server/db"
import { billingOrders, billingSubscriptions, billingWalletEntries, spaces, users, type DbBillingSubscription } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { and, desc, eq, isNull, sql } from "drizzle-orm"
import { listMonthlyUsdCents, listPeriodUsdCents, plansBySubject, type BillingPlan } from "./catalog"
import { btcUsdSpot } from "./btcPrice"
import { creditBalance, creditRunsOutAt, prefetchRates, renewCreditPlan, satsForUsdCents, type RateFor } from "./credit"
import { grantsAccess, liveSubscription, refreshProFlag, subjectOf, type Subject } from "./entitlements"
import { runProPushes, type ProPush } from "./notify"
import { walletBalances } from "./service"

export class BillingAdminError extends Error {
  constructor(readonly code: "not_found" | "invalid_input" | "stripe_managed" | "rate_unavailable") {
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
  /** USD value at the time, for reporting (for BTC: what it was worth that day). */
  readonly usdCents?: number | undefined
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
    usdCents: entry.usdCents ?? null,
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
  /** USD value of the payment when it was made (reporting only; never converts the credit). */
  readonly usdCents?: number | undefined
  /**
   * Optionally start a plan paid from this credit, drawn down per period in the payment's
   * currency. Without it, the credit tops up the balance and any live credit plan keeps renewing.
   */
  readonly plan?: Omit<CreditPlanInput, "chargeCurrency"> | undefined
}

export interface CreditPlanInput {
  readonly plan: BillingPlan
  readonly seats?: number | undefined
  /**
   * Optional fixed amount each period draws, in minor units of `chargeCurrency`. Usually left
   * out: the period is priced in USD (`chargeUsdCents`) and BTC credit is drawn at that period's rate.
   */
  readonly chargeAmount?: number | undefined
  readonly chargeCurrency: "usd" | "btc"
  readonly chargeInterval: "month" | "year"
  /** Price of one period in USD cents; defaults to the catalog list price when one exists. Counts toward MRR. */
  readonly chargeUsdCents?: number | undefined
  /** First period starts here (default now). A past date charges the periods since then. */
  readonly startAt?: Date | undefined
  readonly note?: string | undefined
}

const validateCreditPlan = (subject: Subject, input: CreditPlanInput) => {
  validatePlan(subject, { plan: input.plan, funding: "wallet", seats: input.seats })
  if (input.chargeAmount !== undefined && (!Number.isSafeInteger(input.chargeAmount) || input.chargeAmount <= 0)) throw new BillingAdminError("invalid_input")
  const price = input.chargeUsdCents ?? listPeriodUsdCents(input.plan, input.chargeInterval, input.seats ?? 1)
  if (input.chargeAmount === undefined && !(price !== null && price > 0)) throw new BillingAdminError("invalid_input")
  if (input.chargeCurrency !== "usd" && input.chargeCurrency !== "btc") throw new BillingAdminError("invalid_input")
  if (input.chargeInterval !== "month" && input.chargeInterval !== "year") throw new BillingAdminError("invalid_input")
  if (input.chargeUsdCents !== undefined && !(Number.isSafeInteger(input.chargeUsdCents) && input.chargeUsdCents >= 0)) throw new BillingAdminError("invalid_input")
  // A future start would grant access until then without charging anything.
  if (input.startAt !== undefined && input.startAt.getTime() > Date.now() + 60_000) throw new BillingAdminError("invalid_input")
}

/**
 * A BTC plan priced in USD needs the first period's rate to start: otherwise it would start
 * unpaid and could lapse before a rate arrives. Admins retry when the price sources are back.
 */
const requireFirstRate = (input: CreditPlanInput, rateFor: RateFor, now: Date) => {
  if (input.chargeCurrency === "btc" && input.chargeAmount === undefined && rateFor(input.startAt ?? now) === null) {
    throw new BillingAdminError("rate_unavailable")
  }
}

/** Starts a credit plan inside the caller's transaction and charges any periods already due. */
const startCreditPlan = async (tx: Transaction, subject: Subject, input: CreditPlanInput, now: Date, rateFor: RateFor) => {
  const startAt = input.startAt ?? now
  const created = await replaceWithManualPlan(tx, subject, {
    plan: input.plan, funding: "wallet", paidThrough: startAt, seats: input.seats, note: input.note,
  })
  // Default the reporting value to the list price for that exact period (yearly plans have their own price).
  const usdPerCharge = input.chargeUsdCents ?? listPeriodUsdCents(input.plan, input.chargeInterval, input.seats ?? 1)
  await tx.update(billingSubscriptions).set({
    chargeAmount: input.chargeAmount ?? null,
    chargeCurrency: input.chargeCurrency,
    chargeInterval: input.chargeInterval,
    chargeUsdCents: usdPerCharge,
  }).where(eq(billingSubscriptions.id, created.id))
  await renewCreditPlan(tx, created.id, now, rateFor)
  const [subscription] = await tx.select().from(billingSubscriptions).where(eq(billingSubscriptions.id, created.id))
  return subscription!
}

/** Starts (or replaces with) a plan paid from existing credit. */
export const adminStartCreditPlan = async (subject: Subject, input: CreditPlanInput, _adminId: number | null, now = new Date()) => {
  validateCreditPlan(subject, input)
  await requireSubject(subject)
  const rateFor = await prefetchRates({ chargeCurrency: input.chargeCurrency, chargeInterval: input.chargeInterval, paidThrough: input.startAt ?? now }, now)
  requireFirstRate(input, rateFor, now)
  const pushes: ProPush[] = []
  const subscription = await db.transaction(async (tx) => {
    const sub = await startCreditPlan(tx, subject, input, now, rateFor)
    const push = await refreshProFlag(tx, subject, now.getTime())
    if (push) pushes.push(push)
    return sub
  })
  await runProPushes(pushes)
  return subscription
}

/**
 * Records an off-Stripe payment (BTC, bank transfer) as credit in its own currency, and
 * optionally starts the plan it pays for. Live credit plans then draw from it per period.
 */
export const adminRecordPayment = async (subject: Subject, input: RecordPaymentInput, adminId: number | null) => {
  if ((input.currency !== "usd" && input.currency !== "btc") || !Number.isSafeInteger(input.amount) || input.amount <= 0) {
    throw new BillingAdminError("invalid_input")
  }
  if (input.reference !== undefined && input.reference.length > 500) throw new BillingAdminError("invalid_input")
  const plan = input.plan ? { ...input.plan, chargeCurrency: input.currency } : undefined
  if (plan) validateCreditPlan(subject, plan)
  if (input.usdCents !== undefined && !(Number.isSafeInteger(input.usdCents) && input.usdCents >= 0)) throw new BillingAdminError("invalid_input")
  await requireSubject(subject)
  const now = new Date()
  // Rates are fetched before the transaction: for the new plan's periods, or the live plan's.
  const liveBefore = plan ? null : await liveSubscription(db, subject)
  const rateFor = plan
    ? await prefetchRates({ chargeCurrency: plan.chargeCurrency, chargeInterval: plan.chargeInterval, paidThrough: plan.startAt ?? now }, now)
    : liveBefore ? await prefetchRates(liveBefore, now) : () => null
  if (plan) requireFirstRate(plan, rateFor, now)

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
      usdCents: input.usdCents ?? null,
      adminId,
    }).returning()
    let subscription: DbBillingSubscription | null = null
    if (plan) {
      subscription = await startCreditPlan(tx, subject, plan, now, rateFor)
    } else {
      // A top-up can let a live credit plan catch up on a period it couldn't cover.
      const live = await liveSubscription(tx, subject)
      if (live?.funding === "wallet" && live.chargeCurrency !== null) await renewCreditPlan(tx, live.id, now, rateFor)
    }
    const push = await refreshProFlag(tx, subject, now.getTime())
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
  const now = Date.now()
  const btcUsd = live.some((row) => row.subscription.chargeCurrency === "btc") || balances.some((row) => row.currency === "btc")
    ? await btcUsdSpot(now)
    : null
  const liveRows = await Promise.all(live.map(async (row) => {
    const sub = row.subscription
    const balance = sub.chargeCurrency ? await creditBalance(db, subjectOf(sub), sub.chargeCurrency) : null
    return {
      ...sub,
      isPro: grantsAccess(sub, now),
      creditBalance: balance,
      creditRunsOutAt: balance === null ? null : creditRunsOutAt(sub, balance, btcUsd),
      monthlyUsdCents: monthlyRevenueUsdCents(sub),
      userName: row.userName,
      username: row.username,
      spaceName: row.spaceName,
    }
  }))
  const paying = liveRows.filter((row) => row.isPro && row.monthlyUsdCents !== null && row.monthlyUsdCents > 0)
  const sum = (rows: typeof paying) => rows.reduce((total, row) => total + (row.monthlyUsdCents ?? 0), 0)
  const mrrUsdCents = sum(paying)
  const mrr = {
    mrrUsdCents,
    arrUsdCents: mrrUsdCents * 12,
    stripeUsdCents: sum(paying.filter((row) => row.funding === "stripe")),
    creditUsdCents: sum(paying.filter((row) => row.funding === "wallet")),
    payingPlans: paying.length,
    compPlans: liveRows.filter((row) => row.isPro && row.funding === "comp").length,
    /** Live paid plans with no known USD value (custom enterprise without a set value). */
    unpricedPlans: liveRows.filter((row) => row.isPro && row.funding !== "comp" && row.monthlyUsdCents === null).length,
    /** Monthly draw from credit in each currency, as charged (not converted). */
    /** Monthly draw from credit per currency; USD-priced BTC plans are estimated at today's rate. */
    creditMonthlyByCurrency: liveRows.filter((row) => row.isPro && row.chargeCurrency !== null)
      .reduce<Record<string, number>>((acc, row) => {
        const currency = row.chargeCurrency!
        const perMonth = row.chargeAmount !== null
          ? (row.chargeInterval === "year" ? row.chargeAmount / 12 : row.chargeAmount)
          : currency === "usd" ? (row.monthlyUsdCents ?? 0)
          : btcUsd !== null && row.monthlyUsdCents ? satsForUsdCents(row.monthlyUsdCents, btcUsd) : 0
        acc[currency] = Math.round((acc[currency] ?? 0) + perMonth)
        return acc
      }, {}),
  }
  return {
    mrr,
    /** Current BTC price used for run-out estimates (null when unavailable or not needed). */
    btcUsd,
    live: liveRows,
    balances: balances.map((row) => ({ ...row, balance: Number(row.balance) })),
    entries: entries.map((row) => ({ ...row.entry, userName: row.userName, username: row.username, spaceName: row.spaceName })),
    orders: orders.map((row) => ({ ...row.order, userName: row.userName, username: row.username, spaceName: row.spaceName })),
    receivedOffStripe: Object.fromEntries(received.map((row) => [row.currency, Number(row.total)])),
  }
}

/**
 * Monthly revenue a live plan represents, in USD cents. Stripe plans use catalog list prices
 * (per seat where it applies); credit plans use their recorded USD value per charge. Comps and
 * one-time prepaid plans count as zero; null means paid but no known USD value.
 */
export const monthlyRevenueUsdCents = (sub: DbBillingSubscription): number | null => {
  if (sub.funding === "comp" || sub.funding === "prepaid") return 0
  if (sub.funding === "stripe") return listMonthlyUsdCents(sub.plan, sub.interval, sub.seats)
  if (sub.funding === "wallet") {
    if (sub.chargeUsdCents === null) return sub.chargeCurrency === null ? 0 : null
    return sub.chargeInterval === "year" ? Math.round(sub.chargeUsdCents / 12) : sub.chargeUsdCents
  }
  return 0
}

