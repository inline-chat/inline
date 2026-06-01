import { bytea, creationDate } from "@in/server/db/schema/common"
import { messages } from "@in/server/db/schema/messages"
import { users } from "@in/server/db/schema/users"
import { relations } from "drizzle-orm/_relations"
import { pgTable, integer, text, bigint, index, timestamp, uniqueIndex, boolean } from "drizzle-orm/pg-core"
import { documents, photos, videos } from "./media"

export const urlPreviewCache = pgTable(
  "url_preview_cache",
  {
    id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),

    urlHash: bytea("url_hash").notNull(),
    url: bytea("url").notNull(),
    urlIv: bytea("url_iv").notNull(),
    urlTag: bytea("url_tag").notNull(),

    finalUrl: bytea("final_url"),
    finalUrlIv: bytea("final_url_iv"),
    finalUrlTag: bytea("final_url_tag"),

    provider: text("provider").notNull().default("generic"),
    siteName: text("site_name"),
    mediaType: text("media_type", { enum: ["article", "image", "video", "document", "embed"] }),

    title: bytea("title"),
    titleIv: bytea("title_iv"),
    titleTag: bytea("title_tag"),

    description: bytea("description"),
    descriptionIv: bytea("description_iv"),
    descriptionTag: bytea("description_tag"),

    author: bytea("author"),
    authorIv: bytea("author_iv"),
    authorTag: bytea("author_tag"),

    imageUrlHash: bytea("image_url_hash"),
    imageUrl: bytea("image_url"),
    imageUrlIv: bytea("image_url_iv"),
    imageUrlTag: bytea("image_url_tag"),

    mediaKind: text("media_kind", { enum: ["photo", "video", "document", "external_video", "embed"] }),
    photoId: bigint("photo_id", { mode: "number" }).references(() => photos.id),
    videoId: bigint("video_id", { mode: "number" }).references(() => videos.id),
    documentId: bigint("document_id", { mode: "number" }).references(() => documents.id),

    externalUrl: bytea("external_url"),
    externalUrlIv: bytea("external_url_iv"),
    externalUrlTag: bytea("external_url_tag"),
    externalMimeType: text("external_mime_type"),
    externalWidth: integer("external_width"),
    externalHeight: integer("external_height"),
    externalDuration: integer("external_duration"),

    embedUrl: bytea("embed_url"),
    embedUrlIv: bytea("embed_url_iv"),
    embedUrlTag: bytea("embed_url_tag"),
    embedType: text("embed_type"),
    embedWidth: integer("embed_width"),
    embedHeight: integer("embed_height"),
    embedDuration: integer("embed_duration"),

    hasLargeMedia: boolean("has_large_media"),
    showLargeMedia: boolean("show_large_media"),

    duration: integer("duration"),
    fetchedAt: timestamp("fetched_at", { mode: "date", precision: 3 }).notNull(),
    lastUsedAt: timestamp("last_used_at", { mode: "date", precision: 3 }).notNull(),
    expiresAt: timestamp("expires_at", { mode: "date", precision: 3 }).notNull(),
    createdAt: timestamp("created_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    updatedAt: timestamp("updated_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
  },
  (table) => ({
    urlHashUnique: uniqueIndex("url_preview_cache_url_hash_unique").on(table.urlHash),
    imageUrlHashIndex: index("url_preview_cache_image_url_hash_idx").on(table.imageUrlHash),
    expiresAtIndex: index("url_preview_cache_expires_at_idx").on(table.expiresAt),
    lastUsedAtIndex: index("url_preview_cache_last_used_at_idx").on(table.lastUsedAt),
  }),
)

export const urlPreview = pgTable("url_preview", {
  id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),

  url: bytea("url"),
  urlIv: bytea("url_iv"),
  urlTag: bytea("url_tag"),

  siteName: text("site_name"),
  provider: text("provider").notNull().default("generic"),
  mediaType: text("media_type", { enum: ["article", "image", "video", "document", "embed"] }),

  title: bytea("title"),
  titleIv: bytea("title_iv"),
  titleTag: bytea("title_tag"),

  description: bytea("description"),
  descriptionIv: bytea("description_iv"),
  descriptionTag: bytea("description_tag"),

  author: bytea("author"),
  authorIv: bytea("author_iv"),
  authorTag: bytea("author_tag"),

  mediaKind: text("media_kind", { enum: ["photo", "video", "document", "external_video", "embed"] }),
  photoId: bigint("photo_id", { mode: "number" }).references(() => photos.id),
  videoId: bigint("video_id", { mode: "number" }).references(() => videos.id),
  documentId: bigint("document_id", { mode: "number" }).references(() => documents.id),
  cacheId: bigint("cache_id", { mode: "number" }).references(() => urlPreviewCache.id),

  externalUrl: bytea("external_url"),
  externalUrlIv: bytea("external_url_iv"),
  externalUrlTag: bytea("external_url_tag"),
  externalMimeType: text("external_mime_type"),
  externalWidth: integer("external_width"),
  externalHeight: integer("external_height"),
  externalDuration: integer("external_duration"),

  embedUrl: bytea("embed_url"),
  embedUrlIv: bytea("embed_url_iv"),
  embedUrlTag: bytea("embed_url_tag"),
  embedType: text("embed_type"),
  embedWidth: integer("embed_width"),
  embedHeight: integer("embed_height"),
  embedDuration: integer("embed_duration"),

  hasLargeMedia: boolean("has_large_media"),
  showLargeMedia: boolean("show_large_media"),

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

export const messageAttachments = pgTable(
  "message_attachments",
  {
    id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),
    messageId: bigint("message_id", { mode: "bigint" }).references(() => messages.globalId, { onDelete: "cascade" }),

    /** external task id */
    externalTaskId: bigint("external_task_id", { mode: "bigint" }).references(() => externalTasks.id),
    urlPreviewId: bigint("url_preview_id", { mode: "bigint" }).references(() => urlPreview.id),
  },
  (table) => ({
    messageIdIndex: index("message_attachments_message_id_idx").on(table.messageId),
  }),
)

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

export const urlPreviewRelations = relations(urlPreview, ({ one }) => ({
  photo: one(photos, {
    fields: [urlPreview.photoId],
    references: [photos.id],
  }),

  video: one(videos, {
    fields: [urlPreview.videoId],
    references: [videos.id],
  }),

  document: one(documents, {
    fields: [urlPreview.documentId],
    references: [documents.id],
  }),

  cache: one(urlPreviewCache, {
    fields: [urlPreview.cacheId],
    references: [urlPreviewCache.id],
  }),
}))

export const urlPreviewCacheRelations = relations(urlPreviewCache, ({ one }) => ({
  photo: one(photos, {
    fields: [urlPreviewCache.photoId],
    references: [photos.id],
  }),

  video: one(videos, {
    fields: [urlPreviewCache.videoId],
    references: [videos.id],
  }),

  document: one(documents, {
    fields: [urlPreviewCache.documentId],
    references: [documents.id],
  }),
}))

export type DbMessageAttachment = typeof messageAttachments.$inferSelect
export type DbNewMessageAttachment = typeof messageAttachments.$inferInsert

export type DbExternalTask = typeof externalTasks.$inferSelect
export type DbNewExternalTask = typeof externalTasks.$inferInsert

export type DbLinkEmbed = typeof urlPreview.$inferSelect
export type DbNewLinkEmbed = typeof urlPreview.$inferInsert

export type DbUrlPreviewCache = typeof urlPreviewCache.$inferSelect
export type DbNewUrlPreviewCache = typeof urlPreviewCache.$inferInsert
