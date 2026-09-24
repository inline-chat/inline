import { db } from "@in/server/db"
import { UpdateBucket, updates, users } from "@in/server/db/schema"
import { and, desc, eq, inArray, sql } from "drizzle-orm"

export const REPAIR_FRONTIER_BATCH_SIZE = 512

/**
 * Read after the sweep's discovery fence. Each user's sequence is monotonic;
 * changes committed after this snapshot are found by the next inclusive sweep
 * or its broker hint. Keep the legacy counter/history reconciliation used by
 * getUpdatesState, including when an older writer's cached counter lags.
 */
export async function loadRepairUserFrontiers(userIds: readonly number[]): Promise<Map<number, number>> {
  const result = new Map<number, number>()
  const ids = [...new Set(userIds)]
  // Keep the correlated query in its own builder. Drizzle strips table
  // qualifiers from raw column chunks in a single-table SELECT projection;
  // an inline SQL fragment would compare entity_id with updates.id instead
  // of the outer users.id.
  const latestRetainedSequence = db.select({ seq: updates.seq })
    .from(updates)
    .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, users.id)))
    .orderBy(desc(updates.seq))
    .limit(1)
  for (let offset = 0; offset < ids.length; offset += REPAIR_FRONTIER_BATCH_SIZE) {
    const rows = await db.select({
      userId: users.id,
      seq: sql<number>`greatest(coalesce(${users.updateSeq}, 0), coalesce((${latestRetainedSequence}), 0))`.mapWith(Number),
    }).from(users).where(inArray(users.id, ids.slice(offset, offset + REPAIR_FRONTIER_BATCH_SIZE)))
    for (const row of rows) result.set(row.userId, row.seq)
  }
  return result
}
