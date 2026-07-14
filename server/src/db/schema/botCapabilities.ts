import { integer, pgTable, serial, timestamp, uniqueIndex, varchar } from "drizzle-orm/pg-core"
import { users } from "./users"

export const botCapabilities = pgTable(
  "bot_capabilities",
  {
    id: serial("id").primaryKey(),
    botUserId: integer("bot_user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    kind: varchar("kind", { length: 64 }).notNull(),
    version: integer("version").notNull(),
    createdAt: timestamp("created_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    updatedAt: timestamp("updated_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
  },
  (table) => ({
    botCapabilitiesBotUserIdKindUnique: uniqueIndex("bot_capabilities_bot_user_id_kind_unique").on(
      table.botUserId,
      table.kind,
    ),
  }),
)

export type DbBotCapability = typeof botCapabilities.$inferSelect
export type DbNewBotCapability = typeof botCapabilities.$inferInsert
