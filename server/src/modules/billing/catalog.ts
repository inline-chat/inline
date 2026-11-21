/**
 * Plan codes Inline sells through the shared checkout service. Price IDs live in the
 * service's CHECKOUT_APPS entry; Inline only knows codes, subjects and list prices.
 */
export type BillingSubject = "user" | "space"
export type BillingPlan = "pro" | "believer" | "team" | "enterprise"
export type BillingInterval = "month" | "year" | "three_years" | "none"

export interface CatalogPlan {
  readonly code: string
  readonly subject: BillingSubject
  readonly plan: BillingPlan
  readonly interval: BillingInterval
  /** subscription: Stripe renews it. payment: one-time, grants `prepaidDays`. */
  readonly mode: "subscription" | "payment"
  /** List price in USD cents, per seat for space plans. */
  readonly usdCents: number
  readonly perSeat: boolean
  /** One-time plans: how many days the purchase lasts. */
  readonly prepaidDays?: number
  /** Only sold when the checkout mode is test. */
  readonly testOnly?: boolean
}

export const catalog: readonly CatalogPlan[] = [
  { code: "pro-monthly", subject: "user", plan: "pro", interval: "month", mode: "subscription", usdCents: 1_000, perSeat: false },
  { code: "pro-yearly", subject: "user", plan: "pro", interval: "year", mode: "subscription", usdCents: 10_000, perSeat: false },
  // Personal Pro billed every three years (Stripe price: yearly, interval_count 3).
  { code: "believer", subject: "user", plan: "believer", interval: "three_years", mode: "subscription", usdCents: 20_000, perSeat: false },
  { code: "team-monthly", subject: "space", plan: "team", interval: "month", mode: "subscription", usdCents: 2_000, perSeat: true },
  { code: "team-yearly", subject: "space", plan: "team", interval: "year", mode: "subscription", usdCents: 20_000, perSeat: true },
  // Existing one-time sandbox price used to verify payment and fulfillment end to end.
  { code: "sandbox-test", subject: "space", plan: "team", interval: "none", mode: "payment", usdCents: 0, perSeat: false, prepaidDays: 30, testOnly: true },
]

/** End of a one-time plan bought (or extended) from `from`. */
export const prepaidEnd = (plan: CatalogPlan, from: Date): Date =>
  new Date(from.getTime() + (plan.prepaidDays ?? 30) * 24 * 60 * 60 * 1000)

export const findPlan = (code: string): CatalogPlan | undefined => catalog.find((plan) => plan.code === code)
