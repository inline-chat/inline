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
    /** pro | team | enterprise */
    plan: varchar({ length: 32 }).notNull(),
    /** month | year | three_years | none */
    interval: varchar({ length: 16 }).notNull(),
    /** stripe | prepaid | wallet | comp */
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
    note: text(),
    createdAt: at("created_at").defaultNow().notNull(),
    updatedAt: at("updated_at").defaultNow().notNull(),
    endedAt: at("ended_at"),
  },
  (table) => [
    check("billing_subscriptions_subject_check", sql`(${table.userId} is null) <> (${table.spaceId} is null)`),
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
    /** legacy_import | btc_topup | admin_topup | plan_charge | refund | adjustment */
    kind: varchar({ length: 32 }).notNull(),
    reference: text(),
    subscriptionId: integer("subscription_id").references(() => billingSubscriptions.id),
    adminId: integer("admin_id").references(() => superadminUsers.id),
    createdAt: at("created_at").defaultNow().notNull(),
  },
  (table) => [
    check("billing_wallet_entries_subject_check", sql`(${table.userId} is null) <> (${table.spaceId} is null)`),
    check("billing_wallet_entries_currency_check", sql`${table.currency} in ('usd', 'btc')`),
    index("billing_wallet_entries_user_idx").on(table.userId),
    index("billing_wallet_entries_space_idx").on(table.spaceId),
  ],
)

export type DbBillingSubscription = typeof billingSubscriptions.$inferSelect
export type DbBillingOrder = typeof billingOrders.$inferSelect
export type DbBillingWalletEntry = typeof billingWalletEntries.$inferSelect
