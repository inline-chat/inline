import { bytea, creationDate } from "@in/server/db/schema/common"
import { relations } from "drizzle-orm"
import { pgTable, integer, text, bigint } from "drizzle-orm/pg-core"
import { photos } from "./media"
import { messages } from "@in/server/db/schema/messages"
import { chats } from "@in/server/db/schema/chats"

export const translations = pgTable("message_translations", {
  id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),
  date: creationDate,

  messageId: bigint("message_id", { mode: "number" })
    .references(() => messages.messageId)
    .notNull(),
  chatId: bigint("chat_id", { mode: "number" })
    .references(() => chats.id)
    .notNull(),

  // Encrypted translation text
  translation: bytea("translation"),
  translationIv: bytea("translation_iv"),
  translationTag: bytea("translation_tag"),

  // Language code (e.g. "en", "es", "fr")
  language: text("language").notNull(),
})

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
