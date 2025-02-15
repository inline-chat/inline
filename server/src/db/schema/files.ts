import { doublePrecision, pgTable } from "drizzle-orm/pg-core"
import { users } from "./users"
import { text } from "drizzle-orm/pg-core"
import { integer } from "drizzle-orm/pg-core"
import { bytea, creationDate } from "@in/server/db/schema/common"
import type { AnyPgColumn } from "drizzle-orm/pg-core"
import { serial } from "drizzle-orm/pg-core"
import { relations } from "drizzle-orm"

export const files = pgTable("files", {
  id: serial("id").primaryKey(), // Internal synthetic id

  // Unqiue file id (generated and exposed to client)
  fileUniqueId: text("file_unique_id").unique().notNull(),

  // What path we give to file to store on s3. For files with only bytes set this is null
  pathEncrypted: bytea("path_encrypted"),
  pathIv: bytea("path_iv"),
  pathTag: bytea("path_tag"),

  // File original name
  nameEncrypted: bytea("name_encrypted"),
  nameIv: bytea("name_iv"),
  nameTag: bytea("name_tag"),

  // For all file types
  fileSize: integer("file_size"),
  mimeType: text("mime_type"), // not null?
  fileType: text("file_type", { enum: ["photo", "video", "document", "audio"] }),

  // Photo, video specific
  width: integer("width"),
  height: integer("height"),

  // For embedded photos (eg. "h" size class)
  bytesEncrypted: bytea("bytes_encrypted"),
  bytesIv: bytea("bytes_iv"),
  bytesTag: bytea("bytes_tag"),

  // Thumbnails
  thumbSize: text("thumb_size", { enum: ["i", "s", "m", "h"] }),
  thumbFor: integer("thumb_for").references((): AnyPgColumn => files.id),

  // Video specific
  videoDuration: doublePrecision("video_duration"),

  // Internal
  cdn: integer("cdn").default(1),

  /** required, uploaded by */
  userId: integer("user_id")
    .notNull()
    .references(() => users.id),

  date: creationDate,
})

export const filesRelations = relations(files, ({ many, one }) => ({
  thumbs: many(files, {
    relationName: "thumbFor",
  }),

  thumbFor: one(files, {
    relationName: "thumbFor",
    fields: [files.thumbFor],
    references: [files.id],
  }),
}))

export type DbFile = typeof files.$inferSelect
export type DbNewFile = typeof files.$inferInsert
