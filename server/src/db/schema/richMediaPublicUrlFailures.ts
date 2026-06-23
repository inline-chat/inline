import { bytea, creationDate } from "@in/server/db/schema/common"
import { bigint, index, integer, pgTable, text, timestamp, uniqueIndex } from "drizzle-orm/pg-core"

export const richMediaPublicUrlFailures = pgTable(
  "rich_media_public_url_failures",
  {
    id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),
    kind: text("kind", { enum: ["photo", "video", "document", "voice"] }).notNull(),
    urlHash: bytea("url_hash").notNull(),
    urlHost: text("url_host"),
    failureCount: integer("failure_count").notNull().default(1),
    lastError: text("last_error"),
    lastFailedAt: timestamp("last_failed_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    retryAfter: timestamp("retry_after", { mode: "date", precision: 3 }).notNull(),
    updatedAt: timestamp("updated_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    date: creationDate,
  },
  (table) => ({
    kindUrlHashUnique: uniqueIndex("rich_media_public_url_failures_kind_url_hash_unique").on(table.kind, table.urlHash),
    retryAfterIndex: index("rich_media_public_url_failures_retry_after_idx").on(table.retryAfter),
    urlHostIndex: index("rich_media_public_url_failures_url_host_idx").on(table.urlHost),
  }),
)

export type DbRichMediaPublicUrlFailure = typeof richMediaPublicUrlFailures.$inferSelect
export type DbNewRichMediaPublicUrlFailure = typeof richMediaPublicUrlFailures.$inferInsert
