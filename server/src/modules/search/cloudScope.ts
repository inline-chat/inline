import { and, eq, sql, type SQL } from "drizzle-orm"
import { SearchMessagesFilter, type SearchMessagesGlobalInput } from "@inline-chat/protocol/core"
import { chats } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { getEffectiveChatAccessUserIds } from "@in/server/modules/authorization/chatAccessProjection"
import { completeCatalogCte } from "@in/server/modules/chatList/pagedChatList"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { CloudSearchBudget } from "./cloudSearchBudget"

export type Filters = {
  chatId: number | null
  spaceId: number | null
  fromUserId: number | null
  minDate: number | null
  maxDate: number | null
  filter: SearchMessagesFilter
  includeArchived: boolean
  homeOnly: boolean
}

export type SearchScope = { id: number; floor: number }

// Discovery can include temporarily stale candidates. Apply canonical access before fetching any keys.
export async function discoverScope(
  filters: Filters,
  actor: number,
  tx: Transaction,
  budget: CloudSearchBudget,
  onlyIds?: number[],
): Promise<SearchScope[]> {
  const scoped = filters.spaceId !== null || filters.homeOnly
  if (onlyIds?.length === 0) return []
  const catalog = onlyIds
    ? sql`catalog as (select id from chats where id in (${sql.join(onlyIds, sql`, `)}))`
    : completeCatalogCte(actor)
  const allowed: SearchScope[] = []
  let after = 0
  while (true) {
    budget.check()
    const rows = await tx.execute<SearchScope>(sql`
    with recursive ${catalog}
    ${
      scoped
        ? sql`, lineage(id, ancestor_id, space_id, parent_chat_id) as (
      select c.id, c.id, c.space_id, c.parent_chat_id from catalog k join chats c on c.id = k.id
      union
      select a.id, p.id, p.space_id, p.parent_chat_id from lineage a join chats p on p.id = a.parent_chat_id
      where a.space_id is null
    )`
        : sql``
    }
    select c.id, coalesce(d.collapsed_max_id, 0) as floor from catalog k
    join chats c on c.id = k.id left join dialogs d on d.chat_id = c.id and d.user_id = ${actor}
    where c.id > ${after}
    ${filters.chatId !== null ? sql`and c.id = ${filters.chatId}` : sql``}
    ${filters.includeArchived ? sql`` : sql`and d.archived is not true`}
    ${
      filters.spaceId === null
        ? sql``
        : sql`and exists(select 1 from lineage ln join members mb on mb.space_id = ln.space_id
      where ln.id = c.id and ln.space_id = ${filters.spaceId} and mb.user_id = ${actor})`
    }
    ${filters.homeOnly ? sql`and not exists(select 1 from lineage where id = c.id and space_id is not null)` : sql``}
    order by c.id limit 2048`)
    if (rows.length === 0) return allowed
    const access = await getEffectiveChatAccessUserIds(
      tx,
      rows.map((row) => row.id),
      { userIds: [actor] },
    )
    allowed.push(...rows.filter((row) => access.get(row.id)?.has(actor)))
    if (rows.length < 2048) return allowed
    after = rows[rows.length - 1]!.id
  }
}

export function basePredicate(ids: number[], filters: Filters, highWater: bigint): SQL {
  return sql`m.chat_id in (${sql.join(ids, sql`, `)}) and m.message_id > coalesce(d.collapsed_max_id, 0)
    ${filters.includeArchived ? sql`` : sql`and coalesce(d.archived, false) = false`}
    and ${messageFilters(filters, highWater)}`
}

export function messageFilters(filters: Filters, highWater: bigint): SQL {
  return sql`m.global_id <= ${highWater}
    ${filters.fromUserId === null ? sql`` : sql`and m.from_id = ${filters.fromUserId}`}
    ${filters.minDate === null ? sql`` : sql`and m.date >= ${new Date(filters.minDate * 1000).toISOString()}::timestamp`}
    ${filters.maxDate === null ? sql`` : sql`and m.date < (${new Date(filters.maxDate * 1000).toISOString()}::timestamp + interval '1 second')`}
    ${mediaPredicate(filters.filter)}`
}

function mediaPredicate(filter: SearchMessagesFilter): SQL {
  switch (filter) {
    case SearchMessagesFilter.FILTER_UNSPECIFIED:
      return sql``
    case SearchMessagesFilter.FILTER_PHOTOS:
      return sql`and m.photo_id is not null`
    case SearchMessagesFilter.FILTER_VIDEOS:
      return sql`and m.video_id is not null`
    case SearchMessagesFilter.FILTER_PHOTO_VIDEO:
      return sql`and (m.photo_id is not null or m.video_id is not null)`
    case SearchMessagesFilter.FILTER_DOCUMENTS:
      return sql`and m.document_id is not null`
    case SearchMessagesFilter.FILTER_LINKS:
      return sql`and m.has_link is true`
    case SearchMessagesFilter.FILTER_VOICE_MEMOS:
      return sql`and m.voice_id is not null`
    default:
      throw RealtimeRpcError.BadRequest()
  }
}

export async function normalizeFilters(
  input: SearchMessagesGlobalInput,
  actor: number,
  tx: Transaction,
): Promise<Filters> {
  const positive = (value: bigint | undefined): number | null => {
    if (value === undefined) return null
    const number = Number(value)
    if (!Number.isSafeInteger(number) || number < 1 || number > 2147483647) throw RealtimeRpcError.BadRequest()
    return number
  }
  const date = (value: bigint | undefined): number | null => {
    if (value === undefined) return null
    const number = Number(value)
    if (!Number.isSafeInteger(number) || number < 0 || number > 253402300799) throw RealtimeRpcError.BadRequest()
    return number
  }
  let chatId: number | null = null
  if (input.peerId) {
    switch (input.peerId.type.oneofKind) {
      case "chat":
        chatId = positive(input.peerId.type.chat.chatId)
        break
      case "user":
      case "self": {
        const userId = input.peerId.type.oneofKind === "self" ? actor : positive(input.peerId.type.user.userId)!
        const [chat] = await tx
          .select({ id: chats.id })
          .from(chats)
          .where(
            and(
              eq(chats.type, "private"),
              eq(chats.minUserId, Math.min(actor, userId)),
              eq(chats.maxUserId, Math.max(actor, userId)),
            ),
          )
          .limit(1)
        chatId = chat?.id ?? 0
        break
      }
      default:
        throw RealtimeRpcError.PeerIdInvalid()
    }
  }
  const filters: Filters = {
    chatId,
    spaceId: positive(input.spaceId),
    fromUserId: positive(input.fromUserId),
    minDate: date(input.minDate),
    maxDate: date(input.maxDate),
    filter: input.filter ?? SearchMessagesFilter.FILTER_UNSPECIFIED,
    includeArchived: input.includeArchived ?? true,
    homeOnly: input.homeOnly ?? false,
  }
  mediaPredicate(filters.filter)
  if (filters.minDate !== null && filters.maxDate !== null && filters.minDate > filters.maxDate)
    throw RealtimeRpcError.BadRequest()
  return filters
}
