import { db } from "@in/server/db"
import { billingSubscriptions, billingWalletEntries, type DbBillingSubscription } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { and, eq, isNotNull, isNull, lte, sql } from "drizzle-orm"
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
  sub.endedAt === null && sub.funding === "wallet" && sub.chargeAmount !== null && sub.chargeCurrency !== null
  && (sub.chargeInterval === "month" || sub.chargeInterval === "year") && sub.paidThrough !== null

/**
 * Draws due periods from credit for one credit plan, inside the caller's transaction.
 * Each period is charged once (unique per plan and period start). When credit can't cover a
 * whole period, it charges what's left and extends by that fraction; with no credit it stops
 * and the plan lapses at `paid_through`. Returns how many charges were written.
 */
export const renewCreditPlan = async (tx: Transaction, subscriptionId: number, now = new Date()): Promise<number> => {
  let charged = 0
  for (let i = 0; i < MAX_PERIODS_PER_RUN; i++) {
    const [sub] = await tx.select().from(billingSubscriptions).where(eq(billingSubscriptions.id, subscriptionId)).for("update")
    if (!sub || !isCreditPlan(sub)) break
    const periodStart = sub.paidThrough!
    if (periodStart.getTime() > now.getTime() + RENEW_AHEAD_MS) break
    const subject = subjectOf(sub)
    const balance = await creditBalance(tx, subject, sub.chargeCurrency!)
    if (balance <= 0) break
    const amount = Math.min(sub.chargeAmount!, balance)
    const fraction = amount / sub.chargeAmount!
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
    isNotNull(billingSubscriptions.chargeAmount),
    lte(billingSubscriptions.paidThrough, new Date(now.getTime() + RENEW_AHEAD_MS)),
  ))
  return rows.map((row) => row.id)
}

/** When the current credit runs out if nothing is added: paid-through plus the periods it still covers. */
export const creditRunsOutAt = (sub: DbBillingSubscription, balance: number): Date | null => {
  if (!isCreditPlan(sub)) return null
  let end = sub.paidThrough!
  let remaining = Math.max(0, balance)
  for (let i = 0; i < 240 && remaining > 0; i++) {
    const amount = Math.min(sub.chargeAmount!, remaining)
    end = periodEnd(end, sub.chargeInterval as ChargeInterval, amount / sub.chargeAmount!)
    remaining -= amount
  }
  return end
}
