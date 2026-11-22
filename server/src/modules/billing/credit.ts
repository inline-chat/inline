import { db } from "@in/server/db"
import { billingSubscriptions, billingWalletEntries, type DbBillingSubscription } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { and, eq, isNotNull, isNull, lte, sql } from "drizzle-orm"
import { btcUsdForPeriod } from "./btcPrice"
import { subjectOf, type Subject } from "./entitlements"

/** Renew a day before the paid period ends so access never gaps. */
export const RENEW_AHEAD_MS = 24 * 60 * 60 * 1000
/** Bound catch-up after downtime; one call never charges more periods than this. */
const MAX_PERIODS_PER_RUN = 36

export type ChargeInterval = "month" | "year"

/** Adds whole months or years in UTC, clamping to the month's last day (Jan 31 + 1 month = Feb 28). */
const addWhole = (from: Date, interval: ChargeInterval): Date => {
  const months = interval === "year" ? 12 : 1
  const d = new Date(from)
  const day = d.getUTCDate()
  d.setUTCDate(1)
  d.setUTCMonth(d.getUTCMonth() + months)
  const lastDay = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).getUTCDate()
  d.setUTCDate(Math.min(day, lastDay))
  return d
}

/** End of a period starting at `from`; a partial charge buys the same fraction of that period. */
export const periodEnd = (from: Date, interval: ChargeInterval, fraction = 1): Date => {
  const whole = addWhole(from, interval)
  if (fraction >= 1) return whole
  return new Date(from.getTime() + Math.floor((whole.getTime() - from.getTime()) * fraction))
}

const subjectWhere = (subject: Subject) =>
  subject.userId !== undefined ? eq(billingWalletEntries.userId, subject.userId) : eq(billingWalletEntries.spaceId, subject.spaceId!)

export const creditBalance = async (tx: Transaction | typeof db, subject: Subject, currency: string): Promise<number> => {
  const [row] = await tx.select({ balance: sql<string | null>`sum(${billingWalletEntries.amount})` })
    .from(billingWalletEntries)
    .where(and(subjectWhere(subject), eq(billingWalletEntries.currency, currency)))
  return Number(row?.balance ?? 0)
}

const isCreditPlan = (sub: DbBillingSubscription) =>
  sub.endedAt === null && sub.funding === "wallet" && sub.chargeCurrency !== null
  && (sub.chargeAmount !== null || (sub.chargeUsdCents ?? 0) > 0)
  && (sub.chargeInterval === "month" || sub.chargeInterval === "year") && sub.paidThrough !== null

/** BTC price (USD per BTC) to charge a period starting at the given date with; null when unknown. */
export type RateFor = (periodStart: Date) => number | null

/** Sats for a USD amount at a BTC price, rounded up so the period is never undercharged. */
export const satsForUsdCents = (usdCents: number, btcUsd: number) => Math.ceil((usdCents / 100 / btcUsd) * 100_000_000)

/**
 * What one full period draws from credit, in the credit's minor units, and its USD value.
 * Fixed plans draw `charge_amount`; USD-priced plans draw the price, converted to sats at the
 * period's rate for BTC credit. Null when a needed rate is unknown.
 */
const periodCharge = (sub: DbBillingSubscription, periodStart: Date, rateFor: RateFor): { amount: number; usdCents: number | null } | null => {
  if (sub.chargeAmount !== null) {
    const rate = sub.chargeCurrency === "btc" ? rateFor(periodStart) : null
    const usd = sub.chargeCurrency === "usd" ? sub.chargeAmount : rate === null ? sub.chargeUsdCents : Math.round((sub.chargeAmount / 100_000_000) * rate * 100)
    return { amount: sub.chargeAmount, usdCents: usd }
  }
  const price = sub.chargeUsdCents!
  if (sub.chargeCurrency === "usd") return { amount: price, usdCents: price }
  const rate = rateFor(periodStart)
  return rate === null ? null : { amount: satsForUsdCents(price, rate), usdCents: price }
}

/** The period starts a renewal run may charge, from `paid_through` up to the renewal window. */
const dueStarts = (paidThrough: Date, interval: ChargeInterval, now: Date) => {
  const starts: Date[] = []
  let start = paidThrough
  while (starts.length < MAX_PERIODS_PER_RUN && start.getTime() <= now.getTime() + RENEW_AHEAD_MS) {
    starts.push(start)
    start = periodEnd(start, interval)
  }
  return starts
}

/**
 * Fetches BTC rates for a plan's due periods before any transaction, so no row lock is held
 * across the network. Plans that don't need BTC conversion get an empty lookup.
 */
export const prefetchRates = async (sub: Pick<DbBillingSubscription, "chargeCurrency" | "chargeInterval" | "paidThrough">, now: Date): Promise<RateFor> => {
  if (sub.chargeCurrency !== "btc" || !sub.paidThrough || (sub.chargeInterval !== "month" && sub.chargeInterval !== "year")) return () => null
  const rates = new Map<number, number | null>()
  for (const start of dueStarts(sub.paidThrough, sub.chargeInterval, now)) {
    rates.set(start.getTime(), await btcUsdForPeriod(start, now))
  }
  return (periodStart) => rates.get(periodStart.getTime()) ?? null
}

/**
 * Draws due periods from credit for one credit plan, inside the caller's transaction.
 * Each period is charged once (unique per plan and period start). When credit can't cover a
 * whole period, it charges what's left and extends by that fraction; with no credit it stops
 * and the plan lapses at `paid_through`. Returns how many charges were written.
 */
export const renewCreditPlan = async (tx: Transaction, subscriptionId: number, now = new Date(), rateFor: RateFor = () => null): Promise<number> => {
  let charged = 0
  for (let i = 0; i < MAX_PERIODS_PER_RUN; i++) {
    const [sub] = await tx.select().from(billingSubscriptions).where(eq(billingSubscriptions.id, subscriptionId)).for("update")
    if (!sub || !isCreditPlan(sub)) break
    const periodStart = sub.paidThrough!
    if (periodStart.getTime() > now.getTime() + RENEW_AHEAD_MS) break
    const subject = subjectOf(sub)
    const balance = await creditBalance(tx, subject, sub.chargeCurrency!)
    if (balance <= 0) break
    // Without the period's BTC rate, wait for the next sweep (renewal starts a day early).
    const full = periodCharge(sub, periodStart, rateFor)
    if (!full) break
    const amount = Math.min(full.amount, balance)
    const fraction = amount / full.amount
    const inserted = await tx.insert(billingWalletEntries).values({
      userId: sub.userId,
      spaceId: sub.spaceId,
      currency: sub.chargeCurrency!,
      amount: -amount,
      kind: "plan_charge",
      reference: `${sub.plan} ${sub.chargeInterval} from ${periodStart.toISOString().slice(0, 10)}${fraction < 1 ? " (partial)" : ""}`,
      subscriptionId: sub.id,
      periodStart,
      occurredAt: periodStart,
      usdCents: full.usdCents === null ? null : -Math.round(full.usdCents * fraction),
    }).onConflictDoNothing().returning({ id: billingWalletEntries.id })
    if (inserted.length === 0) break
    await tx.update(billingSubscriptions)
      .set({ paidThrough: periodEnd(periodStart, sub.chargeInterval as ChargeInterval, fraction), updatedAt: now })
      .where(eq(billingSubscriptions.id, sub.id))
    charged += 1
    if (fraction < 1) break
  }
  return charged
}

/** Live credit plans whose paid period ends within the renewal window. */
export const dueCreditPlanIds = async (now = new Date()) => {
  const rows = await db.select({ id: billingSubscriptions.id }).from(billingSubscriptions).where(and(
    isNull(billingSubscriptions.endedAt),
    eq(billingSubscriptions.funding, "wallet"),
    isNotNull(billingSubscriptions.chargeCurrency),
    lte(billingSubscriptions.paidThrough, new Date(now.getTime() + RENEW_AHEAD_MS)),
  ))
  return rows.map((row) => row.id)
}

/**
 * When the current credit runs out if nothing is added: paid-through plus the periods it still
 * covers. BTC credit priced in USD is estimated at today's rate (`spotBtcUsd`); null without one.
 */
export const creditRunsOutAt = (sub: DbBillingSubscription, balance: number, spotBtcUsd: number | null = null): Date | null => {
  if (!isCreditPlan(sub)) return null
  const per = periodCharge(sub, sub.paidThrough!, () => spotBtcUsd)
  if (!per) return null
  let end = sub.paidThrough!
  let remaining = Math.max(0, balance)
  for (let i = 0; i < 240 && remaining > 0; i++) {
    const amount = Math.min(per.amount, remaining)
    end = periodEnd(end, sub.chargeInterval as ChargeInterval, amount / per.amount)
    remaining -= amount
  }
  return end
}
