import { db } from "@in/server/db"
import { recentRealtimeBuckets, type RecentRealtimeBucket } from "@in/server/db/schema/recentRealtimeBuckets"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { Transaction } from "@in/server/db/types"
import { and, asc, gt, sql } from "drizzle-orm"

export const RECENT_REALTIME_BUCKET_TTL_MS = 5 * 60_000
export const MAX_RECENT_REALTIME_BUCKET_PAGE_SIZE = 256

export type RecentRealtimeBucketCursor = Pick<RecentRealtimeBucket, "bucket" | "entityId">
type RecordedBucket = RecentRealtimeBucketCursor & { seq: number }

const assertPositiveInteger = (value: number): void => {
  if (!Number.isInteger(value) || value <= 0 || value > 2_147_483_647) {
    throw new Error("Invalid recent realtime bucket integer")
  }
}

const assertCursor = ({ bucket, entityId }: RecentRealtimeBucketCursor): void => {
  if (bucket !== UpdateBucket.Chat && bucket !== UpdateBucket.User && bucket !== UpdateBucket.Space) {
    throw new Error("Invalid recent realtime bucket kind")
  }
  assertPositiveInteger(entityId)
}

const pageSize = (limit: number = MAX_RECENT_REALTIME_BUCKET_PAGE_SIZE): number => {
  if (!Number.isInteger(limit) || limit < 1 || limit > MAX_RECENT_REALTIME_BUCKET_PAGE_SIZE) {
    throw new Error("Recent realtime bucket page size must be between 1 and 256")
  }
  return limit
}

/**
 * Every gateway scans this small recent-activity index independently. Neither
 * the key order nor expiry is a commit cursor: complete fair cycles are required,
 * and a gap longer than the TTL needs authoritative client reconciliation.
 */
export const RecentRealtimeBuckets = {
  async record(tx: Transaction, input: RecordedBucket): Promise<void> {
    assertCursor(input)
    assertPositiveInteger(input.seq)
    const expiry = sql`clock_timestamp() + ${RECENT_REALTIME_BUCKET_TTL_MS} * interval '1 millisecond'`
    await tx.insert(recentRealtimeBuckets).values({ ...input, expiresAt: expiry })
      .onConflictDoUpdate({
        target: [recentRealtimeBuckets.bucket, recentRealtimeBuckets.entityId],
        set: { seq: input.seq, expiresAt: expiry },
        // Stale publishers and duplicate registration cannot regress the
        // frontier or keep an inactive bucket alive forever.
        setWhere: gt(sql`excluded.seq`, recentRealtimeBuckets.seq),
      })
  },

  async readPage(input: { after?: RecentRealtimeBucketCursor; limit?: number } = {}): Promise<RecentRealtimeBucket[]> {
    const limit = pageSize(input.limit)
    if (input.after) assertCursor(input.after)
    return db.select().from(recentRealtimeBuckets).where(and(
      gt(recentRealtimeBuckets.expiresAt, sql`statement_timestamp()`),
      input.after === undefined ? undefined : sql`(${recentRealtimeBuckets.bucket}, ${recentRealtimeBuckets.entityId}) > (${input.after.bucket}, ${input.after.entityId})`,
    )).orderBy(asc(recentRealtimeBuckets.bucket), asc(recentRealtimeBuckets.entityId)).limit(limit)
  },

  /** One short statement; never wait for an active mutation's bucket lock. */
  async cleanupExpired(limit?: number): Promise<number> {
    const batchSize = pageSize(limit)
    const rows = await db.execute<{ bucket: number }>(sql`
      with expired as (
        select bucket, entity_id from ${recentRealtimeBuckets}
        where expires_at <= statement_timestamp()
        order by expires_at, bucket, entity_id
        limit ${batchSize}
        for update skip locked
      )
      delete from ${recentRealtimeBuckets} as recent
      using expired
      where recent.bucket = expired.bucket and recent.entity_id = expired.entity_id
      returning recent.bucket
    `)
    return rows.length
  },
}
