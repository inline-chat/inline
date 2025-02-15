import { bigint, foreignKey, index, pgTable, serial, timestamp, unique, type AnyPgColumn } from "drizzle-orm/pg-core"
import { users } from "./users"
import { text } from "drizzle-orm/pg-core"
import { chats } from "./chats"
import { bigserial } from "drizzle-orm/pg-core"
import { integer } from "drizzle-orm/pg-core"
import { messages } from "./messages"
import { relations } from "drizzle-orm"
import { creationDate } from "./common"

export const reactions = pgTable(
  "reactions",
  {
    id: serial().primaryKey(),

    messageId: integer("message_id").notNull(),
    chatId: integer("chat_id")
      .notNull()
      .references((): AnyPgColumn => chats.id, {
        onDelete: "cascade",
      }),
    userId: integer("user_id")
      .notNull()
      .references((): AnyPgColumn => users.id, {
        onDelete: "cascade",
      }),
    emoji: text("emoji").notNull(),
    date: creationDate,
  },
  (table) => ({
    uniqueReactionPerEmoji: unique("unique_reaction_per_emoji").on(
      table.chatId,
      table.messageId,
      table.userId,
      table.emoji,
    ),

    messageIdForeignKey: foreignKey({
      name: "message_id_fk",
      columns: [table.chatId, table.messageId],
      foreignColumns: [messages.chatId, messages.messageId],
    }).onDelete("cascade"),
  }),
)

export const reactionRelations = relations(reactions, ({ one }) => ({
  message: one(messages, {
    fields: [reactions.chatId, reactions.messageId],
    references: [messages.chatId, messages.messageId],
  }),
}))

export type DbReaction = typeof reactions.$inferSelect
export type DbNewReaction = typeof reactions.$inferInsert
