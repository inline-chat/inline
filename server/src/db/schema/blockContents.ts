import { bytea } from "@in/server/db/schema/common"
import { photos } from "@in/server/db/schema/media"
import { sql } from "drizzle-orm"
import { relations } from "drizzle-orm/_relations"
import {
  bigint,
  check,
  index,
  integer,
  pgTable,
  smallint,
  timestamp,
  varchar,
} from "drizzle-orm/pg-core"

const createdAt = () =>
  timestamp("created_at", { mode: "date", precision: 3, withTimezone: true }).defaultNow().notNull()
const updatedAt = () =>
  timestamp("updated_at", { mode: "date", precision: 3, withTimezone: true }).defaultNow().notNull()

export const blockContents = pgTable("block_contents", {
  id: bigint("id", { mode: "bigint" }).primaryKey().generatedAlwaysAsIdentity(),
  payloadEncrypted: bytea("payload_encrypted").notNull(),
  payloadIv: bytea("payload_iv").notNull(),
  payloadTag: bytea("payload_tag").notNull(),
  schemaVersion: smallint("schema_version").default(1).notNull(),
  revision: integer("revision").default(0).notNull(),
  createdAt: createdAt(),
  updatedAt: updatedAt(),
})

export const blockContentImageJobs = pgTable(
  "block_content_image_jobs",
  {
    id: bigint("id", { mode: "bigint" }).primaryKey().generatedAlwaysAsIdentity(),
    contentId: bigint("content_id", { mode: "bigint" })
      .notNull()
      .references(() => blockContents.id, { onDelete: "cascade" }),
    expectedRevision: integer("expected_revision").notNull(),
    blockPath: integer("block_path").array().notNull(),
    sourceHash: bytea("source_hash").notNull(),
    hashVersion: smallint("hash_version").notNull().default(0),
    sourceEncrypted: bytea("source_encrypted").notNull(),
    sourceIv: bytea("source_iv").notNull(),
    sourceTag: bytea("source_tag").notNull(),
    state: varchar("state", { length: 16 }).default("pending").notNull(),
    attempts: smallint("attempts").default(0).notNull(),
    availableAt: timestamp("available_at", { mode: "date", precision: 3, withTimezone: true }).defaultNow().notNull(),
    leaseToken: varchar("lease_token", { length: 64 }),
    leaseUntil: timestamp("lease_until", { mode: "date", precision: 3, withTimezone: true }),
    stagedObjectPathEncrypted: bytea("staged_object_path_encrypted"),
    stagedObjectPathIv: bytea("staged_object_path_iv"),
    stagedObjectPathTag: bytea("staged_object_path_tag"),
    photoId: bigint("photo_id", { mode: "number" }).references(() => photos.id, { onDelete: "set null" }),
    lastErrorCode: varchar("last_error_code", { length: 64 }),
    createdAt: createdAt(),
    updatedAt: updatedAt(),
  },
  (table) => ({
    readyIndex: index("block_content_image_jobs_ready_idx").on(table.state, table.availableAt, table.id),
    revisionIndex: index("block_content_image_jobs_revision_idx").on(table.contentId, table.expectedRevision),
    pathIndex: index("block_content_image_jobs_path_idx").on(table.contentId, table.blockPath),
    stateCheck: check(
      "block_content_image_jobs_state_check",
      sql`${table.state} in ('pending', 'processing', 'ready', 'failed', 'canceled')`,
    ),
    attemptsCheck: check("block_content_image_jobs_attempts_check", sql`${table.attempts} >= 0`),
  }),
)

export const blockContentRelations = relations(blockContents, ({ many }) => ({
  imageJobs: many(blockContentImageJobs),
}))

export const blockContentImageJobRelations = relations(blockContentImageJobs, ({ one }) => ({
  content: one(blockContents, {
    fields: [blockContentImageJobs.contentId],
    references: [blockContents.id],
  }),
  photo: one(photos, {
    fields: [blockContentImageJobs.photoId],
    references: [photos.id],
  }),
}))

export type DbBlockContent = typeof blockContents.$inferSelect
export type DbNewBlockContent = typeof blockContents.$inferInsert
export type DbBlockContentImageJob = typeof blockContentImageJobs.$inferSelect
export type DbNewBlockContentImageJob = typeof blockContentImageJobs.$inferInsert
