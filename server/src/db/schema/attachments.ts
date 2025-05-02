import { bytea, creationDate } from "@in/server/db/schema/common"
import { files } from "@in/server/db/schema/files"
import { messages } from "@in/server/db/schema/messages"
import { users } from "@in/server/db/schema/users"
import { relations } from "drizzle-orm"
import { pgTable, serial, integer, text, bigint, varchar, pgEnum, numeric } from "drizzle-orm/pg-core"




export const linkEmbed_experimental = pgTable("link_embed_experimental", {
  id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),
  url: text("url").notNull(),
  providerName: text("provider_name"),
  title: text("title"),
  description: text("description"),
  imageUrl: varchar("image_url", { length: 2_048 }),
  imageWidth: integer("image_width"),
  imageHeight: integer("image_height"),
  html: text("html"),
  date: creationDate,
  duration: numeric("duration", {precision: 10, scale: 3}),
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
  linkEmbedId: bigint("link_embed_id", {mode:"bigint" }).references(() => linkEmbed_experimental.id)


})

export const messageAttachmentsRelations = relations(messageAttachments, ({ one }) => ({
  externalTask: one(externalTasks, {
    fields: [messageAttachments.externalTaskId],
    references: [externalTasks.id],
  }),

  linkEmbed: one(linkEmbed_experimental, {
    fields: [messageAttachments.linkEmbedId],
    references: [linkEmbed_experimental.id],
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

  export type DbLinkEmbed = typeof linkEmbed_experimental.$inferSelect
  export type DbNewLinkEmbed = typeof linkEmbed_experimental.$inferInsert

