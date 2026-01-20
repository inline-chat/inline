import { users } from "@in/server/db/schema/users"
import { bytea } from "@in/server/db/schema/common"
import { integer, pgTable, serial, timestamp, text, varchar, unique } from "drizzle-orm/pg-core"

export const superadminUsers = pgTable(
  "superadmin_users",
  {
    id: serial().primaryKey(),
    email: varchar("email", { length: 256 }).notNull().unique(),
    userId: integer("user_id").references(() => users.id),
    passwordHash: text("password_hash"),
    passwordSetAt: timestamp("password_set_at", { mode: "date", precision: 3 }),
    totpSecretEncrypted: bytea("totp_secret_encrypted"),
    totpSecretIv: bytea("totp_secret_iv"),
    totpSecretTag: bytea("totp_secret_tag"),
    totpEnabledAt: timestamp("totp_enabled_at", { mode: "date", precision: 3 }),
    totpLastUsedAt: timestamp("totp_last_used_at", { mode: "date", precision: 3 }),
    failedLoginAttempts: integer("failed_login_attempts").default(0).notNull(),
    lastLoginAttemptAt: timestamp("last_login_attempt_at", { mode: "date", precision: 3 }),
    loginLockedUntil: timestamp("login_locked_until", { mode: "date", precision: 3 }),
    disabledAt: timestamp("disabled_at", { mode: "date", precision: 3 }),
    date: timestamp("date", { mode: "date", precision: 3 }).defaultNow(),
  },
  (table) => ({
    userIdUnique: unique("superadmin_users_user_id_unique").on(table.userId),
  }),
)

export type DbSuperadminUser = typeof superadminUsers.$inferSelect
export type DbNewSuperadminUser = typeof superadminUsers.$inferInsert
