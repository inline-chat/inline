import { db } from "@in/server/db"
import { billingSubscriptions, spaces, users, type DbBillingSubscription } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { and, eq, isNull, lt, ne, or, sql } from "drizzle-orm"
import { enqueueProUpdate, type ProPush } from "./notify"

export type Subject = { readonly userId: number; readonly spaceId?: undefined } | { readonly spaceId: number; readonly userId?: undefined }

type Executor = Transaction | typeof db

/** Stripe statuses that keep access; past_due keeps it while Stripe retries the card. */
const accessStatuses = new Set(["active", "trialing", "past_due"])
/** Stripe can renew a little after period end; don't drop access in that gap. */
export const STRIPE_RENEWAL_GRACE_MS = 3 * 24 * 60 * 60 * 1000
/** Stripe statuses after which the subscription never comes back. */
export const endedStripeStatuses = new Set(["canceled", "incomplete_expired", "unpaid"])

export const grantsAccess = (
  subscription: Pick<DbBillingSubscription, "endedAt" | "status" | "paidThrough" | "funding">,
  now = Date.now(),
): boolean => {
  if (subscription.endedAt || !accessStatuses.has(subscription.status)) return false
  if (!subscription.paidThrough) return true
  const grace = subscription.funding === "stripe" ? STRIPE_RENEWAL_GRACE_MS : 0
  return subscription.paidThrough.getTime() + grace > now
}

export const subjectWhere = (subject: Subject) =>
  subject.userId !== undefined
    ? eq(billingSubscriptions.userId, subject.userId)
    : eq(billingSubscriptions.spaceId, subject.spaceId!)

export const liveSubscription = async (tx: Executor, subject: Subject, lock = false) => {
  const query = tx.select().from(billingSubscriptions)
    .where(and(subjectWhere(subject), isNull(billingSubscriptions.endedAt)))
    .limit(1)
  const [row] = lock ? await query.for("update") : await query
  return row ?? null
}

export const subjectOf = (row: { userId: number | null; spaceId: number | null }): Subject =>
  row.userId !== null ? { userId: row.userId } : { spaceId: row.spaceId! }

export const subjectKey = (subject: Subject) =>
  subject.userId !== undefined ? `user:${subject.userId}` : `space:${subject.spaceId}`

/** The public badge a personal plan shows. */
export const badgeForPlan = (plan: string): "pro" | "believer" => plan === "believer" ? "believer" : "pro"

/**
 * Writes the derived `is_pro` flag (and a user's public `badge`) for a subject. When it changes, records the durable
 * update in the same transaction and returns the live push to run after commit.
 */
export const refreshProFlag = async (tx: Transaction, subject: Subject, now = Date.now()): Promise<ProPush | null> => {
  const live = await liveSubscription(tx, subject)
  const isPro = live ? grantsAccess(live, now) : false
  if (subject.userId !== undefined) {
    const badge = isPro && live ? badgeForPlan(live.plan) : null
    const changed = await tx.update(users).set({ isPro, badge })
      .where(and(
        eq(users.id, subject.userId),
        or(sql`${users.isPro} is distinct from ${isPro}`, sql`${users.badge} is distinct from ${badge}`),
      ))
      .returning({ id: users.id })
    return changed.length > 0 ? enqueueProUpdate(tx, subject) : null
  }
  const changed = await tx.update(spaces).set({ isPro })
    .where(and(eq(spaces.id, subject.spaceId!), sql`${spaces.isPro} is distinct from ${isPro}`))
    .returning({ id: spaces.id })
  return changed.length > 0 ? enqueueProUpdate(tx, subject) : null
}

/** Ends live rows whose paid period (plus Stripe grace) is over. Returns affected subjects. */
export const expireLapsedSubscriptions = async (tx: Transaction, now = new Date()): Promise<Subject[]> => {
  const stripeCutoff = new Date(now.getTime() - STRIPE_RENEWAL_GRACE_MS)
  const lapsed = await tx.update(billingSubscriptions)
    .set({ endedAt: now, status: "expired", updatedAt: now })
    .where(and(
      isNull(billingSubscriptions.endedAt),
      or(
        and(eq(billingSubscriptions.funding, "stripe"), lt(billingSubscriptions.paidThrough, stripeCutoff)),
        and(ne(billingSubscriptions.funding, "stripe"), lt(billingSubscriptions.paidThrough, now)),
      ),
    ))
    .returning({ userId: billingSubscriptions.userId, spaceId: billingSubscriptions.spaceId })
  return lapsed.map(subjectOf)
}

