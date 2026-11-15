import { db } from "@in/server/db"
import { UpdateBucket, chatParticipants, chats, dialogs, members, spaces, updates, users } from "@in/server/db/schema"
import { and, desc, eq, inArray, sql } from "drizzle-orm"
import { captureUpdateDiscoveryWatermark } from "@in/server/modules/updates/updateDiscoveryBarrier"
import { getUpdatesState } from "@in/server/functions/updates.getUpdatesState"
import type { RepairDiscovery, RepairDiscoveryRequest, RepairDiscoverySnapshot } from "./repairDiscovery"
import { Log } from "@in/server/utils/log"

export const REPAIR_FRONTIER_BATCH_SIZE = 512
const log = new Log("internalMessaging.repairDiscovery")

/** A conservative prefilter, never authorization. A false positive costs a
 * normal scan; a false negative loses recovery. Cover the entire catalog used
 * by ChatModel.getUserChats: DMs, Home participants, space threads (including group grants), and
 * dialog-backed linked threads. Include all space members deliberately, even
 * those without chat access. The normal discovery path rechecks authority.
 * SQL returns at most one ID per requested user, irrespective of chat count.
 */
async function findChangedResourceUsers(requests: readonly RepairDiscoveryRequest[], watermark: Date): Promise<Set<number>> {
  const changed = new Set<number>()
  const horizon = BigInt(Math.floor(watermark.getTime() / 1000)) - CHANGE_DRIVEN_HORIZON_SECONDS
  for (let offset = 0; offset < requests.length; offset += REPAIR_FRONTIER_BATCH_SIZE) {
    const batch = requests.slice(offset, offset + REPAIR_FRONTIER_BATCH_SIZE)
    const recent = batch.filter(({ date }) => date >= horizon)
    const stale = batch.filter(({ date }) => date < horizon)
    const queries = [
      ...(recent.length > 0 ? [recentChangedUsersQuery(recent)] : []),
      ...(stale.length > 0 ? [staleChangedUsersQuery(stale)] : []),
    ]
    for (const query of queries) {
      for (const row of await db.execute<{ userId: number }>(query)) {
        if (!Number.isSafeInteger(row.userId) || row.userId <= 0) throw new Error("Invalid discovery candidate")
        changed.add(row.userId)
      }
    }
  }
  return changed
}

/** Requests older than this, relative to the discovery watermark, use the
 * membership-driven query, so one long-offline reconnect cannot widen the
 * changed-chat scan for every other user in its batch. */
const CHANGE_DRIVEN_HORIZON_SECONDS = 3600n

const discoveryTag = (path: "recent" | "stale") =>
  sql.raw(`/*application='inline-server',operation='repair_discovery',source='repair.discovery',path='${path}'*/`)

// Schema timestamps store UTC without a time zone. Explicit conversion keeps
// these comparisons independent of the PostgreSQL session time zone.
const utcTimestamp = (date: bigint) => sql`(to_timestamp(${date.toString()}::double precision) at time zone 'UTC')`
const requestedValues = (batch: readonly RepairDiscoveryRequest[]) =>
  sql.join(batch.map(({ userId, date }) => sql`(${userId}::integer, ${utcTimestamp(date)})`), sql`, `)

/** Change-driven: cost scales with chats changed since the batch's oldest
 * checkpoint, not with account size. Each branch maps a changed chat back to
 * requested users through the same relationship as the stale query, then
 * re-applies that user's own checkpoint. The floor is a bound parameter (not
 * a subquery) so custom plans see it and range-scan chats_last_update_date_idx.
 * Spaces have no recency index and a user has few member spaces, so the
 * space branch stays membership-driven. */
function recentChangedUsersQuery(batch: readonly RepairDiscoveryRequest[]) {
  const floor = batch.reduce((min, { date }) => (date < min ? date : min), batch[0]!.date)
  return sql`
    with requested(user_id, since) as materialized (values ${requestedValues(batch)}),
    changed_chats as materialized (
      select ${chats.id} as id, ${chats.spaceId} as space_id, ${chats.minUserId} as min_user_id,
        ${chats.maxUserId} as max_user_id, ${chats.lastUpdateDate} as changed_at
      from ${chats} where ${chats.lastUpdateDate} >= ${utcTimestamp(floor)}
    ),
    changed_space_chats as (
      select space_id, max(changed_at) as changed_at from changed_chats
      where space_id is not null group by space_id
    )
    select r.user_id as "userId" from changed_chats c
    inner join requested r on r.user_id = c.min_user_id
    where c.changed_at >= r.since
    union
    select r.user_id from changed_chats c
    inner join requested r on r.user_id = c.max_user_id
    where c.changed_at >= r.since
    union
    select r.user_id from changed_chats c
    inner join ${chatParticipants} on ${chatParticipants.chatId} = c.id
    inner join requested r on r.user_id = ${chatParticipants.userId}
    where c.space_id is null and c.changed_at >= r.since
    union
    select r.user_id from changed_space_chats c
    inner join ${members} on ${members.spaceId} = c.space_id
    inner join requested r on r.user_id = ${members.userId}
    where c.changed_at >= r.since
    union
    select r.user_id from changed_chats c
    inner join ${dialogs} on ${dialogs.chatId} = c.id
    inner join requested r on r.user_id = ${dialogs.userId}
    where c.changed_at >= r.since
    union
    select r.user_id from requested r
    inner join ${members} on ${members.userId} = r.user_id
    inner join ${spaces} on ${spaces.id} = ${members.spaceId}
    where ${spaces.lastUpdateDate} >= r.since
    ${discoveryTag("recent")}
  `
}

/** Membership-driven: walks each user's whole catalog. Only used for
 * checkpoints older than the horizon, where the changed set can be large. */
function staleChangedUsersQuery(batch: readonly RepairDiscoveryRequest[]) {
  return sql`
    with requested(user_id, since) as (values ${requestedValues(batch)})
    select r.user_id as "userId" from requested r
    inner join ${chats} on ${chats.minUserId} = r.user_id
    where ${chats.lastUpdateDate} >= r.since
    union
    select r.user_id from requested r
    inner join ${chats} on ${chats.maxUserId} = r.user_id
    where ${chats.lastUpdateDate} >= r.since
    union
    select r.user_id from requested r
    inner join ${chatParticipants} on ${chatParticipants.userId} = r.user_id
    inner join ${chats} on ${chats.id} = ${chatParticipants.chatId}
    where ${chats.spaceId} is null and ${chats.lastUpdateDate} >= r.since
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
    ${discoveryTag("stale")}
  `
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
    const changed = await findChangedResourceUsers(unique, watermark)
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
