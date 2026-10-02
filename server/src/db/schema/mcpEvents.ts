import { sql } from "drizzle-orm"
import { boolean, bytea, check, index, integer, jsonb, pgTable, timestamp, varchar } from "drizzle-orm/pg-core"
import { creationDate } from "./common"
import { oauthGrants } from "./oauth"

export type McpEventSelector = { chatId: string; excludeSelf?: boolean } | { spaceId: string }

/** One pending occurrence per subscription keeps delivery and cursor acknowledgement atomic. */
export const mcpEventSubscriptions = pgTable("mcp_event_subscriptions", {
  id: varchar("id", { length: 80 }).primaryKey(),
  grantId: varchar("grant_id", { length: 128 }).notNull().references(() => oauthGrants.id),
  name: varchar("name", { length: 80 }).notNull(),
  selector: jsonb("selector").$type<McpEventSelector>().notNull(),
  callbackUrl: varchar("callback_url", { length: 4096 }).notNull(),
  secretEncrypted: bytea("secret_encrypted").notNull(),
  previousSecretEncrypted: bytea("previous_secret_encrypted"),
  previousSecretUntil: timestamp("previous_secret_until", { mode: "date", precision: 3 }),
  verifiedAt: timestamp("verified_at", { mode: "date", precision: 3 }).notNull(),
  expiresAt: timestamp("expires_at", { mode: "date", precision: 3 }).notNull(),
  cursorSeq: integer("cursor_seq").notNull(),
  gapSeq: integer("gap_seq"),
  pendingEncrypted: bytea("pending_encrypted"),
  pendingSeq: integer("pending_seq"),
  attemptCount: integer("attempt_count").notNull().default(0),
  nextAttemptAt: timestamp("next_attempt_at", { mode: "date", precision: 3 }).notNull().defaultNow(),
  leaseOwner: varchar("lease_owner", { length: 36 }),
  leaseUntil: timestamp("lease_until", { mode: "date", precision: 3 }),
  generation: integer("generation").notNull().default(0),
  stopped: boolean("stopped").notNull().default(false),
  date: creationDate,
}, (table) => [
  index("mcp_events_due_idx").on(table.nextAttemptAt, table.expiresAt).where(sql`${table.stopped} = false AND ${table.gapSeq} IS NULL`),
  index("mcp_events_grant_idx").on(table.grantId),
  index("mcp_events_expiry_idx").on(table.expiresAt),
  check("mcp_events_cursor_nonnegative", sql`${table.cursorSeq} >= 0 AND (${table.gapSeq} IS NULL OR ${table.gapSeq} >= ${table.cursorSeq})`),
  check("mcp_events_pending_pair", sql`(${table.pendingEncrypted} IS NULL) = (${table.pendingSeq} IS NULL)`),
])

export type McpEventSubscription = typeof mcpEventSubscriptions.$inferSelect
