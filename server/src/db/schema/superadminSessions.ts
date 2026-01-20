import { users } from "@in/server/db/schema/users"
import { integer, pgTable, serial, text, timestamp, varchar, unique } from "drizzle-orm/pg-core"

export const superadminSessions = pgTable(
  "superadmin_sessions",
  {
    id: serial().primaryKey(),
    userId: integer("user_id")
      .notNull()
      .references(() => users.id),
    tokenHash: varchar("token_hash", { length: 64 }).notNull(),
    revokedAt: timestamp("revoked_at", { mode: "date", precision: 3 }),
    lastSeenAt: timestamp("last_seen_at", { mode: "date", precision: 3 }),
    stepUpAt: timestamp("step_up_at", { mode: "date", precision: 3 }),
    expiresAt: timestamp("expires_at", { mode: "date", precision: 3 }).notNull(),
    idleExpiresAt: timestamp("idle_expires_at", { mode: "date", precision: 3 }).notNull(),
    ip: text("ip"),
    userAgentHash: varchar("user_agent_hash", { length: 64 }),
    date: timestamp("date", { mode: "date", precision: 3 }).defaultNow(),
  },
  (table) => ({
    tokenHashUnique: unique("superadmin_sessions_token_hash_unique").on(table.tokenHash),
  }),
)

export type DbSuperadminSession = typeof superadminSessions.$inferSelect
export type DbNewSuperadminSession = typeof superadminSessions.$inferInsert
