import { pgTable, integer, serial, uniqueIndex } from "drizzle-orm/pg-core"
import { relations } from "drizzle-orm/_relations"
import { bytea, creationDate } from "@in/server/db/schema/common"
import { users } from "@in/server/db/schema/users"
import { sessions } from "@in/server/db/schema/sessions"

export const botTokens = pgTable(
  "bot_tokens",
  {
    id: serial("id").primaryKey(),

    botUserId: integer("bot_user_id")
      .notNull()
      .references(() => users.id),

    sessionId: integer("session_id")
      .notNull()
      .references(() => sessions.id),

    tokenEncrypted: bytea("token_encrypted").notNull(),
    tokenIv: bytea("token_iv").notNull(),
    tokenTag: bytea("token_tag").notNull(),

    date: creationDate,
  },
  (table) => ({
    botTokensBotUserIdUnique: uniqueIndex("bot_tokens_bot_user_id_unique").on(table.botUserId),
  }),
)

export const botTokensRelations = relations(botTokens, ({ one }) => ({
  botUser: one(users, {
    fields: [botTokens.botUserId],
    references: [users.id],
  }),
  session: one(sessions, {
    fields: [botTokens.sessionId],
    references: [sessions.id],
  }),
}))

export type DbBotToken = typeof botTokens.$inferSelect
export type DbNewBotToken = typeof botTokens.$inferInsert
