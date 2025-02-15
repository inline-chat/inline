import { bytea } from "@in/server/db/schema/common"
import { users } from "@in/server/db/schema/users"
import { integer, pgEnum, pgTable, serial, varchar, boolean, timestamp, text, unique } from "drizzle-orm/pg-core"

export const clientTypeEnum = pgEnum("client_type", ["ios", "macos", "web"])

export const sessions = pgTable(
  "sessions",
  {
    id: serial().primaryKey(),
    userId: integer("user_id")
      .notNull()
      .references(() => users.id),
    tokenHash: varchar("token_hash", { length: 64 }).notNull(), // hash
    revoked: timestamp({ mode: "date", precision: 3 }),
    lastActive: timestamp("last_active", { mode: "date", precision: 3 }),
    active: boolean("active").default(false).notNull(),

    // JSON serialized object of personal data for this user such as city, country, region, timezone
    personalDataEncrypted: bytea("personal_data_encrypted"),
    personalDataIv: bytea("personal_data_iv"),
    personalDataTag: bytea("personal_data_tag"),

    // push notifications
    applePushToken: text(), // @deprecated
    applePushTokenEncrypted: bytea("apple_push_token_encrypted"),
    applePushTokenIv: bytea("apple_push_token_iv"),
    applePushTokenTag: bytea("apple_push_token_tag"),

    // device id
    deviceId: text("device_id"),

    // client and device info
    clientType: clientTypeEnum("client_type"),
    clientVersion: text(),
    osVersion: text(),

    date: timestamp({ mode: "date", precision: 3 }),
  },
  (table) => ({
    deviceIdUserUnique: unique("device_id_user_unique").on(table.deviceId, table.userId),
  }),
)

export type DbSession = typeof sessions.$inferSelect
export type DbNewSession = typeof sessions.$inferInsert
