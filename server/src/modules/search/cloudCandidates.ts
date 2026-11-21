import { sql } from "drizzle-orm"
import type { chatSearchKeys } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { searchSourceBytes } from "./cloudIndex"
import { openChatSearchKey } from "./cloudCrypto"
import { messageFilters, type Filters, type SearchScope } from "./cloudScope"
import { CLOUD_TOKENIZER_VERSION, cloudQueryTags, type ParsedCloudQuery } from "./cloudTokens"
import type { CloudSearchBudget } from "./cloudSearchBudget"

export type Seek = { date: string; id: string }
export type Candidate = { id: string; chatId: number; dateMs: string; bytes: number; work: string }
export type SearchKey = typeof chatSearchKeys.$inferSelect
const WINDOW = 240
const BATCH = 512
const fields = sql`m.global_id::text as id, m.chat_id as "chatId", sd.work_version::text as work,
  (extract(epoch from m.date)*1000)::bigint::text as "dateMs", ${searchSourceBytes}::int as bytes`
const current = sql`sd.ready and sd.message_rev = m.rev and sd.tokenizer_version = ${CLOUD_TOKENIZER_VERSION}`
const before = (seek?: Seek) =>
  seek ? sql`and (m.date, m.global_id) < (${seek.date}::timestamp, ${seek.id}::bigint)` : sql``

function compare(a: Candidate, b: Candidate) {
  return Number(b.dateMs) - Number(a.dateMs) || (a.id === b.id ? 0 : BigInt(a.id) < BigInt(b.id) ? 1 : -1)
}

export async function findCandidates(
  tx: Transaction,
  scopes: SearchScope[],
  keys: Map<number, SearchKey>,
  query: ParsedCloudQuery,
  filters: Filters,
  highWater: bigint,
  limit: number,
  budget: CloudSearchBudget,
  seek?: Seek,
): Promise<Candidate[]> {
  const floors = new Map(scopes.filter((s) => keys.has(s.id)).map((s) => [s.id, s.floor]))
  if (!floors.size) return []
  const tags = new Map<number, string[][]>()
  function terms(id: number) {
    const cached = tags.get(id)
    if (cached) return cached
    const key = openChatSearchKey(id, keys.get(id)!.keyEnvelope)
    try {
      const value = cloudQueryTags(id, key, query)
      tags.set(id, value)
      return value
    } finally {
      key.fill(0)
    }
  }
  // A chat can contribute to the newest window only if its newest message is
  // at least as recent as the Nth newest chat head. Seek one head per chat,
  // then read just the short-listed chats down to that lower bound.
  const windowSize = Math.min(WINDOW, Math.max(32, limit * 2))
  const chatIds = [...floors.keys()]
  const columns = terms(chatIds[0]!).map((_, index) => sql.identifier(`word${index}`))
  const matches = sql.join(
    columns.map((column) => sql`sd.tags && s.${column}`),
    sql` and `,
  )
  function taggedScope(ids: number[]) {
    const rows = ids.map((id) => {
      const words = terms(id).map((options) => sql`${"{" + options.join(",") + "}"}::uuid[]`)
      return sql`(${id}::int,${floors.get(id)!}::int,${sql.join(words, sql`, `)})`
    })
    return sql`scope(id,floor,${sql.join(columns, sql`, `)}) as materialized (values ${sql.join(rows, sql`, `)})`
  }
  const chronology = sql`m.global_id <= ${highWater} ${before(seek)}
    ${filters.minDate === null ? sql`` : sql`and m.date >= ${new Date(filters.minDate * 1000).toISOString()}::timestamp`}
    ${filters.maxDate === null ? sql`` : sql`and m.date < (${new Date(filters.maxDate * 1000).toISOString()}::timestamp + interval '1 second')`}`
  const dateOrder = sql`m.date desc nulls last, m.global_id desc nulls last`
  const singleChat = floors.size === 1
  const window = singleChat
    ? sql`
    select m.global_id,m.date,m.chat_id from messages m where m.chat_id=${chatIds[0]!} and m.message_id > ${floors.get(chatIds[0]!)!}
      and ${chronology} order by ${dateOrder} limit ${windowSize}`
    : sql`with heads as materialized (
        select h.*,s.floor from unnest(${"{" + chatIds.join(",") + "}"}::int[],
          ${"{" + [...floors.values()].join(",") + "}"}::int[]) s(id,floor) cross join lateral (
          select m.chat_id,m.date,m.global_id from messages m where m.chat_id=s.id and m.message_id>s.floor and ${chronology}
          order by ${dateOrder} limit 1) h order by h.date desc,h.global_id desc limit ${windowSize}
      ), cutoff as (
        select date,global_id from heads order by date desc,global_id desc offset ${windowSize - 1} limit 1
      )
      select r.* from heads s cross join lateral (
        select m.global_id,m.date,m.chat_id from messages m where m.chat_id=s.chat_id and m.message_id>s.floor and ${chronology}
        and (m.date,m.global_id) >= (coalesce((select date from cutoff),'-infinity'::timestamp),
          coalesce((select global_id from cutoff),0::bigint))
        order by ${dateOrder} limit ${windowSize}
      ) r order by r.date desc,r.global_id desc limit ${windowSize}`
  const ids = await tx.execute<{ id: string; date: string; chatId: number }>(sql`
    select r.global_id::text as id, r.date::text as date, r.chat_id as "chatId" from (${window}) r
    order by r.date desc, r.global_id desc`)
  let head: Candidate[] = []
  if (ids.length) {
    const recentChats = [...new Set(ids.map((row) => row.chatId))]
    head = await tx.execute<Candidate>(sql`
      with ${taggedScope(recentChats)}
      select ${fields} from messages m join scope s on s.id=m.chat_id
      join message_search_documents sd on sd.message_global_id=m.global_id
      left join documents doc on doc.id=m.document_id
      where m.global_id in (${sql.join(
        ids.map((row) => BigInt(row.id)),
        sql`, `,
      )}) and ${current}
        and m.message_id > s.floor and (sd.overflow or (${matches}))
        and ${messageFilters(filters, highWater)} order by m.date desc, m.global_id desc limit ${limit}`)
  }
  if (head.length >= limit || ids.length < windowSize) return head
  const boundary = ids[ids.length - 1]!
  let tail: Candidate[] = []
  for (let i = 0; i < chatIds.length; i += BATCH) {
    budget.check()
    const batch = chatIds.slice(i, i + BATCH)
    // Parameterized per-chat probes reuse one plan for the batch. Keeping the
    // posting lookup separate from the source lookup avoids scanning all messages
    // when PostgreSQL overestimates how often a chat-keyed tag can occur.
    const rows = await tx.execute<Candidate>(sql`
      with ${taggedScope(batch)},
      postings as materialized (
        select s.id,s.floor,p.* from scope s cross join lateral (
          select sd.message_global_id, sd.message_rev, sd.work_version from message_search_documents sd
          where ${matches} and sd.ready and sd.tokenizer_version = ${CLOUD_TOKENIZER_VERSION}
          offset 0
        ) p
        union all select s.id,s.floor,sd.message_global_id, sd.message_rev, sd.work_version
          from message_search_documents sd join scope s on s.id=sd.chat_id
          where sd.ready and sd.overflow and sd.tokenizer_version = ${CLOUD_TOKENIZER_VERSION}
      )
      select ${fields} from postings sd cross join lateral (
        select * from messages m where m.global_id=sd.message_global_id and m.chat_id=sd.id
          and m.rev=sd.message_rev and m.message_id>sd.floor and ${messageFilters(filters, highWater)}
          ${before(boundary)} offset 0
      ) m left join documents doc on doc.id=m.document_id
      order by m.date desc, m.global_id desc limit ${limit - head.length}`)
    tail = tail
      .concat(rows)
      .sort(compare)
      .slice(0, limit - head.length)
  }
  return head.concat(tail)
}
