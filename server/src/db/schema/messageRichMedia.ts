import { bytea } from "@in/server/db/schema/common"
import { chats } from "@in/server/db/schema/chats"
import { documents, photos, videos, voices } from "@in/server/db/schema/media"
import { messages } from "@in/server/db/schema/messages"
import { relations } from "drizzle-orm/_relations"
import { bigint, index, integer, pgTable, text, timestamp } from "drizzle-orm/pg-core"

export const messageRichMedia = pgTable(
  "message_rich_media",
  {
    id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),
    messageGlobalId: bigint("message_global_id", { mode: "bigint" })
      .notNull()
      .references(() => messages.globalId, { onDelete: "cascade" }),
    chatId: integer("chat_id")
      .notNull()
      .references(() => chats.id, { onDelete: "cascade" }),
    messageId: integer("message_id").notNull(),

    blockId: text("block_id").notNull(),
    blockPath: text("block_path").notNull(),
    sortOrder: integer("sort_order").notNull(),
    kind: text("kind", { enum: ["photo", "video", "document", "voice", "public_url"] }).notNull(),
    status: text("status", { enum: ["resolved", "pending", "failed"] }).notNull().default("resolved"),

    photoId: bigint("photo_id", { mode: "number" }).references(() => photos.id),
    videoId: bigint("video_id", { mode: "number" }).references(() => videos.id),
    documentId: bigint("document_id", { mode: "number" }).references(() => documents.id),
    voiceId: bigint("voice_id", { mode: "number" }).references(() => voices.id),

    publicUrlHash: bytea("public_url_hash"),
    publicUrl: bytea("public_url"),
    publicUrlIv: bytea("public_url_iv"),
    publicUrlTag: bytea("public_url_tag"),
    error: text("error"),

    createdAt: timestamp("created_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    updatedAt: timestamp("updated_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
  },
  (table) => ({
    messageIndex: index("message_rich_media_message_idx").on(table.messageGlobalId, table.sortOrder),
    chatMessageIndex: index("message_rich_media_chat_message_idx").on(table.chatId, table.messageId),
    photoIndex: index("message_rich_media_photo_idx").on(table.photoId),
    videoIndex: index("message_rich_media_video_idx").on(table.videoId),
    documentIndex: index("message_rich_media_document_idx").on(table.documentId),
    voiceIndex: index("message_rich_media_voice_idx").on(table.voiceId),
    publicUrlHashIndex: index("message_rich_media_public_url_hash_idx").on(table.publicUrlHash),
  }),
)

export const messageRichMediaRelations = relations(messageRichMedia, ({ one }) => ({
  message: one(messages, {
    fields: [messageRichMedia.messageGlobalId],
    references: [messages.globalId],
  }),
  chat: one(chats, {
    fields: [messageRichMedia.chatId],
    references: [chats.id],
  }),
  photo: one(photos, {
    fields: [messageRichMedia.photoId],
    references: [photos.id],
  }),
  video: one(videos, {
    fields: [messageRichMedia.videoId],
    references: [videos.id],
  }),
  document: one(documents, {
    fields: [messageRichMedia.documentId],
    references: [documents.id],
  }),
  voice: one(voices, {
    fields: [messageRichMedia.voiceId],
    references: [voices.id],
  }),
}))

export type DbMessageRichMedia = typeof messageRichMedia.$inferSelect
export type DbNewMessageRichMedia = typeof messageRichMedia.$inferInsert
