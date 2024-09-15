import {
  integer,
  pgEnum,
  pgTable,
  serial,
  uniqueIndex,
  varchar,
  boolean,
  timestamp,
  text,
} from "drizzle-orm/pg-core"

export const waitlist = pgTable("waitlist", {
  id: serial("id").primaryKey(),
  email: varchar("email", { length: 256 }).notNull().unique(),
  verified: boolean("verified").default(false).notNull(),
  name: varchar("name", { length: 256 }),
  userAgent: text("user_agent"),
  timeZone: varchar("time_zone", { length: 256 }),
  date: timestamp("date", { mode: "date", withTimezone: true }).defaultNow(),
})

export type WaitlistSubscriber = typeof waitlist.$inferSelect
export type NewWaitlistSubscriber = typeof waitlist.$inferInsert
