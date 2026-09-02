import { pgTable, timestamp, varchar } from "drizzle-orm/pg-core"

export const reservedUsernames = pgTable("reserved_usernames", {
  username: varchar("username", { length: 256 }).primaryKey(),
  createdAt: timestamp("created_at", { mode: "date", withTimezone: true })
    .defaultNow()
    .notNull(),
})

export type DbReservedUsername = typeof reservedUsernames.$inferSelect
