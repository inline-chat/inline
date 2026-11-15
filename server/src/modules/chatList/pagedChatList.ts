import type { Transaction } from "@in/server/db/types"
import { getEffectiveChatAccessUserIds } from "@in/server/modules/authorization/chatAccessProjection"
import { isStoredChatAccessTrusted } from "@in/server/modules/authorization/chatAccessTrust"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { ChatListKind, ChatListOrder, ChatListScope, type ChatListOffset, type GetChatsInput } from "@inline-chat/protocol/core"
import { sql, type SQL } from "drizzle-orm"

export const CHAT_LIST_MAX_LIMIT = 100
const MAX_DB_ID = 2_147_483_647n
/** Rows read per statement when access is checked through the projection. */
const FALLBACK_BATCH_SIZE = 250

type Kind = "dm" | "spaceThread" | "homeThread"

/** A validated paged GetChats request. */
export type ChatListRequest = {
  limit: number
  scope: "dialogs" | "accessible"
  order: "recent" | "id"
  /** Exclusive start. `date` is set in RECENT order. */
  offset?: { chatId: number; date?: bigint }
  filter: {
    kinds: ReadonlySet<Kind>
    spaceIds: number[]
    unread?: boolean
    archived?: boolean
    open?: boolean
    pinned?: boolean
    folderId?: number
  }
}

/** One listed chat and its sort key: activity date in Unix seconds. */
export type ChatListRow = { chatId: number; activity: bigint }

const badRequest = (reason: string) => RealtimeRpcError.BadRequestWithReason(reason)

function toDbId(value: bigint, field: string): number {
  if (value <= 0n || value > MAX_DB_ID) throw badRequest(`${field} must be a positive ID`)
  return Number(value)
}

const kindByProto: ReadonlyMap<ChatListKind, Kind> = new Map([
  [ChatListKind.DM, "dm"],
  [ChatListKind.SPACE_THREAD, "spaceThread"],
  [ChatListKind.HOME_THREAD, "homeThread"],
])

/** Validates a paged request (`limit` present). Throws a bad request with a reason. */
export function parseChatListRequest(input: Partial<GetChatsInput>): ChatListRequest {
  const limit = input.limit
  if (limit === undefined) throw new Error("parseChatListRequest needs a paged request")
  if (!Number.isInteger(limit) || limit < 1) throw badRequest("limit must be at least 1")

  let scope: ChatListRequest["scope"]
  const scopeValue = input.scope ?? ChatListScope.DIALOGS
  if (input.includeSubthreads === true || scopeValue === ChatListScope.ACCESSIBLE) scope = "accessible"
  else if (scopeValue === ChatListScope.DIALOGS) scope = "dialogs"
  else throw badRequest("unknown scope")

  let order: ChatListRequest["order"]
  const orderValue = input.order ?? ChatListOrder.RECENT
  if (orderValue === ChatListOrder.RECENT) order = "recent"
  else if (orderValue === ChatListOrder.ID) order = "id"
  else throw badRequest("unknown order")

  const filter = input.filter
  if (filter?.query !== undefined && filter.query.trim() !== "") {
    throw badRequest("filter.query is not supported yet")
  }
  const kinds = new Set<Kind>()
  for (const value of filter?.kinds ?? []) {
    const kind = kindByProto.get(value)
    if (!kind) throw badRequest("unknown chat kind")
    kinds.add(kind)
  }

  return {
    limit: Math.min(limit, CHAT_LIST_MAX_LIMIT),
    scope,
    order,
    offset: input.offset ? parseOffset(input.offset, order) : undefined,
    filter: {
      kinds,
      spaceIds: [...new Set((filter?.spaceIds ?? []).map((id) => toDbId(id, "space_ids")))],
      unread: filter?.unread,
      archived: filter?.archived,
      open: filter?.open,
      pinned: filter?.pinned,
      folderId: filter?.folderId === undefined ? undefined : toDbId(filter.folderId, "folder_id"),
    },
  }
}

function parseOffset(offset: ChatListOffset, order: ChatListRequest["order"]): ChatListRequest["offset"] {
  const chatId = toDbId(offset.chatId, "offset.chat_id")
  if (order === "id") return { chatId }
  if (offset.date === undefined) throw badRequest("offset.date is required in RECENT order")
  return { chatId, date: offset.date }
}

export function nextOffsetFor(request: ChatListRequest, last: ChatListRow): ChatListOffset {
  return request.order === "recent"
    ? { chatId: BigInt(last.chatId), date: last.activity }
    : { chatId: BigInt(last.chatId) }
}

/**
 * Every chat the user can reach through a root they belong to, and its linked
 * descendants. Discovery only: the access projection decides what is returned.
 */
export function completeCatalogCte(userId: number): SQL {
  return sql`
    seeds as (
      select c.id
      from chats c
      where c.parent_chat_id is null
        and (
          (c.type = 'private' and (c.min_user_id = ${userId} or c.max_user_id = ${userId}))
          or (c.type = 'thread' and exists (
            select 1 from members m
            where m.space_id = c.space_id and m.user_id = ${userId}
          ))
        )

      union

      select cp.chat_id
      from chat_participants cp
      join chats c on c.id = cp.chat_id
      where cp.user_id = ${userId} and c.type = 'thread'

      union

      select cpg.chat_id
      from chat_participant_groups cpg
      join user_group_members ugm on ugm.group_id = cpg.group_id
      join chats c on c.id = cpg.chat_id
      where ugm.user_id = ${userId} and c.type = 'thread'
    ), catalog as (
      select id from seeds

      union

      select child.id from chats child join catalog parent on child.parent_chat_id = parent.id
      where child.type = 'thread'
    )`
}

// Unix seconds, so the cursor round-trips exactly through ChatListOffset.date.
const activityKey = sql`floor(extract(epoch from coalesce(c.last_message_date, c.date)))::bigint`

function filterSql(userId: number, filter: ChatListRequest["filter"]): SQL[] {
  const conditions: SQL[] = []
  if (filter.kinds.size > 0) {
    const kinds: SQL[] = []
    if (filter.kinds.has("dm")) kinds.push(sql`c.type = 'private'`)
    if (filter.kinds.has("spaceThread")) kinds.push(sql`(c.type = 'thread' and c.space_id is not null)`)
    if (filter.kinds.has("homeThread")) kinds.push(sql`(c.type = 'thread' and c.space_id is null)`)
    conditions.push(sql`(${sql.join(kinds, sql` or `)})`)
  }
  if (filter.spaceIds.length > 0) {
    conditions.push(sql`(c.space_id is null or c.space_id in (${sql.join(filter.spaceIds, sql`, `)}))`)
  }
  if (filter.unread !== undefined) {
    // Same messages getBatchUnreadCounts counts, stopping at the first; the
    // last_msg_id guard skips the probe for dialogs read to the end.
    const unread = sql`coalesce(d.id is not null and (
      d.unread_mark is true
      or (c.last_msg_id > coalesce(d.read_inbox_max_id, 0) and exists (
        select 1 from messages m
        where m.chat_id = c.id
          and m.message_id > coalesce(d.read_inbox_max_id, 0)
          and m.from_id <> ${userId}
          and m.counts_as_unread is true
          and m.system_message_encrypted is null
      ))
    ), false)`
    conditions.push(filter.unread ? unread : sql`not ${unread}`)
  }
  const dialogFlag = (column: SQL, value: boolean | undefined) => {
    if (value !== undefined) conditions.push(value ? sql`${column} is true` : sql`${column} is not true`)
  }
  dialogFlag(sql`d.archived`, filter.archived)
  dialogFlag(sql`d.open`, filter.open)
  dialogFlag(sql`d.pinned`, filter.pinned)
  if (filter.folderId !== undefined) conditions.push(sql`d.folder_id = ${filter.folderId}`)
  return conditions
}

function cursorSql(order: ChatListRequest["order"], after: ChatListRequest["offset"]): SQL | null {
  if (!after) return null
  if (order === "id") return sql`c.id > ${after.chatId}`
  return sql`(${activityKey}, c.id) < (${after.date!}, ${after.chatId})`
}

/**
 * One statement: scope, filter and cursor, ordered, `limit` rows. With
 * `requireStoredAccess` the statement also requires a `chat_access` row;
 * otherwise the caller must authorize the rows itself.
 */
function discoverySql(
  userId: number,
  request: ChatListRequest,
  params: { after: ChatListRequest["offset"]; limit: number; requireStoredAccess: boolean },
): SQL {
  const conditions = filterSql(userId, request.filter)
  const cursor = cursorSql(request.order, params.after)
  if (cursor) conditions.push(cursor)

  let prefix = sql``
  let source: SQL
  if (request.scope === "dialogs") {
    source = params.requireStoredAccess
      ? sql`dialogs d
        join chats c on c.id = d.chat_id
        join chat_access a on a.chat_id = d.chat_id and a.user_id = d.user_id`
      : sql`dialogs d join chats c on c.id = d.chat_id`
    conditions.unshift(sql`d.user_id = ${userId}`, sql`d.chat_list_hidden is not true`)
  } else if (params.requireStoredAccess) {
    source = sql`chat_access a
      join chats c on c.id = a.chat_id
      left join dialogs d on d.chat_id = a.chat_id and d.user_id = a.user_id`
    conditions.unshift(sql`a.user_id = ${userId}`)
  } else {
    prefix = sql`with recursive ${completeCatalogCte(userId)}`
    source = sql`catalog k
      join chats c on c.id = k.id
      left join dialogs d on d.chat_id = c.id and d.user_id = ${userId}`
  }

  const orderBy = request.order === "id" ? sql`c.id asc` : sql`${activityKey} desc, c.id desc`
  const where = conditions.length > 0 ? sql`where ${sql.join(conditions, sql` and `)}` : sql``
  return sql`
    ${prefix}
    select c.id as "chatId", ${activityKey} as "activity"
    from ${source}
    ${where}
    order by ${orderBy}
    limit ${params.limit}
    /*application='inline-server',operation='chat_list',scope='${sql.raw(request.scope)}',order='${sql.raw(request.order)}'*/
  `
}

type RawRow = { chatId: number; activity: string | number | bigint }
const toRow = (row: RawRow): ChatListRow => ({ chatId: Number(row.chatId), activity: BigInt(row.activity) })

/**
 * Up to `limit + 1` authorized rows in list order; more than `limit` means the
 * list continues. Read-only: never creates dialogs.
 */
export async function discoverChatListPage(tx: Transaction, userId: number, request: ChatListRequest): Promise<ChatListRow[]> {
  const wanted = request.limit + 1
  if (isStoredChatAccessTrusted()) {
    const rows = await tx.execute<RawRow>(discoverySql(userId, request, {
      after: request.offset, limit: wanted, requireStoredAccess: true,
    }))
    return rows.map(toRow)
  }

  // The table is not trusted: read in batches and authorize each through the
  // projection until the page plus one look-ahead row is full.
  const accepted: ChatListRow[] = []
  let after = request.offset
  const batchSize = Math.max(wanted, FALLBACK_BATCH_SIZE)
  for (;;) {
    const batch = (await tx.execute<RawRow>(discoverySql(userId, request, {
      after, limit: batchSize, requireStoredAccess: false,
    }))).map(toRow)
    if (batch.length === 0) return accepted
    const access = await getEffectiveChatAccessUserIds(tx, batch.map((row) => row.chatId), {
      userIds: [userId],
      source: "chats.list",
      committed: true,
    })
    for (const row of batch) {
      if (access.get(row.chatId)?.has(userId) !== true) continue
      accepted.push(row)
      if (accepted.length === wanted) return accepted
    }
    if (batch.length < batchSize) return accepted
    const last = batch[batch.length - 1]!
    after = { chatId: last.chatId, date: last.activity }
  }
}
