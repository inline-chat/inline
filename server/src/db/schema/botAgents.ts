import { bytea } from "@in/server/db/schema/common"
import { users } from "@in/server/db/schema/users"
import { relations } from "drizzle-orm/_relations"
import { bigserial, index, integer, pgTable, text, timestamp, varchar } from "drizzle-orm/pg-core"

export const botAgents = pgTable(
  "bot_agents",
  {
    id: bigserial("id", { mode: "number" }).primaryKey(),
    botUserId: integer("bot_user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    name: varchar("name", { length: 256 }).notNull(),
    handle: varchar("handle", { length: 256 }),
    emoji: varchar("emoji", { length: 64 }),
    description: text("description"),
    skillKey: varchar("skill_key", { length: 256 }),
    instructionsEncrypted: bytea("instructions_encrypted"),
    createdAt: timestamp("created_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    updatedAt: timestamp("updated_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
  },
  (table) => ({
    botUserIdIndex: index("bot_agents_bot_user_id_idx").on(table.botUserId),
  }),
)

export const botAgentsRelations = relations(botAgents, ({ one }) => ({
  botUser: one(users, {
    fields: [botAgents.botUserId],
    references: [users.id],
  }),
}))

export type DbBotAgent = typeof botAgents.$inferSelect
export type DbNewBotAgent = typeof botAgents.$inferInsert
