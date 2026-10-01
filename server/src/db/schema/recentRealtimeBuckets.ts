import { sql } from "drizzle-orm"
import { check, index, integer, pgTable, primaryKey, timestamp } from "drizzle-orm/pg-core"

/** Temporary discovery metadata, never message history or delivery acknowledgements. */
export const recentRealtimeBuckets = pgTable("recent_realtime_buckets", {
  bucket: integer("bucket").notNull(),
  entityId: integer("entity_id").notNull(),
  seq: integer("seq").notNull(),
  expiresAt: timestamp("expires_at", { mode: "date", withTimezone: true, precision: 3 }).notNull(),
}, (table) => [
  primaryKey({ columns: [table.bucket, table.entityId] }),
  index("recent_realtime_buckets_expiry_idx").on(table.expiresAt),
  check("recent_realtime_buckets_bucket_valid", sql`${table.bucket} in (1, 2, 3)`),
  check("recent_realtime_buckets_entity_positive", sql`${table.entityId} > 0`),
  check("recent_realtime_buckets_seq_positive", sql`${table.seq} > 0`),
])

export type RecentRealtimeBucket = typeof recentRealtimeBuckets.$inferSelect
