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

export const thereUsers = pgTable("there_users", {
  id: serial("id").primaryKey(),
  email: varchar("email", { length: 256 }).notNull().unique(),
  name: varchar("name", { length: 256 }),
  timeZone: varchar("time_zone", { length: 256 }),
  date: timestamp("date", { mode: "date", withTimezone: true }).defaultNow(),
})

export type ThereUser = typeof thereUsers.$inferSelect
export type NewThereUser = typeof thereUsers.$inferInsert
