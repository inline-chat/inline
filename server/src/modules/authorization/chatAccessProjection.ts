import type { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { sql } from "drizzle-orm"

type ChatAccessRow = {
  chatId: number
  userId: number
}

export type ChatAccessMap = Map<number, Set<number>>

/**
 * The projection is used both inside a mutation transaction and by realtime
 * fanout after that transaction commits. It only needs a query executor; the
 * caller chooses the consistency boundary appropriate to its operation.
 */
export type ChatAccessQuery = Pick<typeof db, "execute">

type ChatIdRow = { chatId: number }

/**
 * Durable user access events are limited to independent/top-level chats.
 * Subthreads are discoverable through their parent and do not fan out access
 * transitions to every parent participant.
 */
export async function getRootChatIdsForAccessEvents(
  tx: Transaction,
  chatIds: number[],
): Promise<number[]> {
  const ids = uniquePositiveIds(chatIds)
  if (ids.length === 0) return []
  const chatIdList = sql.join(ids, sql`, `)
  const rows = await tx.execute<ChatIdRow>(sql`
    select c.id as "chatId"
    from chats c
    where c.id in (${chatIdList}) and c.parent_chat_id is null
    order by c.id
  `)
  return rows.map((row) => row.chatId)
}

export async function getSpaceRootChatIdsForAccessEvents(
  tx: Transaction,
  spaceId: number,
): Promise<number[]> {
  if (!Number.isSafeInteger(spaceId) || spaceId <= 0) return []
  const rows = await tx.execute<ChatIdRow>(sql`
    select c.id as "chatId"
    from chats c
    where c.space_id = ${spaceId} and c.parent_chat_id is null
    order by c.id
  `)
  return rows.map((row) => row.chatId)
}

/**
 * Computes the effective users who can discover each chat from the caller's
 * database snapshot. This mirrors AccessGuards:
 * an explicit grant on the target wins only within current owning-Space
 * authority; otherwise a child inherits from its root chat. Retained participant
 * rows never preserve access after Space departure or soft deletion.
 */
export async function getEffectiveChatAccessUserIds(
  tx: ChatAccessQuery,
  chatIds: number[],
  options?: { userIds?: number[] },
): Promise<ChatAccessMap> {
  const ids = uniquePositiveIds(chatIds)
  const result: ChatAccessMap = new Map(ids.map((chatId) => [chatId, new Set<number>()]))
  if (ids.length === 0) return result

  const constrainedUserIds = options?.userIds === undefined ? undefined : uniquePositiveIds(options.userIds)
  if (constrainedUserIds?.length === 0) return result

  const chatIdList = sql.join(ids, sql`, `)
  const userFilter = constrainedUserIds === undefined
    ? sql``
    : sql`and access."userId" in (${sql.join(constrainedUserIds, sql`, `)})`
  const rows = await tx.execute<ChatAccessRow>(sql`
    with recursive ancestors as (
      select
        c.id as "chatId",
        c.id as "ancestorId",
        c.parent_chat_id as "parentChatId",
        0::int as depth
      from chats c
      where c.id in (${chatIdList})

      union all

      select
        ancestors."chatId",
        parent.id as "ancestorId",
        parent.parent_chat_id as "parentChatId",
        ancestors.depth + 1
      from ancestors
      join chats parent on parent.id = ancestors."parentChatId"
    ),
    roots as (
      select distinct on ("chatId")
        "chatId",
        "ancestorId" as "rootChatId"
      from ancestors
      order by "chatId", depth desc
    ),
    access as (
      select cp.chat_id as "chatId", cp.user_id as "userId"
      from chat_participants cp
      where cp.chat_id in (${chatIdList})

      union

      select cpg.chat_id as "chatId", ugm.user_id as "userId"
      from chat_participant_groups cpg
      join user_groups ug on ug.id = cpg.group_id
      join user_group_members ugm on ugm.group_id = ug.id
      join members m on m.space_id = ug.space_id and m.user_id = ugm.user_id
      where cpg.chat_id in (${chatIdList})

      union

      select r."chatId", root.min_user_id as "userId"
      from roots r
      join chats root on root.id = r."rootChatId"
      where root.type = 'private' and root.min_user_id is not null

      union

      select r."chatId", root.max_user_id as "userId"
      from roots r
      join chats root on root.id = r."rootChatId"
      where root.type = 'private' and root.max_user_id is not null

      union

      select r."chatId", m.user_id as "userId"
      from roots r
      join chats root on root.id = r."rootChatId"
      join members m on m.space_id = root.space_id
      where root.type = 'thread'
        and root.space_id is not null
        and root.public_thread is true
        and m.can_access_public_chats is distinct from false

      union

      select r."chatId", cp.user_id as "userId"
      from roots r
      join chats root on root.id = r."rootChatId"
      join chat_participants cp on cp.chat_id = root.id
      left join members m on m.space_id = root.space_id and m.user_id = cp.user_id
      where root.type = 'thread'
        and root.public_thread is distinct from true
        and (root.space_id is null or m.user_id is not null)

      union

      select r."chatId", ugm.user_id as "userId"
      from roots r
      join chats root on root.id = r."rootChatId"
      join chat_participant_groups cpg on cpg.chat_id = root.id
      join user_groups ug on ug.id = cpg.group_id
      join user_group_members ugm on ugm.group_id = ug.id
      join members m on m.space_id = ug.space_id and m.user_id = ugm.user_id
      where root.type = 'thread' and root.public_thread is distinct from true
    )
    select distinct access."chatId", access."userId"
    from access
    join users u on u.id = access."userId"
    where u.deleted is distinct from true
      and not exists (
        select 1
        from ancestors a
        join chats owning_chat on owning_chat.id = a."ancestorId"
        where a."chatId" = access."chatId"
          and owning_chat.space_id is not null
          and not exists (
            select 1
            from members owning_member
            join spaces owning_space on owning_space.id = owning_member.space_id
            where owning_member.space_id = owning_chat.space_id
              and owning_member.user_id = access."userId"
              and owning_space.deleted is null
          )
      )
      ${userFilter}
    order by access."chatId", access."userId"
  `)

  for (const row of rows) {
    result.get(row.chatId)?.add(row.userId)
  }
  return result
}

export function addedAccessUserIds(chatId: number, before: ChatAccessMap, after: ChatAccessMap): number[] {
  const oldIds = before.get(chatId) ?? new Set<number>()
  return Array.from(after.get(chatId) ?? []).filter((userId) => !oldIds.has(userId))
}

export function removedAccessUserIds(chatId: number, before: ChatAccessMap, after: ChatAccessMap): number[] {
  const newIds = after.get(chatId) ?? new Set<number>()
  return Array.from(before.get(chatId) ?? []).filter((userId) => !newIds.has(userId))
}

function uniquePositiveIds(ids: number[]): number[] {
  return Array.from(new Set(ids.filter((id) => Number.isSafeInteger(id) && id > 0)))
}
