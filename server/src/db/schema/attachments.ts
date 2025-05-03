import { bytea, creationDate } from "@in/server/db/schema/common"
import { files } from "@in/server/db/schema/files"
import { messages } from "@in/server/db/schema/messages"
import { users } from "@in/server/db/schema/users"
import { relations } from "drizzle-orm"
import { pgTable, serial, integer, text, bigint, varchar, pgEnum, numeric } from "drizzle-orm/pg-core"
import { photos } from "./media"

export const urlPreview = pgTable("url_preview", {
  id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),

  url: bytea("url"),
  urlIv: bytea("url_iv"),
  urlTag: bytea("url_tag"),

  siteName: text("site_name"),

  title: bytea("title"),
  titleIv: bytea("title_iv"),
  titleTag: bytea("title_tag"),

  description: bytea("description"),
  descriptionIv: bytea("description_iv"),
  descriptionTag: bytea("description_tag"),

  photoId: bigint("photo_id", { mode: "number" }).references(() => photos.id),

  duration: integer("duration"),
  date: creationDate,
})

export const externalTasks = pgTable("external_tasks", {
  id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),
  application: text("application").notNull(),
  taskId: text("task_id").notNull(),
  status: text("status", { enum: ["backlog", "todo", "in_progress", "done", "cancelled"] }).notNull(),
  assignedUserId: bigint("assigned_user_id", { mode: "bigint" }).references(() => users.id),
  number: text("number"),
  url: text("url"),

  /** title of the task (encrypted) */
  title: bytea("title"),
  titleIv: bytea("title_iv"),
  titleTag: bytea("title_tag"),

  date: creationDate,
})

export const messageAttachments = pgTable("message_attachments", {
  id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),
  messageId: bigint("message_id", { mode: "bigint" }).references(() => messages.globalId),

  /** external task id */
  externalTaskId: bigint("external_task_id", { mode: "bigint" }).references(() => externalTasks.id),
  urlPreviewId: bigint("url_preview_id", { mode: "bigint" }).references(() => urlPreview.id),
})

export const messageAttachmentsRelations = relations(messageAttachments, ({ one }) => ({
  externalTask: one(externalTasks, {
    fields: [messageAttachments.externalTaskId],
    references: [externalTasks.id],
  }),

  linkEmbed: one(urlPreview, {
    fields: [messageAttachments.urlPreviewId],
    references: [urlPreview.id],
  }),

  message: one(messages, {
    fields: [messageAttachments.messageId],
    references: [messages.globalId],
  }),
}))

export type DbMessageAttachment = typeof messageAttachments.$inferSelect
export type DbNewMessageAttachment = typeof messageAttachments.$inferInsert

export type DbExternalTask = typeof externalTasks.$inferSelect
export type DbNewExternalTask = typeof externalTasks.$inferInsert

export type DbLinkEmbed = typeof urlPreview.$inferSelect
export type DbNewLinkEmbed = typeof urlPreview.$inferInsert
