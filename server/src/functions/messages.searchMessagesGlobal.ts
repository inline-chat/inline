import { createHash } from "node:crypto"
import { eq, inArray, sql } from "drizzle-orm"
import type {
  GlobalMessageSearchHit,
  SearchMessagesGlobalInput,
  SearchMessagesGlobalResult,
} from "@inline-chat/protocol/core"
import type { Transaction } from "@in/server/db/types"
import { chatSearchKeys, documents, messages, messageSearchBackfill } from "@in/server/db/schema"
import { encodeOutputPeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { openSearchCursor, sealSearchCursor } from "@in/server/modules/search/cloudCrypto"
import {
  MAX_SEARCH_SOURCE_BYTES,
  cloudSearchEnabled,
  cloudSearchMessageHasText,
  readSearchFileName,
  readSearchMessageText,
} from "@in/server/modules/search/cloudIndex"
import { withCloudSearchBudget, type CloudSearchBudget } from "@in/server/modules/search/cloudSearchBudget"
import { basePredicate, discoverScope, normalizeFilters, type Filters } from "@in/server/modules/search/cloudScope"
import {
  CLOUD_TOKENIZER_VERSION,
  matchExcerpts,
  parseCloudQuery,
  type ParsedCloudQuery,
} from "@in/server/modules/search/cloudTokens"
import { findCandidates, type Candidate, type Seek, type SearchKey } from "@in/server/modules/search/cloudCandidates"
import type { HandlerContext } from "@in/server/realtime/types"

const COVERAGE_BATCH = 512
const CANDIDATES = 200
const BYTE_BUDGET = 2 * 1024 * 1024
const CURSOR_LIFETIME = 15 * 60 * 1000

type Caller = Pick<HandlerContext, "userId" | "sessionId" | "inlineProtocol" | "isBot" | "signal">

type Cursor = { binding: string; highWater: string; seek: Seek; expires: number; incomplete: boolean }

type Verified = { candidate: Candidate; hit: GlobalMessageSearchHit }

async function checkCaller(tx: Transaction, caller: Caller) {
  // Restrict to a live, bound realtime key. HTTP, scoped OAuth and bot transports get no global-search grant.
  const [row] = await tx.execute<{ bot: boolean | null; capture: boolean }>(sql`
    select u.bot as bot, inline_search_capture_enabled() as capture from inline_protocol_auth_keys k join sessions s on s.id = k.account_session_id and s.user_id = k.user_id
    join users u on u.id = s.user_id
    where k.auth_key_id = ${Buffer.from(caller.inlineProtocol!.permanentAuthKeyId)}
      and k.user_id = ${caller.userId} and s.id = ${caller.sessionId} and s.revoked is null
      and u.deleted is not true and k.authorized_at is not null and k.revoked_at is null
      and (k.expires_at is null or k.expires_at > now())`)
  if (!row) throw RealtimeRpcError.Unauthenticated()
  if (row.bot) throw humanRequired()
  if (!row.capture) throw RealtimeRpcError.ServiceUnavailable(60)
}

function cursorFrom(value: string): Cursor {
  const c = openSearchCursor(value) as Partial<Cursor> | null
  if (
    !c ||
    typeof c.binding !== "string" ||
    typeof c.expires !== "number" ||
    c.expires <= Date.now() ||
    typeof c.incomplete !== "boolean" ||
    typeof c.highWater !== "string" ||
    !/^\d{1,19}$/.test(c.highWater) ||
    typeof c.seek?.id !== "string" ||
    !/^\d{1,19}$/.test(c.seek.id) ||
    typeof c.seek.date !== "string" ||
    !Number.isFinite(Date.parse(c.seek.date))
  )
    throw RealtimeRpcError.BadRequest()
  return c as Cursor
}

function humanRequired() {
  const error = new RealtimeRpcError(RealtimeRpcError.Code.UNAUTHENTICATED, "Human account required", 403)
  error.publicReason = "Global search requires a human account."
  return error
}

async function readKeys(tx: Transaction, scope: { id: number }[], budget: CloudSearchBudget) {
  const keys = new Map<number, SearchKey>()
  for (let i = 0; i < scope.length; i += 500) {
    budget.check()
    const ids = scope.slice(i, i + 500).map((row) => row.id)
    const batch = await tx.select().from(chatSearchKeys).where(inArray(chatSearchKeys.chatId, ids))
    for (const key of batch) keys.set(key.chatId, key)
  }
  return keys
}

async function missingCoverage(
  tx: Transaction,
  ids: number[],
  filters: Filters,
  highWater: bigint,
  actor: number,
  backfilled: boolean,
) {
  if (backfilled) {
    // Every current source row was either visited by the checkpoint or inserted under a trigger.
    // Only pending and other-profile rows can be incomplete. Seek those by chat before applying visibility.
    const scope = sql`sd.chat_id in (${sql.join(ids, sql`, `)})`
    const [row] = await tx.execute<{ missing: boolean }>(sql`
      with uncertain as (
        select message_global_id from message_search_documents sd where ${scope} and not ready
        union all select message_global_id from message_search_documents sd where ${scope} and ready and tokenizer_version < ${CLOUD_TOKENIZER_VERSION}
        union all select message_global_id from message_search_documents sd where ${scope} and ready and tokenizer_version > ${CLOUD_TOKENIZER_VERSION}
      ) select exists(select 1 from uncertain u join messages m on m.global_id = u.message_global_id
        left join dialogs d on d.chat_id = m.chat_id and d.user_id = ${actor}
        where ${basePredicate(ids, filters, highWater)}) as missing`)
    return row?.missing ?? true
  }
  const [coverage] = await tx.execute<{ missing: boolean }>(sql`
    select exists(select 1 from messages m
      left join dialogs d on d.chat_id = m.chat_id and d.user_id = ${actor}
      left join message_search_documents sd on sd.message_global_id = m.global_id
      left join chat_search_keys sk on sk.chat_id = m.chat_id
      where ${basePredicate(ids, filters, highWater)}
        and (sd.message_global_id is null or not sd.ready or sd.message_rev <> m.rev
          or sk.chat_id is null or sd.tokenizer_version is distinct from ${CLOUD_TOKENIZER_VERSION}))
      as missing`)
  return coverage?.missing ?? true
}

async function verify(
  tx: Transaction,
  candidates: Candidate[],
  query: ParsedCloudQuery,
  limit: number,
  candidateBudget: number,
  budget: CloudSearchBudget,
) {
  const toRead: Candidate[] = []
  let bytes = 0
  for (const row of candidates.slice(0, candidateBudget)) {
    if (row.bytes > MAX_SEARCH_SOURCE_BYTES || (toRead.length && bytes + row.bytes > BYTE_BUDGET)) break
    toRead.push(row)
    bytes += row.bytes
  }
  if (!toRead.length && candidates.length)
    throw RealtimeRpcError.BadRequestWithReason("Search verification limit exceeded")
  const rows = !toRead.length
    ? []
    : await tx
        .select({
          id: messages.globalId,
          chatId: messages.chatId,
          messageId: messages.messageId,
          fromId: messages.fromId,
          text: messages.text,
          textEncrypted: messages.textEncrypted,
          textIv: messages.textIv,
          textTag: messages.textTag,
          systemMessageEncrypted: messages.systemMessageEncrypted,
          systemMessageIv: messages.systemMessageIv,
          systemMessageTag: messages.systemMessageTag,
          fileName: documents.fileName,
          fileNameIv: documents.fileNameIv,
          fileNameTag: documents.fileNameTag,
        })
        .from(messages)
        .leftJoin(documents, eq(documents.id, messages.documentId))
        .where(
          inArray(
            messages.globalId,
            toRead.map((row) => BigInt(row.id)),
          ),
        )
  const byId = new Map(rows.map((row) => [row.id.toString(), row]))
  const verified: Verified[] = []
  let visited = 0
  for (const candidate of toRead) {
    budget.check()
    visited++
    const row = byId.get(candidate.id)!
    if (!cloudSearchMessageHasText(row)) continue
    const excerpts = matchExcerpts(query, { text: readSearchMessageText(row), fileName: readSearchFileName(row) })
    if (excerpts)
      verified.push({
        candidate,
        hit: {
          chatId: BigInt(row.chatId),
          messageId: BigInt(row.messageId),
          date: BigInt(Math.floor(Number(candidate.dateMs) / 1000)),
          fromUserId: BigInt(row.fromId),
          excerpts,
        },
      })
    if (verified.length === limit) break
  }
  return { verified, visited }
}

async function collectPage(
  tx: Transaction,
  budget: CloudSearchBudget,
  caller: Caller,
  input: SearchMessagesGlobalInput,
  query: ParsedCloudQuery,
  cursor: Cursor | undefined,
  ceiling: bigint | undefined,
  limit: number,
) {
  const candidateBudget = query.every((term) => term.length === 1) ? limit : CANDIDATES
  await checkCaller(tx, caller)
  const filters = await normalizeFilters(input, caller.userId, tx)
  const binding = createHash("sha256")
    .update(JSON.stringify([CLOUD_TOKENIZER_VERSION, caller.userId, caller.sessionId, input.query, filters]))
    .digest("base64url")
  if (cursor && cursor.binding !== binding) throw RealtimeRpcError.BadRequestWithReason("Restart the search")
  const scope = await discoverScope(filters, caller.userId, tx, budget)
  const keys = await readKeys(tx, scope, budget)
  const highWater =
    ceiling ??
    BigInt((await tx.execute<{ id: string }>(sql`select coalesce(max(global_id), 0)::text as id from messages`))[0]!.id)
  const candidates = await findCandidates(
    tx,
    scope,
    keys,
    query,
    filters,
    highWater,
    candidateBudget + 1,
    budget,
    cursor?.seek,
  )
  const { verified, visited } = await verify(tx, candidates, query, limit, candidateBudget, budget)
  const last = candidates[visited - 1]
  const seek =
    last && visited < candidates.length ? { date: new Date(Number(last.dateMs)).toISOString(), id: last.id } : undefined
  return {
    binding,
    highWater,
    verified,
    seek,
    last,
    lookahead: candidates[visited],
    filters,
    ids: scope.map((s) => s.id),
  }
}

async function disclosePage(
  tx: Transaction,
  budget: CloudSearchBudget,
  caller: Caller,
  phase: Awaited<ReturnType<typeof collectPage>>,
  cursor: Cursor | undefined,
): Promise<SearchMessagesGlobalResult | undefined> {
  await checkCaller(tx, caller)
  const { filters, binding } = phase
  let incomplete = cursor?.incomplete ?? false
  const [backfill] = await tx
    .select({ complete: messageSearchBackfill.complete })
    .from(messageSearchBackfill)
    .where(eq(messageSearchBackfill.profile, CLOUD_TOKENIZER_VERSION))
  // The common case (caught up) needs no second catalog scan. If a batch may be
  // incomplete, check its current access and filters before disclosing that bit.
  for (let i = 0; !incomplete && i < phase.ids.length; i += COVERAGE_BATCH) {
    budget.check()
    const ids = phase.ids.slice(i, i + COVERAGE_BATCH)
    const coverage = (ids: number[]) =>
      missingCoverage(tx, ids, filters, phase.highWater, caller.userId, !!backfill?.complete)
    if (!(await coverage(ids))) continue
    const allowed = await discoverScope(filters, caller.userId, tx, budget, ids)
    if (allowed.length) incomplete = await coverage(allowed.map((s) => s.id))
  }
  const hits: GlobalMessageSearchHit[] = []
  let continuation = false
  const candidates = phase.verified.map((v) => v.candidate)
  if (phase.lookahead && phase.last) candidates.push(phase.lookahead, phase.last)
  const scoped = await discoverScope(filters, caller.userId, tx, budget, [
    ...new Set(candidates.map((row) => row.chatId)),
  ])
  const ids = scoped.map((row) => row.id)
  if (ids.length) {
    const visible = await tx.execute<{
      id: string
      work: string
      sender: number
      messageId: number
      chatId: number
      dateMs: string
      type: "private" | "thread"
      minUserId: number | null
      maxUserId: number | null
    }>(sql`
          select m.global_id::text as id, sd.work_version::text as work, m.from_id as sender, m.message_id as "messageId", m.chat_id as "chatId", c.type, c.min_user_id as "minUserId", c.max_user_id as "maxUserId",
            (extract(epoch from m.date)*1000)::bigint::text as "dateMs" from messages m join chats c on c.id = m.chat_id
          join message_search_documents sd on sd.message_global_id = m.global_id and sd.message_rev = m.rev and sd.ready
          join chat_search_keys sk on sk.chat_id = m.chat_id
          left join dialogs d on d.chat_id = m.chat_id and d.user_id = ${caller.userId}
          where ${basePredicate(ids, filters, phase.highWater)} and sd.tokenizer_version = ${CLOUD_TOKENIZER_VERSION}
            and m.global_id in (${sql.join(
              candidates.map((row) => BigInt(row.id)),
              sql`, `,
            )})`)
    const current = new Map(visible.map((row) => [row.id, row]))
    const stillCurrent = (candidate: Candidate) => {
      const row = current.get(candidate.id)
      return row?.work === candidate.work && row.dateMs === candidate.dateMs && row.chatId === candidate.chatId
    }
    continuation = !!(phase.lookahead && phase.last && stillCurrent(phase.lookahead) && stillCurrent(phase.last))
    for (const { candidate, hit } of phase.verified) {
      const row = current.get(candidate.id)
      if (
        row?.work === candidate.work &&
        row.dateMs === candidate.dateMs &&
        BigInt(row.sender) === hit.fromUserId &&
        BigInt(row.messageId) === hit.messageId &&
        BigInt(row.chatId) === hit.chatId
      ) {
        hits.push({
          ...hit,
          peer: encodeOutputPeerFromChat({ ...row, id: row.chatId }, { currentUserId: caller.userId }),
        })
      } else if (
        ids.includes(candidate.chatId) &&
        Number(hit.messageId) > scoped.find((s) => s.id === candidate.chatId)!.floor
      )
        incomplete = true
    }
  }
  // A revoked or edited lookahead cannot authorize a continuation or silently
  // terminate a page that still has other results. Recompute against a fresh snapshot.
  if (phase.seek && !continuation) return undefined
  return {
    hits,
    indexIncomplete: incomplete,
    nextCursor:
      phase.seek && continuation
        ? sealSearchCursor({
            binding,
            highWater: phase.highWater.toString(),
            seek: phase.seek,
            incomplete,
            expires: cursor?.expires ?? Date.now() + CURSOR_LIFETIME,
          } satisfies Cursor)
        : undefined,
  }
}

export async function searchMessagesGlobal(
  input: SearchMessagesGlobalInput,
  caller: Caller,
): Promise<SearchMessagesGlobalResult> {
  if (!cloudSearchEnabled()) throw RealtimeRpcError.ServiceUnavailable(60)
  if (!caller.inlineProtocol) throw RealtimeRpcError.Unauthenticated()
  if (caller.isBot) throw humanRequired()
  let query: ParsedCloudQuery
  let cursor: Cursor | undefined
  try {
    query = parseCloudQuery(input.query)
  } catch {
    throw RealtimeRpcError.BadRequestWithReason(
      "Enter up to eight whole words or a quoted phrase. Prefix wildcards are unsupported.",
    )
  }
  try {
    cursor = input.cursor === undefined ? undefined : cursorFrom(input.cursor)
  } catch {
    throw RealtimeRpcError.BadRequestWithReason("Invalid or expired search cursor. Restart the search.")
  }
  const limit = input.limit ?? 20
  if (!Number.isInteger(limit) || limit < 1 || limit > 50) throw RealtimeRpcError.BadRequest()
  return withCloudSearchBudget(caller.userId, caller.sessionId, caller.signal, async (budget) => {
    let ceiling = cursor ? BigInt(cursor.highWater) : undefined
    for (let attempt = 0; attempt < 2; attempt++) {
      const page = await budget.snapshot((tx) => collectPage(tx, budget, caller, input, query, cursor, ceiling, limit))
      ceiling = page.highWater
      const result = await budget.snapshot((tx) => disclosePage(tx, budget, caller, page, cursor))
      if (result) return result
    }
    throw RealtimeRpcError.ServiceUnavailable(1)
  })
}
