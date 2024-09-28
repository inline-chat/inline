import { sql } from "drizzle-orm"
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
  bigserial,
  bigint,
} from "drizzle-orm/pg-core"
import { pgSchema, pgSequence } from "drizzle-orm/pg-core"

// Sequence with params
export const userIdSequence = pgSequence("user_id", {
  startWith: 1000,
  minValue: 1000,
  cycle: false,
  cache: 100,
  increment: 3,
})

export const users = pgTable("users", {
  id: bigint("id", { mode: "bigint" })
    .default(sql`nextval('user_id')`)
    .primaryKey(),
  email: varchar("email", { length: 256 }).unique(),
  phoneNumber: varchar("phone_number", { length: 15 }).unique(),
  email_verified: boolean("email_verified"),
  phone_verified: boolean("phone_verified"),
  firstName: varchar("first_name", { length: 256 }),
  lastName: varchar("last_name", { length: 256 }),
  deleted: boolean("deleted"),
  date: timestamp("date", { mode: "date", precision: 3 }).defaultNow(),
})

// flags? pendingSetup
// presence? online

export type DbUser = typeof users.$inferSelect
export type DbNewUser = typeof users.$inferInsert
