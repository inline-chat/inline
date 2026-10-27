import { gt, sql, type SQL } from "drizzle-orm"
import { db } from "@in/server/db"
import { chatAccessState, chats } from "@in/server/db/schema"
import { Log } from "@in/server/utils/log"
import { effectiveChatAccessSql } from "./chatAccessProjection"
import { isChatAccessSyncEnabled, lockChatAccess } from "./chatAccessSync"

const log = new Log("authorization.chatAccessVerifier")

const VERIFY_CHAT_BATCH = 500
const MAX_SAMPLES = 20
const FIRST_RUN_DELAY_MS = 30_000
const RUN_INTERVAL_MS = 5 * 60_000
const RUN_JITTER_MS = 30_000
// Servers still on the previous release write without syncing during a rollout.
const ROLLOUT_GRACE_MS = 15 * 60_000

type AccessPair = { chatId: number; userId: number }
type SampleKind = "missing" | "extra" | "orphan"

export type ChatAccessVerification = {
  /**
   * The backfill has never completed (no `chat_access_state` row), so missing
   * rows are expected. Extra and orphan rows are drift even then.
   */
  backfill: boolean
  /** The backfill completed moments ago, so drift may come from servers still rolling out. */
  rolloutGrace: boolean
  chats: number
  rows: number
  missing: number
  extra: number
  orphans: number
  durationMs: number
  samples: Array<AccessPair & { kind: SampleKind }>
}

type BatchDiff = {
  expected: number
  missing: number
  extra: number
  missingSamples: string[] | null
  extraSamples: string[] | null
}

/**
 * One statement per batch: the projection is computed once, and the repair or
 * comparison is set-based in SQL, so the parameter count is bounded by the
 * batch's chat ids (about three per chat) no matter how many pairs differ.
 */
const batchDiffSql = (chatIds: readonly number[], repair: boolean): SQL => {
  const ids = sql.join([...chatIds], sql`, `)
  const projected = effectiveChatAccessSql(chatIds, undefined, "access.verify")
  if (repair) {
    return sql`
      with projected as (${projected}),
      deleted as (
        delete from chat_access stored
        where stored.chat_id in (${ids})
          and not exists (
            select 1 from projected p where p."chatId" = stored.chat_id and p."userId" = stored.user_id
          )
        returning stored.chat_id, stored.user_id
      ),
      inserted as (
        insert into chat_access (chat_id, user_id)
        select p."chatId", p."userId" from projected p
        on conflict do nothing
        returning chat_id, user_id
      )
      select
        (select count(*) from projected)::int as expected,
        (select count(*) from inserted)::int as missing,
        (select count(*) from deleted)::int as extra,
        (select array_agg(chat_id::text || ':' || user_id::text) from (select chat_id, user_id from inserted limit ${MAX_SAMPLES}) s) as "missingSamples",
        (select array_agg(chat_id::text || ':' || user_id::text) from (select chat_id, user_id from deleted limit ${MAX_SAMPLES}) s) as "extraSamples"
    `
  }
  return sql`
    with projected as (${projected}),
    stored as (select chat_id, user_id from chat_access where chat_id in (${ids})),
    missing as (
      select p."chatId" as chat_id, p."userId" as user_id from projected p
      where not exists (select 1 from stored s where s.chat_id = p."chatId" and s.user_id = p."userId")
    ),
    extra as (
      select s.chat_id, s.user_id from stored s
      where not exists (select 1 from projected p where p."chatId" = s.chat_id and p."userId" = s.user_id)
    )
    select
      (select count(*) from projected)::int as expected,
      (select count(*) from missing)::int as missing,
      (select count(*) from extra)::int as extra,
      (select array_agg(chat_id::text || ':' || user_id::text) from (select chat_id, user_id from missing limit ${MAX_SAMPLES}) s) as "missingSamples",
      (select array_agg(chat_id::text || ':' || user_id::text) from (select chat_id, user_id from extra limit ${MAX_SAMPLES}) s) as "extraSamples"
  `
}

const parsePairs = (values: string[] | null): AccessPair[] => (values ?? []).map((value) => {
  const [chatId, userId] = value.split(":")
  return { chatId: Number(chatId), userId: Number(userId) }
})

/**
 * Compares `chat_access` with the canonical projection for every chat and
 * repairs any difference. Each batch of chats is compared and repaired in one
 * statement under the access lock, so no sync interleaves with a batch; batches
 * are separate transactions, so the run is consistent per batch, not globally.
 * Rows for different chats are independent, so per-batch consistency is what
 * a comparison needs.
 */
export async function verifyChatAccess(options: { repair?: boolean; batchSize?: number } = {}): Promise<ChatAccessVerification> {
  const repair = options.repair ?? true
  const batchSize = options.batchSize ?? VERIFY_CHAT_BATCH
  const started = performance.now()
  const [state] = await db.select().from(chatAccessState).limit(1)
  const result: ChatAccessVerification = {
    backfill: state === undefined,
    rolloutGrace: state !== undefined && Date.now() - state.backfilledAt.getTime() < ROLLOUT_GRACE_MS,
    chats: 0, rows: 0, missing: 0, extra: 0, orphans: 0, durationMs: 0, samples: [],
  }
  const sample = (pair: AccessPair, kind: SampleKind) => {
    if (result.samples.length < MAX_SAMPLES) result.samples.push({ ...pair, kind })
  }

  let cursor = 0
  while (true) {
    const ids = (await db.select({ id: chats.id }).from(chats).where(gt(chats.id, cursor)).orderBy(chats.id).limit(batchSize))
      .map((row) => row.id)
    if (ids.length === 0) break
    cursor = ids[ids.length - 1]!
    result.chats += ids.length
    await db.transaction(async (tx) => {
      await lockChatAccess(tx)
      const [diff] = await tx.execute<BatchDiff>(batchDiffSql(ids, repair))
      if (!diff) return
      result.rows += diff.expected
      result.missing += diff.missing
      result.extra += diff.extra
      for (const pair of parsePairs(diff.missingSamples)) sample(pair, "missing")
      for (const pair of parsePairs(diff.extraSamples)) sample(pair, "extra")
    })
  }

  // Rows whose chat no longer exists; deletion paths should have removed them.
  await db.transaction(async (tx) => {
    await lockChatAccess(tx)
    const orphans = repair
      ? sql`delete from chat_access access
          where not exists (select 1 from chats c where c.id = access.chat_id)
          returning access.chat_id, access.user_id`
      : sql`select access.chat_id, access.user_id from chat_access access
          where not exists (select 1 from chats c where c.id = access.chat_id)`
    const [row] = await tx.execute<{ orphans: number; samples: string[] | null }>(sql`
      with orphaned as (${orphans})
      select (select count(*) from orphaned)::int as orphans,
        (select array_agg(chat_id::text || ':' || user_id::text) from (select chat_id, user_id from orphaned limit ${MAX_SAMPLES}) s) as samples
    `)
    result.orphans = row?.orphans ?? 0
    for (const pair of parsePairs(row?.samples ?? null)) sample(pair, "orphan")
  })

  // A completed repair pass ends the backfill; from now on every difference is drift.
  if (repair && result.backfill) {
    await db.insert(chatAccessState).values({ id: 1, backfilledAt: new Date() }).onConflictDoNothing()
  }

  result.durationMs = Math.round(performance.now() - started)
  return result
}

/** Runs the verifier shortly after start and then every few minutes. */
export class ChatAccessVerifier {
  private timer: ReturnType<typeof setTimeout> | undefined
  private running: Promise<void> | undefined
  private stopped = false

  constructor(private readonly verify: () => Promise<ChatAccessVerification> = verifyChatAccess) {}

  start(): void {
    this.schedule(FIRST_RUN_DELAY_MS)
  }

  async stop(): Promise<void> {
    this.stopped = true
    if (this.timer) clearTimeout(this.timer)
    this.timer = undefined
    await this.running
  }

  private schedule(baseMs: number): void {
    if (this.stopped) return
    this.timer = setTimeout(() => {
      this.timer = undefined
      this.running = this.runOnce().finally(() => {
        this.running = undefined
        this.schedule(RUN_INTERVAL_MS)
      })
    }, baseMs + Math.floor(Math.random() * RUN_JITTER_MS))
    this.timer.unref?.()
  }

  private async runOnce(): Promise<void> {
    try {
      const result = await this.verify()
      reportVerification(result)
    } catch (error) {
      log.warn("Chat access verification could not complete", { error })
    }
  }
}

export function reportVerification(result: ChatAccessVerification): void {
  const { samples, ...counts } = result
  // Missing rows are expected only until the first backfill completes.
  const drift = (result.backfill ? 0 : result.missing) + result.extra + result.orphans
  if (drift > 0 && result.rolloutGrace) {
    log.warn("Chat access drift during rollout grace was repaired", { ...counts, samples })
  } else if (drift > 0) {
    // Drift means an access-changing path skipped syncChatAccess.
    log.error("Chat access drifted from the projection and was repaired", { ...counts, samples })
  } else if (result.backfill) {
    log.info("Backfilled chat access", counts)
  }
}

export function startChatAccessVerifier(): ChatAccessVerifier | null {
  if (!isChatAccessSyncEnabled()) return null
  const verifier = new ChatAccessVerifier()
  verifier.start()
  return verifier
}
