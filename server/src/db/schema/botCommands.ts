import { integer, pgTable, serial, timestamp, uniqueIndex, varchar } from "drizzle-orm/pg-core"
import { users } from "@in/server/db/schema/users"
import { relations } from "drizzle-orm/_relations"

export const botCommands = pgTable(
  "bot_commands",
  {
    id: serial("id").primaryKey(),

    botUserId: integer("bot_user_id")
      .notNull()
      .references(() => users.id),

    command: varchar("command", { length: 32 }).notNull(),
    description: varchar("description", { length: 256 }).notNull(),
    sortOrder: integer("sort_order").notNull().default(0),

    createdAt: timestamp("created_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    updatedAt: timestamp("updated_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
  },
  (table) => ({
    botCommandsBotUserIdCommandUnique: uniqueIndex("bot_commands_bot_user_id_command_unique").on(
      table.botUserId,
      table.command,
    ),
  }),
)

export const botCommandsRelations = relations(botCommands, ({ one }) => ({
  botUser: one(users, {
    fields: [botCommands.botUserId],
    references: [users.id],
  }),
}))

export type DbBotCommand = typeof botCommands.$inferSelect
export type DbNewBotCommand = typeof botCommands.$inferInsert
