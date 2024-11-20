import { users } from "@in/server/db/schema/users"
import { integer, pgEnum, pgTable, serial, varchar, timestamp, text } from "drizzle-orm/pg-core"

export const clientTypeEnum = pgEnum("client_type", ["ios", "macos", "web"])

export const sessions = pgTable("sessions", {
  id: serial().primaryKey(),
  userId: integer("user_id")
    .notNull()
    .references(() => users.id),
  tokenHash: varchar("token_hash", { length: 64 }).notNull(), // hash
  revoked: timestamp({ mode: "date", precision: 3 }),
  lastActive: timestamp("last_active", { mode: "date", precision: 3 }),

  // personal info
  country: text(),
  region: text(),
  city: text(),
  timezone: text(),
  ip: text(),
  deviceName: text(),
  applePushToken: text(),

  // client and device info
  clientType: clientTypeEnum("client_type"),
  clientVersion: text(),
  osVersion: text(),

  date: timestamp({ mode: "date", precision: 3 }),
})

export type DbSession = typeof sessions.$inferSelect
export type DbNewSession = typeof sessions.$inferInsert
