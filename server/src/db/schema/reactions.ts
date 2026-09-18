import { bytea } from "./common"
import { encryptedText } from "./encrypted"
import { foreignKey, pgTable, unique, type AnyPgColumn } from "drizzle-orm/pg-core"
import { users } from "./users"
import { chats } from "./chats"
import { integer } from "drizzle-orm/pg-core"
import { messages } from "./messages"
import { relations } from "drizzle-orm/_relations"
import { creationDate } from "./common"

export const reactions = pgTable(
  "reactions",
  {
    id: integer().primaryKey().generatedAlwaysAsIdentity(),

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
    emoji: encryptedText("emoji", "reactions.emoji").notNull(),
    emojiHash: bytea("emoji_hash"),
    date: creationDate,
  },
  (table) => ({
    uniqueEncryptedReaction: unique("reactions_identity_emoji_hash_unique").on(
      table.chatId, table.messageId, table.userId, table.emojiHash,
    ),
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
