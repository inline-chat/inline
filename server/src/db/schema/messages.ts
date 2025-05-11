import { bigint, boolean, pgTable, timestamp, unique } from "drizzle-orm/pg-core"
import { users } from "./users"
import { text } from "drizzle-orm/pg-core"
import { chats } from "./chats"
import { bigserial } from "drizzle-orm/pg-core"
import { integer } from "drizzle-orm/pg-core"
import { index } from "drizzle-orm/pg-core"
import { bytea, creationDate } from "@in/server/db/schema/common"
import type { AnyPgColumn } from "drizzle-orm/pg-core"
import { relations } from "drizzle-orm"
import { reactions } from "./reactions"
import { files } from "@in/server/db/schema/files"
import { documents, photos, videos } from "@in/server/db/schema/media"
import { messageAttachments } from "./attachments"
import { translations } from "@in/server/db/schema/translations"

export const messages = pgTable(
  "messages",
  {
    globalId: bigserial("global_id", { mode: "bigint" }).primaryKey(),

    // sequencial within one chat
    messageId: integer("message_id").notNull(),

    // random id, used for optimistic update and deduplication
    randomId: bigint("random_id", { mode: "bigint" }),

    /** message raw text, optional */
    text: text(), // @deprecated
    textEncrypted: bytea("text_encrypted"),
    textIv: bytea("text_iv"),
    textTag: bytea("text_tag"),

    /** required, chat it belongs to */
    chatId: integer("chat_id")
      .notNull()
      .references((): AnyPgColumn => chats.id, {
        onDelete: "cascade",
      }),

    /** required, chat it belongs to */
    fromId: integer("from_id")
      .notNull()
      .references(() => users.id),

    /** when it was edited. if null indicated it hasn't been edited */
    editDate: timestamp("edit_date", { mode: "date", precision: 3 }),

    date: creationDate,

    /** optional, message it is replying to */
    replyToMsgId: integer("reply_to_msg_id"),

    /** if this message is part of a grouped message */
    groupedId: bigint("grouped_id", { mode: "bigint" }),

    /** media id, photo, video, document, etc */
    mediaType: text("media_type", { enum: ["photo", "video", "document"] }),
    photoId: bigint("photo_id", { mode: "number" }).references(() => photos.id),
    videoId: bigint("video_id", { mode: "number" }).references(() => videos.id),
    documentId: bigint("document_id", { mode: "number" }).references(() => documents.id),

    // --------------------------------------------------------
    // Deprecated fields
    // --------------------------------------------------------
    fileId: integer("file_id").references(() => files.id),

    /** if this message is a sticker */
    isSticker: boolean("is_sticker").default(false),
  },
  (table) => ({
    messageIdPerChatUnique: unique("msg_id_per_chat_unique").on(table.messageId, table.chatId),
    messageIdPerChatIndex: index("msg_id_per_chat_index").on(table.messageId, table.chatId),
    randomIdPerSenderIndex: unique("random_id_per_sender_unique").on(table.randomId, table.fromId),
    unreadCountIndex: index("unread_count_index").on(table.chatId, table.messageId, table.fromId),
  }),
)

export const messageRelations = relations(messages, ({ one, many }) => ({
  from: one(users, { fields: [messages.fromId], references: [users.id] }),
  file: one(files, { fields: [messages.fileId], references: [files.id] }),
  reactions: many(reactions),

  photo: one(photos, { fields: [messages.photoId], references: [photos.id] }),
  video: one(videos, { fields: [messages.videoId], references: [videos.id] }),
  document: one(documents, { fields: [messages.documentId], references: [documents.id] }),
  messageAttachments: many(messageAttachments),

  translations: many(translations),
}))

export type DbMessage = typeof messages.$inferSelect
export type DbNewMessage = typeof messages.$inferInsert
