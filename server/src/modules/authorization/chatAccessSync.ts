import { and, inArray, sql, type SQL } from "drizzle-orm"
import { registerPreCommitTask, type PreCommitTask } from "@in/server/db/commitHooks"
import { chatAccess } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { Log } from "@in/server/utils/log"
import { effectiveChatAccessSql } from "./chatAccessProjection"

const log = new Log("authorization.chatAccessSync")

/** Statements stay well below the parameter limit even for the largest Space. */
const SYNC_CHAT_BATCH = 500
// Verifier batches hold the lock briefly on both servers; only report real contention.
const SLOW_LOCK_WAIT_MS = 500

/**
 * Which `chat_access` rows a change can affect. Chat scopes always include
 * every subthread below the given chats; `userIds` narrows the recompute to
 * those users when the change only concerns them.
 */
export type ChatAccessScope =
  | { readonly kind: "chats"; readonly chatIds: readonly number[]; readonly userIds?: readonly number[] }
  | { readonly kind: "spaces"; readonly spaceIds: readonly number[]; readonly userIds?: readonly number[] }
  | { readonly kind: "groups"; readonly groupIds: readonly number[]; readonly userIds?: readonly number[] }
  | { readonly kind: "deletedUsers"; readonly userIds: readonly number[] }

export const isChatAccessSyncEnabled = (): boolean => process.env["INLINE_CHAT_ACCESS_SYNC"] !== "off"

/**
 * Serializes every `chat_access` recompute and repair. Writers take it as the
 * last step of their transaction and only touch `chat_access` afterwards, so a
 * holder never waits on another lock and cannot join a deadlock cycle. In
 * READ COMMITTED the next holder's statements then see the previous commit.
 */
export async function lockChatAccess(tx: Transaction): Promise<number> {
  const started = performance.now()
  const [row] = await tx.execute<{ isolation: string }>(sql`
    select pg_advisory_xact_lock(hashtextextended('inline:chat-access', 0)),
      current_setting('transaction_isolation') as isolation
  `)
  const waitedMs = performance.now() - started
  if (row?.isolation !== "read committed") {
    throw new Error(`chat_access recompute requires read committed, not ${row?.isolation ?? "unknown"}`)
  }
  if (waitedMs >= SLOW_LOCK_WAIT_MS) log.warn("Chat access lock waited", { waitedMs: Math.round(waitedMs) })
  return waitedMs
}

const syncTaskKey = Symbol("chat-access-sync")

/** Every scope one transaction registered, recomputed together before COMMIT. */
class ChatAccessSyncTask implements PreCommitTask {
  readonly scopes: ChatAccessScope[]

  constructor(scope: ChatAccessScope) {
    this.scopes = [scope]
  }

  run = (tx: Transaction): Promise<void> => recomputeContained(tx, this.scopes)

  merge = (next: PreCommitTask): void => {
    if (next instanceof ChatAccessSyncTask) this.scopes.push(...next.scopes)
  }
}

/**
 * Recomputes the scoped `chat_access` rows from the canonical projection in
 * the caller's transaction. Call it from any write that can alter chat access;
 * the recompute runs as the root transaction's last work before COMMIT, so the
 * access lock is always taken after every other write of that transaction.
 */
export async function syncChatAccess(tx: Transaction, scope: ChatAccessScope): Promise<void> {
  if (!isChatAccessSyncEnabled()) return
  const task = new ChatAccessSyncTask(scope)
  if (!registerPreCommitTask(tx, syncTaskKey, task)) await task.run(tx)
}

/**
 * Shadow phase: reads still use the projection, so a failed sync is contained
 * in a savepoint and logged instead of failing the user's change; the verifier
 * repairs the rows. This becomes strict when reads move to the table.
 */
async function recomputeContained(tx: Transaction, scopes: readonly ChatAccessScope[]): Promise<void> {
  try {
    await tx.transaction(async (savepoint) => {
      await lockChatAccess(savepoint)
      for (const scope of scopes) await recomputeChatAccess(savepoint, scope)
    })
  } catch (error) {
    log.warn("Chat access sync failed; the verifier will repair it", { kinds: scopes.map((scope) => scope.kind), error })
  }
}

async function recomputeChatAccess(tx: Transaction, scope: ChatAccessScope): Promise<void> {
  if (scope.kind === "deletedUsers") {
    const userIds = uniqueIds(scope.userIds)
    if (userIds.length > 0) await tx.delete(chatAccess).where(inArray(chatAccess.userId, userIds))
    return
  }
  const userIds = scope.userIds === undefined ? undefined : uniqueIds(scope.userIds)
  if (userIds?.length === 0) return
  const chatIds = await resolveScopeChatIds(tx, scope)
  for (let offset = 0; offset < chatIds.length; offset += SYNC_CHAT_BATCH) {
    const batch = chatIds.slice(offset, offset + SYNC_CHAT_BATCH)
    await tx.delete(chatAccess).where(userIds === undefined
      ? inArray(chatAccess.chatId, batch)
      : and(inArray(chatAccess.chatId, batch), inArray(chatAccess.userId, userIds)))
    await tx.execute(sql`
      insert into chat_access (chat_id, user_id)
      select projected."chatId", projected."userId"
      from (${effectiveChatAccessSql(batch, userIds, "access.sync")}) as projected
      on conflict do nothing
    `)
  }
}

/**
 * The chats and every thread below them, read now. Deletion paths pass this
 * to `syncChatAccess` because the subtree cannot be resolved after the rows
 * are gone.
 */
export async function chatSubtreeIds(tx: Transaction, chatIds: readonly number[]): Promise<number[]> {
  return resolveScopeChatIds(tx, { kind: "chats", chatIds })
}

/** Seeds plus every descendant thread; given chat ids stay in scope even if deleted. */
async function resolveScopeChatIds(
  tx: Transaction,
  scope: Exclude<ChatAccessScope, { kind: "deletedUsers" }>,
): Promise<number[]> {
  let seed: SQL
  if (scope.kind === "chats") {
    const ids = uniqueIds(scope.chatIds)
    if (ids.length === 0) return []
    seed = sql`select unnest(array[${sql.join(ids.map((id) => sql`${id}::integer`), sql`, `)}]) as id`
  } else if (scope.kind === "spaces") {
    const ids = uniqueIds(scope.spaceIds)
    if (ids.length === 0) return []
    seed = sql`select c.id from chats c where c.space_id in (${sql.join(ids, sql`, `)})`
  } else {
    const ids = uniqueIds(scope.groupIds)
    if (ids.length === 0) return []
    seed = sql`select cpg.chat_id as id from chat_participant_groups cpg where cpg.group_id in (${sql.join(ids, sql`, `)})`
  }
  const rows = await tx.execute<{ id: number }>(sql`
    with recursive scoped(id) as (
      ${seed}
      union
      select child.id from chats child join scoped on child.parent_chat_id = scoped.id
    )
    select id from scoped order by id
  `)
  return rows.map((row) => Number(row.id))
}

function uniqueIds(ids: readonly number[]): number[] {
  return Array.from(new Set(ids.filter((id) => Number.isSafeInteger(id) && id > 0)))
}
