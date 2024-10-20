import { users } from "@in/server/db/schema/users"
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
  bigint,
  uuid,
  json,
} from "drizzle-orm/pg-core"

export const sessions = pgTable("sessions", {
  id: serial().primaryKey(),
  userId: integer("user_id")
    .notNull()
    .references(() => users.id),
  tokenHash: varchar("token_hash", { length: 64 }).notNull(), // hash
  revoked: timestamp({ mode: "date", precision: 3 }),
  lastActive: timestamp("last_active", { mode: "date", precision: 3 }),
  date: timestamp({ mode: "date", precision: 3 }),
})

export type DbSession = typeof sessions.$inferSelect
export type DbNewSession = typeof sessions.$inferInsert
