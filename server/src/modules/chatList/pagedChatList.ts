import type { Transaction } from "@in/server/db/types"
import { getEffectiveChatAccessUserIds } from "@in/server/modules/authorization/chatAccessProjection"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import {
  ChatListKind,
  ChatListOrder,
  ChatListScope,
  type ChatListOffset,
  type GetChatsInput,
  type GetCommonChatsInput,
} from "@inline-chat/protocol/core"
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

export function nextOffsetFor(request: Pick<ChatListRequest, "order">, last: ChatListRow): ChatListOffset {
  return request.order === "recent"
    ? { chatId: BigInt(last.chatId), date: last.activity }
    : { chatId: BigInt(last.chatId) }
}

export const COMMON_CHATS_DEFAULT_LIMIT = 30

/** A validated GetCommonChats request, always in RECENT order. */
export type CommonChatsRequest = {
  targetUserId: number
  limit: number
  /** Exclusive start, with its activity date. */
  offset?: ChatListRequest["offset"]
}

/** Throws a bad request for an invalid target, the viewer themself, or a bad page. */
export function parseCommonChatsRequest(input: Partial<GetCommonChatsInput>, viewerUserId: number): CommonChatsRequest {
  const targetUserId = toDbId(input.userId ?? 0n, "user_id")
  if (targetUserId === viewerUserId) throw badRequest("user_id must be another user")
  const limit = input.limit ?? COMMON_CHATS_DEFAULT_LIMIT
  if (!Number.isInteger(limit) || limit < 1) throw badRequest("limit must be at least 1")
  return {
    targetUserId,
    limit: Math.min(limit, CHAT_LIST_MAX_LIMIT),
    offset: input.offset ? parseOffset(input.offset, "recent") : undefined,
  }
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

/** Page through candidate chats. The caller checks current membership before returning them. */
function discoverySql(
  userId: number,
  request: ChatListRequest,
  params: { after: ChatListRequest["offset"]; limit: number },
): SQL {
  const conditions = filterSql(userId, request.filter)
  const cursor = cursorSql(request.order, params.after)
  if (cursor) conditions.push(cursor)

  let prefix = sql``
  let source: SQL
  if (request.scope === "dialogs") {
    source = sql`dialogs d join chats c on c.id = d.chat_id`
    conditions.unshift(sql`d.user_id = ${userId}`, sql`d.chat_list_hidden is not true`)
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

/**
 * Top-level, non-public threads where both users hold an explicit grant: a
 * participant row or a group grant through one of their groups. Public threads
 * are left out by design. Discovery only: the access projection decides.
 */
function commonChatsDiscoverySql(
  viewerUserId: number,
  targetUserId: number,
  params: { after: CommonChatsRequest["offset"]; limit: number },
): SQL {
  const grants = (userId: number) => sql`
    select cp.chat_id from chat_participants cp where cp.user_id = ${userId}
    union
    select cpg.chat_id
    from user_group_members ugm
    join chat_participant_groups cpg on cpg.group_id = ugm.group_id
    where ugm.user_id = ${userId}`
  const cursor = cursorSql("recent", params.after)
  return sql`
    with target_grants as (${grants(targetUserId)}),
    viewer_grants as (${grants(viewerUserId)})
    select c.id as "chatId", ${activityKey} as "activity"
    from target_grants t
    join viewer_grants v on v.chat_id = t.chat_id
    join chats c on c.id = t.chat_id
    where c.type = 'thread'
      and c.parent_chat_id is null
      and c.public_thread is distinct from true
      ${cursor ? sql`and ${cursor}` : sql``}
    order by ${activityKey} desc, c.id desc
    limit ${params.limit}
    /*application='inline-server',operation='common_chats'*/
  `
}

type RawRow = { chatId: number; activity: string | number | bigint }
const toRow = (row: RawRow): ChatListRow => ({ chatId: Number(row.chatId), activity: BigInt(row.activity) })

/**
 * Reads candidate batches in list order until `wanted` rows pass `allowed` or
 * candidates run out, so filtering never shortens a page.
 */
async function collectAuthorizedRows(
  tx: Transaction,
  params: {
    wanted: number
    after: ChatListRequest["offset"]
    discover: (after: ChatListRequest["offset"], limit: number) => SQL
    allowed: (chatIds: number[]) => Promise<(chatId: number) => boolean>
  },
): Promise<ChatListRow[]> {
  const accepted: ChatListRow[] = []
  let after = params.after
  const batchSize = Math.max(params.wanted, FALLBACK_BATCH_SIZE)
  for (;;) {
    const batch = (await tx.execute<RawRow>(params.discover(after, batchSize))).map(toRow)
    if (batch.length === 0) return accepted
    const isAllowed = await params.allowed(batch.map((row) => row.chatId))
    for (const row of batch) {
      if (!isAllowed(row.chatId)) continue
      accepted.push(row)
      if (accepted.length === params.wanted) return accepted
    }
    if (batch.length < batchSize) return accepted
    const last = batch[batch.length - 1]!
    after = { chatId: last.chatId, date: last.activity }
  }
}

/**
 * Up to `limit + 1` authorized rows in list order; more than `limit` means the
 * list continues. Read-only: never creates dialogs.
 */
export async function discoverChatListPage(tx: Transaction, userId: number, request: ChatListRequest): Promise<ChatListRow[]> {
  return collectAuthorizedRows(tx, {
    wanted: request.limit + 1,
    after: request.offset,
    discover: (after, limit) => discoverySql(userId, request, { after, limit }),
    allowed: async (chatIds) => {
      const access = await getEffectiveChatAccessUserIds(tx, chatIds, {
        userIds: [userId],
        source: "chats.list",
        committed: true,
      })
      return (chatId) => access.get(chatId)?.has(userId) === true
    },
  })
}

/**
 * Up to `limit + 1` threads both users can currently access, latest activity
 * first. More than `limit` means the list continues.
 */
export async function discoverCommonChatsPage(
  tx: Transaction,
  viewerUserId: number,
  request: CommonChatsRequest,
): Promise<ChatListRow[]> {
  const { targetUserId } = request
  return collectAuthorizedRows(tx, {
    wanted: request.limit + 1,
    after: request.offset,
    discover: (after, limit) => commonChatsDiscoverySql(viewerUserId, targetUserId, { after, limit }),
    allowed: async (chatIds) => {
      const access = await getEffectiveChatAccessUserIds(tx, chatIds, {
        userIds: [viewerUserId, targetUserId],
        source: "chats.common",
        committed: true,
      })
      return (chatId) => {
        const users = access.get(chatId)
        return users?.has(viewerUserId) === true && users.has(targetUserId)
      }
    },
  })
}
