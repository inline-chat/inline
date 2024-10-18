import {
  pgTable,
  serial,
  varchar,
  timestamp,
  smallint,
} from "drizzle-orm/pg-core"

export const loginCodes = pgTable("login_codes", {
  id: serial().primaryKey(),
  email: varchar("email", { length: 256 }).unique(),
  phoneNumber: varchar("phone_number", { length: 15 }).unique(),
  code: varchar("code", { length: 10 }).notNull(),
  expiresAt: timestamp("expires_at", { mode: "date", precision: 3 }).notNull(),
  attempts: smallint("attempts").default(0),
  date: timestamp("date", { mode: "date", precision: 3 }).defaultNow(),
})

export type DbLoginCode = typeof loginCodes.$inferSelect
export type DbNewLoginCode = typeof loginCodes.$inferInsert
