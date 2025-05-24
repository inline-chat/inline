import { users } from "@in/server/db/schema/users"
import { bytea, integer, pgTable, type AnyPgColumn } from "drizzle-orm/pg-core"

export const userSettings = pgTable("user_settings", {
  userId: integer("user_id")
    .primaryKey()
    .references((): AnyPgColumn => users.id),

  // General settings
  generalEncrypted: bytea("general_encrypted"),
  generalIv: bytea("general_iv"),
  generalTag: bytea("general_tag"),
})

export type DbUserSettings = typeof userSettings.$inferSelect
export type DbNewUserSettings = typeof userSettings.$inferInsert
