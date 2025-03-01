import { bytea, creationDate } from "@in/server/db/schema/common"
import { files } from "@in/server/db/schema/files"
import { messages } from "@in/server/db/schema/messages"
import { pgTable, serial, integer, text, bigint } from "drizzle-orm/pg-core"

// export const messageMedia = pgTable("message_media", {
//   id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),
//   messageId: bigint("message_id", { mode: "bigint" }).references(() => messages.globalId),
//   mediaType: text("media_type", { enum: ["photo", "video", "document"] }),

//   // one of the following
//   photoId: bigint("photo_id", { mode: "bigint" }).references(() => photos.id),
//   videoId: bigint("video_id", { mode: "bigint" }).references(() => videos.id),
//   documentId: bigint("document_id", { mode: "bigint" }).references(() => documents.id),
// })

export const photos = pgTable("photos", {
  id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),
  format: text("format", { enum: ["jpeg", "png"] }).notNull(),
  width: integer("width"),
  height: integer("height"),

  /** stripped photo */
  stripped: bytea("stripped"),
  strippedIv: bytea("stripped_iv"),
  strippedTag: bytea("stripped_tag"),

  date: creationDate,
})

export const photoSizes = pgTable("photo_sizes", {
  id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),
  fileId: integer("file_id").references(() => files.id),
  photoId: bigint("photo_id", { mode: "bigint" }).references(() => photos.id),
  size: text("size", { enum: ["b", "c", "d", "e", "f", "y", "x", "w", "v"] }),
  width: integer("width"),
  height: integer("height"),
})

export const documents = pgTable("documents", {
  id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),
  fileId: integer("file_id").references(() => files.id),
  date: creationDate,

  // file name (encrypted)
  fileName: bytea("file_name"),
  fileNameIv: bytea("file_name_iv"),
  fileNameTag: bytea("file_name_tag"),

  // for thumbnails for uncompressed photos and videos
  photoId: bigint("photo_id", { mode: "bigint" }).references(() => photos.id),
})

export const videos = pgTable("videos", {
  id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),
  fileId: integer("file_id").references(() => files.id),
  date: creationDate,

  width: integer("width"),
  height: integer("height"),
  duration: integer("duration"),

  // thumbnail for the video
  photoId: bigint("photo_id", { mode: "bigint" }).references(() => photos.id),
})
