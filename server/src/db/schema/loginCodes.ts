import {
  pgTable,
  serial,
  varchar,
  timestamp,
  smallint,
  text,
  check,
  index,
  uniqueIndex,
} from "drizzle-orm/pg-core"
import { sql } from "drizzle-orm"

export const loginCodes = pgTable(
  "login_codes",
  {
    id: serial().primaryKey(),
    email: varchar("email", { length: 256 }),
    phoneNumber: varchar("phone_number", { length: 15 }),
    challengeId: varchar("challenge_id", { length: 64 }),
    // Legacy plain-text field; new writes should keep this null.
    code: varchar("code", { length: 10 }),
    // Argon2 hash of login code for at-rest protection and verification.
    codeHash: text("code_hash"),
    expiresAt: timestamp("expires_at", { mode: "date", precision: 3 }).notNull(),
    attempts: smallint("attempts").default(0),
    date: timestamp("date", { mode: "date", precision: 3 }).defaultNow(),
  },
  (table) => ({
    challengeIdUnique: uniqueIndex("login_codes_challenge_id_unique").on(table.challengeId),
    emailExpiryIndex: index("login_codes_email_expires_idx").on(table.email, table.expiresAt),
    phoneExpiryIndex: index("login_codes_phone_expires_idx").on(table.phoneNumber, table.expiresAt),
    // Prevent unusable rows where neither legacy code nor hash is present.
    codeOrHashPresent: check(
      "login_codes_code_or_hash_present",
      sql`${table.code} is not null or ${table.codeHash} is not null`,
    ),
  }),
)

export type DbLoginCode = typeof loginCodes.$inferSelect
export type DbNewLoginCode = typeof loginCodes.$inferInsert
