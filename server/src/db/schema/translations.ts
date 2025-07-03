import { bytea, creationDate } from "@in/server/db/schema/common"
import { relations } from "drizzle-orm/_relations"
import { pgTable, integer, text, bigint, unique, foreignKey } from "drizzle-orm/pg-core"
import { photos } from "./media"
import { messages } from "@in/server/db/schema/messages"
import { chats } from "@in/server/db/schema/chats"

export const translations = pgTable(
  "message_translations",
  {
    id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),
    date: creationDate,

    messageId: bigint("message_id", { mode: "number" }).notNull(),
    chatId: bigint("chat_id", { mode: "number" })
      .references(() => chats.id)
      .notNull(),

    // Encrypted translation text
    translation: bytea("translation"),
    translationIv: bytea("translation_iv"),
    translationTag: bytea("translation_tag"),

    /** encrypted entities */
    entities: bytea("entities"),

    // Language code (e.g. "en", "es", "fr")
    language: text("language").notNull(),
  },
  (t) => ({
    /** Ensure chatId and messageId are valid */
    chatIdMessageIdForeignKey: foreignKey({
      name: "chat_id_message_id_fk",
      columns: [t.chatId, t.messageId],
      foreignColumns: [messages.chatId, messages.messageId],
    }),
  }),
)

export const translationsRelations = relations(translations, ({ one }) => ({
  message: one(messages, {
    fields: [translations.chatId, translations.messageId],
    references: [messages.chatId, messages.messageId],
  }),

  chat: one(chats, {
    fields: [translations.chatId],
    references: [chats.id],
  }),
}))

export type DbTranslation = typeof translations.$inferSelect
export type DbNewTranslation = typeof translations.$inferInsert
