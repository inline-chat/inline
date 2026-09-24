import { db } from "@in/server/db"
import { UpdateBucket, chats, dialogs, members, spaces, updates, users } from "@in/server/db/schema"
import { and, desc, eq, inArray, sql } from "drizzle-orm"
import { captureUpdateDiscoveryWatermark } from "@in/server/modules/updates/updateDiscoveryBarrier"
import { getUpdatesState } from "@in/server/functions/updates.getUpdatesState"
import type { RepairDiscovery, RepairDiscoveryRequest, RepairDiscoverySnapshot } from "./repairDiscovery"
import { Log } from "@in/server/utils/log"

export const REPAIR_FRONTIER_BATCH_SIZE = 512
const log = new Log("internalMessaging.repairDiscovery")

/** A conservative prefilter, never authorization. A false positive costs a
 * normal scan; a false negative loses recovery. Cover the entire catalog used
 * by ChatModel.getUserChats: DMs, space threads (including group grants), and
 * dialog-backed linked threads. Include all space members deliberately, even
 * those without chat access. The normal discovery path rechecks authority.
 * SQL returns at most one ID per requested user, irrespective of chat count.
 */
async function findChangedResourceUsers(requests: readonly RepairDiscoveryRequest[]): Promise<Set<number>> {
  const changed = new Set<number>()
  for (let offset = 0; offset < requests.length; offset += REPAIR_FRONTIER_BATCH_SIZE) {
    const batch = requests.slice(offset, offset + REPAIR_FRONTIER_BATCH_SIZE)
    // Schema timestamps store UTC without a time zone. Explicit conversion
    // keeps this comparison independent of the PostgreSQL session time zone.
    const values = sql.join(batch.map(({ userId, date }) =>
      sql`(${userId}::integer, to_timestamp(${date.toString()}::double precision) at time zone 'UTC')`), sql`, `)
    const rows = await db.execute<{ userId: number }>(sql`
      with requested(user_id, since) as (values ${values})
      select r.user_id as "userId" from requested r
      inner join ${chats} on ${chats.minUserId} = r.user_id
      where ${chats.lastUpdateDate} >= r.since
      union
      select r.user_id from requested r
      inner join ${chats} on ${chats.maxUserId} = r.user_id
      where ${chats.lastUpdateDate} >= r.since
      union
      select r.user_id from requested r
      inner join ${members} on ${members.userId} = r.user_id
      inner join ${chats} on ${chats.spaceId} = ${members.spaceId}
      where ${chats.lastUpdateDate} >= r.since
      union
      select r.user_id from requested r
      inner join ${dialogs} on ${dialogs.userId} = r.user_id
      inner join ${chats} on ${chats.id} = ${dialogs.chatId}
      where ${chats.lastUpdateDate} >= r.since
      union
      select r.user_id from requested r
      inner join ${members} on ${members.userId} = r.user_id
      inner join ${spaces} on ${spaces.id} = ${members.spaceId}
      where ${spaces.lastUpdateDate} >= r.since
    `)
    for (const row of rows) {
      if (!Number.isSafeInteger(row.userId) || row.userId <= 0) throw new Error("Invalid discovery candidate")
      changed.add(row.userId)
    }
  }
  return changed
}

export const postgresRepairDiscovery: RepairDiscovery = {
  captureWatermark: captureUpdateDiscoveryWatermark,
  async prepare(requests, watermark) {
    const startedAt = performance.now()
    if (!Number.isFinite(watermark.getTime())) throw new Error("Invalid discovery watermark")
    const byUser = new Map<number, RepairDiscoveryRequest>()
    for (const request of requests) {
      if (!Number.isSafeInteger(request.userId) || request.userId <= 0 || request.date < 0n) {
        throw new Error("Invalid repair discovery request")
      }
      const previous = byUser.get(request.userId)
      if (!previous || request.date < previous.date) byUser.set(request.userId, request)
    }
    const unique = [...byUser.values()]
    const frontiers = await loadRepairUserFrontiers([...byUser.keys()])
    const changed = await findChangedResourceUsers(unique)
    const timing = {
      users: unique.length, resourceCandidates: changed.size,
      batches: Math.ceil(unique.length / REPAIR_FRONTIER_BATCH_SIZE),
      durationMs: Math.round(performance.now() - startedAt),
    }
    if (timing.durationMs >= 500) log.warn("Repair discovery preparation is slow", timing)
    else log.debug("Repair discovery preparation", timing)
    return new Map(unique.map(({ userId, date }) => [userId, {
      watermark,
      userFrontier: frontiers.get(userId),
      resourcesUnchangedSince: changed.has(userId) ? undefined : date,
    } satisfies RepairDiscoverySnapshot]))
  },
  async discover({ userId, date }, { snapshot, shouldEmitHints }) {
    const checkpoint = snapshot && BigInt(Math.floor(snapshot.watermark.getTime() / 1000))
    const usable = checkpoint !== undefined && date <= checkpoint ? snapshot : undefined
    if (usable?.userFrontier !== undefined && usable.resourcesUnchangedSince !== undefined &&
      date >= usable.resourcesUnchangedSince) {
      // User-bucket hint/replay still runs in the scheduler, even with no
      // resource changes. Only complete negative results skip discovery.
      return { date: checkpoint, seq: usable.userFrontier, updatesFound: false }
    }
    // Resolve inside the call to preserve the existing circular import order.
    return getUpdatesState({ date }, { currentUserId: userId, currentSessionId: 0 }, {
      shouldEmitHints,
      discoveryWatermark: usable?.watermark,
      userFrontier: usable?.userFrontier,
    })
  },
}

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
