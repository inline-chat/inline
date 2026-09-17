import { sql } from "drizzle-orm"
import { check, index, integer, pgTable, timestamp, varchar } from "drizzle-orm/pg-core"

export const authDeliveryBudgets = pgTable("auth_delivery_budgets", {
  key: varchar("key", { length: 96 }).primaryKey(),
  attempts: integer("attempts").notNull(),
  expiresAt: timestamp("expires_at", { mode: "date", withTimezone: true, precision: 3 }).notNull(),
}, (table) => ({ expiry: index("auth_delivery_budgets_expiry_idx").on(table.expiresAt), positive: check("auth_delivery_budgets_attempts_positive", sql`${table.attempts} > 0`) }))
