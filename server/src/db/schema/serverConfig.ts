import { sql } from "drizzle-orm"
import {
  check,
  integer,
  jsonb,
  pgTable,
  timestamp,
  varchar,
} from "drizzle-orm/pg-core"
import { users } from "./users"

export const serverConfig = pgTable(
  "server_config",
  {
    key: varchar("key", { length: 160 }).primaryKey(),
    value: jsonb("value").notNull(),
    version: integer("version").default(1).notNull(),
    updatedByUserId: integer("updated_by_user_id")
      .references(() => users.id, { onDelete: "set null" }),
    createdAt: timestamp("created_at", { mode: "date", withTimezone: true })
      .defaultNow()
      .notNull(),
    updatedAt: timestamp("updated_at", { mode: "date", withTimezone: true })
      .defaultNow()
      .notNull(),
  },
  (table) => [
    check("server_config_version_check", sql`${table.version} > 0`),
  ],
)

export type DbServerConfig = typeof serverConfig.$inferSelect
