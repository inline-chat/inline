import { sql } from "drizzle-orm"
import { check, index, integer, pgTable, primaryKey, smallint, timestamp } from "drizzle-orm/pg-core"

/**
 * Materialized rows of `effectiveChatAccessSql`, kept current by the writers
 * that change access (`syncChatAccess`) and repaired by the verifier.
 *
 * Derived data, so no foreign keys: a cascade from `chats` or `users` would
 * lock these rows before the access lock and could deadlock with a sync.
 */
export const chatAccess = pgTable("chat_access", {
  chatId: integer("chat_id").notNull(),
  userId: integer("user_id").notNull(),
}, (table) => [
  primaryKey({ columns: [table.chatId, table.userId] }),
  index("chat_access_user_chat_idx").on(table.userId, table.chatId),
])

export type DbChatAccess = typeof chatAccess.$inferSelect

/**
 * One row, written when the verifier first completes the backfill. Before it
 * exists, missing rows are expected; after it, every difference is drift.
 */
export const chatAccessState = pgTable("chat_access_state", {
  id: smallint("id").primaryKey().default(1),
  backfilledAt: timestamp("backfilled_at", { mode: "date", withTimezone: true, precision: 3 }).notNull(),
}, (table) => [
  check("chat_access_state_singleton", sql`${table.id} = 1`),
])
