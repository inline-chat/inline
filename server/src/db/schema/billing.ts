import { spaces } from "@in/server/db/schema/spaces"
import { superadminUsers } from "@in/server/db/schema/superadminUsers"
import { users } from "@in/server/db/schema/users"
import { sql } from "drizzle-orm"
import {
  bigint,
  boolean,
  check,
  index,
  integer,
  pgTable,
  serial,
  text,
  timestamp,
  uniqueIndex,
  varchar,
} from "drizzle-orm/pg-core"

const at = (name: string) => timestamp(name, { mode: "date", precision: 3, withTimezone: true })

/**
 * A plan held by exactly one subject: a user (personal Pro) or a space (team Pro).
 * Every funding source moves `paid_through` forward; `users.is_pro` and `spaces.is_pro`
 * are derived from the live row. At most one live (not ended) row per subject.
 */
export const billingSubscriptions = pgTable(
  "billing_subscriptions",
  {
    id: serial().primaryKey(),
    userId: integer("user_id").references(() => users.id),
    spaceId: integer("space_id").references(() => spaces.id),
    /** pro | believer | team | business | enterprise */
    plan: varchar({ length: 32 }).notNull(),
    /** month | year | three_years | none */
    interval: varchar({ length: 16 }).notNull(),
    /** stripe | prepaid | wallet (paid from credit) | comp */
    funding: varchar({ length: 16 }).notNull(),
    /** Stripe subscription status for stripe funding; active | expired | canceled otherwise. */
    status: varchar({ length: 32 }).notNull(),
    seats: integer().default(1).notNull(),
    /** Null means no end date (open-ended comp). */
    paidThrough: at("paid_through"),
    cancelAtPeriodEnd: boolean("cancel_at_period_end").default(false).notNull(),
    payerUserId: integer("payer_user_id").references(() => users.id),
    stripeSubscriptionId: varchar("stripe_subscription_id", { length: 255 }),
    livemode: boolean().default(false).notNull(),
    /**
     * Credit plans. `charge_currency` is the credit drawn (usd | btc); null means the plan isn't
     * renewed from credit. Each period costs `charge_usd_cents`, converted to BTC at that
     * period's rate when the credit is BTC, unless `charge_amount` fixes the amount drawn
     * (minor units of the credit currency).
     */
    chargeAmount: bigint("charge_amount", { mode: "number" }),
    chargeCurrency: varchar("charge_currency", { length: 8 }),
    /** month | year */
    chargeInterval: varchar("charge_interval", { length: 16 }),
    /** Price of one period in USD cents; also what MRR counts. */
    chargeUsdCents: integer("charge_usd_cents"),
    note: text(),
    createdAt: at("created_at").defaultNow().notNull(),
    updatedAt: at("updated_at").defaultNow().notNull(),
    endedAt: at("ended_at"),
  },
  (table) => [
    check("billing_subscriptions_subject_check", sql`(${table.userId} is null) <> (${table.spaceId} is null)`),
    check("billing_subscriptions_charge_check", sql`(${table.chargeCurrency} is null) = (${table.chargeInterval} is null) and (${table.chargeAmount} is null or (${table.chargeAmount} > 0 and ${table.chargeCurrency} is not null)) and (${table.chargeCurrency} is null or ${table.chargeAmount} is not null or ${table.chargeUsdCents} > 0)`),
    uniqueIndex("billing_subscriptions_live_user_unique").on(table.userId).where(sql`${table.endedAt} is null and ${table.userId} is not null`),
    uniqueIndex("billing_subscriptions_live_space_unique").on(table.spaceId).where(sql`${table.endedAt} is null and ${table.spaceId} is not null`),
    uniqueIndex("billing_subscriptions_stripe_unique").on(table.stripeSubscriptionId),
    index("billing_subscriptions_paid_through_idx").on(table.paidThrough).where(sql`${table.endedAt} is null`),
  ],
)

/** A checkout attempt sent to the shared checkout service. `id` is the service's orderId. */
export const billingOrders = pgTable(
  "billing_orders",
  {
    id: varchar({ length: 64 }).primaryKey(),
    buyerUserId: integer("buyer_user_id").references(() => users.id).notNull(),
    userId: integer("user_id").references(() => users.id),
    spaceId: integer("space_id").references(() => spaces.id),
    /** Catalog code, for example pro-monthly. */
    planCode: varchar("plan_code", { length: 64 }).notNull(),
    quantity: integer().default(1).notNull(),
    /** pending | paid | failed | expired | refunded */
    status: varchar({ length: 16 }).notNull(),
    livemode: boolean().default(false).notNull(),
    checkoutSessionId: varchar("checkout_session_id", { length: 255 }),
    checkoutUrl: text("checkout_url"),
    stripeSubscriptionId: varchar("stripe_subscription_id", { length: 255 }),
    paymentIntentId: varchar("payment_intent_id", { length: 255 }),
    subscriptionId: integer("subscription_id").references(() => billingSubscriptions.id),
    createdAt: at("created_at").defaultNow().notNull(),
    updatedAt: at("updated_at").defaultNow().notNull(),
  },
  (table) => [
    check("billing_orders_subject_check", sql`(${table.userId} is null) <> (${table.spaceId} is null)`),
    uniqueIndex("billing_orders_checkout_session_unique").on(table.checkoutSessionId),
    index("billing_orders_buyer_idx").on(table.buyerUserId),
  ],
)

/** Processed checkout notifications, keyed by Stripe event id, so a replay is a no-op. */
export const billingEvents = pgTable("billing_events", {
  id: varchar({ length: 255 }).primaryKey(),
  orderId: varchar("order_id", { length: 64 }),
  type: varchar({ length: 64 }).notNull(),
  receivedAt: at("received_at").defaultNow().notNull(),
})

/**
 * Admin-managed credit for a user or space, in minor units (USD cents, BTC sats).
 * Append-only; the balance is the sum per currency.
 */
export const billingWalletEntries = pgTable(
  "billing_wallet_entries",
  {
    id: serial().primaryKey(),
    userId: integer("user_id").references(() => users.id),
    spaceId: integer("space_id").references(() => spaces.id),
    /** usd | btc */
    currency: varchar({ length: 8 }).notNull(),
    amount: bigint({ mode: "number" }).notNull(),
    /** legacy_import | btc_topup | admin_topup | plan_charge | refund | adjustment (future: stripe_topup) */
    kind: varchar({ length: 32 }).notNull(),
    reference: text(),
    subscriptionId: integer("subscription_id").references(() => billingSubscriptions.id),
    adminId: integer("admin_id").references(() => superadminUsers.id),
    /** When the money actually moved (for example a BTC payment last month); null means at creation. */
    occurredAt: at("occurred_at"),
    /** Credit plan charges: the start of the period paid for. One charge per plan and period. */
    periodStart: at("period_start"),
    /** USD value of this entry when it happened (for BTC: amount × that day's rate). Reporting only. */
    usdCents: integer("usd_cents"),
    createdAt: at("created_at").defaultNow().notNull(),
  },
  (table) => [
    check("billing_wallet_entries_subject_check", sql`(${table.userId} is null) <> (${table.spaceId} is null)`),
    check("billing_wallet_entries_currency_check", sql`${table.currency} in ('usd', 'btc')`),
    index("billing_wallet_entries_user_idx").on(table.userId),
    index("billing_wallet_entries_space_idx").on(table.spaceId),
    uniqueIndex("billing_wallet_entries_period_unique").on(table.subscriptionId, table.periodStart)
      .where(sql`${table.periodStart} is not null`),
  ],
)

export type DbBillingSubscription = typeof billingSubscriptions.$inferSelect
export type DbBillingOrder = typeof billingOrders.$inferSelect
export type DbBillingWalletEntry = typeof billingWalletEntries.$inferSelect
