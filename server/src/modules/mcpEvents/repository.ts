import { randomUUID } from "node:crypto"
import { and, asc, eq, gt, inArray, isNull, lte, notInArray, or, sql } from "drizzle-orm"
import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { mcpEventSubscriptions as subscriptions, oauthGrants } from "@in/server/db/schema"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { reactionEventNames, reactionEventsEnabled } from "./config"
import { sameSecret } from "./crypto"
import { McpEventsError, accessDenied, invalidParams, type EventOccurrence, type McpEventSelector, type McpEventSubscription } from "./types"

export const readSubscription = async (id: string) => (await db.select().from(subscriptions).where(eq(subscriptions.id, id)).limit(1))[0]

type SaveInput = {
  id: string; grantId: string; name: string; selector: McpEventSelector; callbackUrl: string; secret: string
  expiresAt: Date; verifiedAt: Date; requestedSeq?: number
  readPosition: (seq: number, transaction: Transaction) => Promise<{ latestSeq: number; gap: boolean }>
}

export async function saveSubscription(input: SaveInput): Promise<{ row: McpEventSubscription; truncated: boolean }> {
  for (let attempt = 0; attempt < 8; attempt += 1) {
    try { return await persistSubscription(input) }
    catch (error) {
      const cause = error && typeof error === "object" && "cause" in error ? error.cause : error
      const code = cause && typeof cause === "object" && "code" in cause ? cause.code : undefined
      if (code !== "40001" && code !== "40P01") throw error
    }
  }
  throw new McpEventsError({ code: -32013, message: "Concurrent event subscription limit reached", data: { limit: "concurrentSubscriptions" } })
}

async function persistSubscription(input: SaveInput): Promise<{ row: McpEventSubscription; truncated: boolean }> {
  return db.transaction(async (tx) => {
    // Serialize new identities for a grant so its resource budget cannot race.
    const [grant] = await tx.select({ revokedAt: oauthGrants.revokedAt }).from(oauthGrants)
      .where(eq(oauthGrants.id, input.grantId)).for("update").limit(1)
    if (!grant || grant.revokedAt !== null) throw accessDenied()
    // A preserved-value write is the repeatable-read serialization fence.
    // Merely waiting for an unchanged row lock would retain a stale quota
    // snapshot. Contenders retry DB work only; callback verification is outside.
    await tx.update(oauthGrants).set({ date: sql`${oauthGrants.date}` }).where(eq(oauthGrants.id, input.grantId))
    const [existing] = await tx.select().from(subscriptions).where(eq(subscriptions.id, input.id)).for("update").limit(1)
    const now = new Date()
    const active = existing && !existing.stopped && existing.expiresAt > now
    if (!active) {
      const [count] = await tx.select({ count: sql<number>`count(*)::int` }).from(subscriptions)
        .where(and(eq(subscriptions.grantId, input.grantId), eq(subscriptions.stopped, false), gt(subscriptions.expiresAt, now)))
      if ((count?.count ?? 0) >= 64) throw new McpEventsError({ code: -32013, message: "Event subscription limit reached", data: { limit: "subscriptions", max: 64 } })
    }
    if (!existing) {
      const [count] = await tx.select({ count: sql<number>`count(*)::int` }).from(subscriptions).where(eq(subscriptions.grantId, input.grantId))
      if ((count?.count ?? 0) >= 1024) throw new McpEventsError({ code: -32013, message: "Retained event subscription limit reached", data: { limit: "retainedSubscriptions", max: 1024 } })
    }
    // Active refresh never jumps past a pending occurrence, even when the host
    // supplies a newer checkpoint. Select and probe under this identity's lock;
    // an obsolete pre-lock probe must never skip another worker's progress.
    const requestedStart = existing
      ? existing.pendingEncrypted || active
        ? existing.cursorSeq
        : Math.min(existing.cursorSeq, input.requestedSeq ?? existing.cursorSeq)
      : input.requestedSeq
    const position = await input.readPosition(requestedStart ?? 0, tx)
    if (input.requestedSeq !== undefined && input.requestedSeq > position.latestSeq) throw invalidParams()
    const truncated = !existing?.pendingEncrypted && requestedStart !== undefined && (existing?.gapSeq != null || position.gap)
    const cursorSeq = truncated ? position.latestSeq : requestedStart ?? position.latestSeq
    const oldSecret = existing ? Encryption2.decryptToString(existing.secretEncrypted) : undefined
    const rotated = oldSecret !== undefined && !sameSecret(oldSecret, input.secret)
    const previousSecretEncrypted = rotated ? existing!.secretEncrypted : existing?.previousSecretUntil && existing.previousSecretUntil > now ? existing.previousSecretEncrypted : null
    const previousSecretUntil = rotated ? new Date(now.getTime() + 60_000) : existing?.previousSecretUntil && existing.previousSecretUntil > now ? existing.previousSecretUntil : null
    const values = {
      grantId: input.grantId, name: input.name, selector: input.selector, callbackUrl: input.callbackUrl,
      secretEncrypted: Encryption2.encrypt(Buffer.from(input.secret)), previousSecretEncrypted, previousSecretUntil,
      verifiedAt: input.verifiedAt, expiresAt: input.expiresAt, cursorSeq, gapSeq: null,
      generation: (existing?.generation ?? -1) + 1, stopped: false, leaseOwner: null, leaseUntil: null,
      // Renewal extends expiry without bypassing a pending delivery's
      // backoff/Retry-After. Explicit reactivation may restart exhausted work.
      nextAttemptAt: active && existing.pendingEncrypted ? existing.nextAttemptAt : now,
      attemptCount: existing?.pendingEncrypted && !existing.stopped ? existing.attemptCount : 0,
    }
    const rows = existing ? await tx.update(subscriptions).set(values).where(eq(subscriptions.id, input.id)).returning() :
      await tx.insert(subscriptions).values({ id: input.id, ...values }).returning()
    const row = rows[0]
    if (!row) throw new Error("MCP event subscription was not persisted")
    return { row, truncated }
  }, { isolationLevel: "repeatable read" })
}

/** TTL expiry releases encrypted callback state after one fixed day of grace. */
export async function purgeExpiredSubscriptions(limit = 100): Promise<number> {
  return db.transaction(async (tx) => {
    const rows = await tx.select({ id: subscriptions.id }).from(subscriptions)
      .where(lte(subscriptions.expiresAt, new Date(Date.now() - 24 * 60 * 60_000)))
      .orderBy(asc(subscriptions.expiresAt)).limit(Math.min(100, Math.max(1, limit))).for("update", { skipLocked: true })
    if (rows.length === 0) return 0
    await tx.delete(subscriptions).where(inArray(subscriptions.id, rows.map((row) => row.id)))
    return rows.length
  })
}

export async function stopSubscription(id: string, grantId: string): Promise<boolean> {
  const rows = await db.update(subscriptions).set({ stopped: true, generation: sql`${subscriptions.generation} + 1`, leaseOwner: null, leaseUntil: null })
    .where(and(eq(subscriptions.id, id), eq(subscriptions.grantId, grantId))).returning({ id: subscriptions.id })
  return rows.length > 0
}

export async function activeSubscriptions(grantId: string, chatId: string): Promise<McpEventSubscription[]> {
  return db.select().from(subscriptions).where(and(eq(subscriptions.grantId, grantId), eq(subscriptions.stopped, false),
    isNull(subscriptions.gapSeq), gt(subscriptions.expiresAt, new Date()), sql`${subscriptions.selector}->>'chatId' = ${chatId}`)).limit(64)
}

export async function claimSubscriptions(limit = 25): Promise<McpEventSubscription[]> {
  const now = new Date()
  return db.transaction(async (tx) => {
    const rows = await tx.select().from(subscriptions).where(and(eq(subscriptions.stopped, false), isNull(subscriptions.gapSeq),
      gt(subscriptions.expiresAt, now), ...(reactionEventsEnabled() ? [] : [notInArray(subscriptions.name, [...reactionEventNames])]), lte(subscriptions.nextAttemptAt, now), or(isNull(subscriptions.leaseUntil), lte(subscriptions.leaseUntil, now))))
      .orderBy(asc(subscriptions.nextAttemptAt), asc(subscriptions.id)).limit(Math.min(100, Math.max(1, limit))).for("update", { skipLocked: true })
    const claims: McpEventSubscription[] = []
    for (const row of rows) {
      const [claimed] = await tx.update(subscriptions).set({ leaseOwner: randomUUID(), leaseUntil: new Date(now.getTime() + 30_000) })
        .where(eq(subscriptions.id, row.id)).returning()
      if (claimed) claims.push(claimed)
    }
    return claims
  })
}

export const leaseGuard = (claim: McpEventSubscription) => and(eq(subscriptions.id, claim.id), eq(subscriptions.generation, claim.generation),
  eq(subscriptions.leaseOwner, claim.leaseOwner ?? ""), gt(subscriptions.leaseUntil, new Date()),
  eq(subscriptions.stopped, false), gt(subscriptions.expiresAt, new Date()))

export async function currentClaim(claim: McpEventSubscription): Promise<McpEventSubscription | undefined> {
  return (await db.select().from(subscriptions).where(leaseGuard(claim)).limit(1))[0]
}

export async function persistPending(claim: McpEventSubscription, occurrence: EventOccurrence, seq: number): Promise<McpEventSubscription | undefined> {
  return (await db.update(subscriptions).set({ pendingEncrypted: Encryption2.encrypt(Buffer.from(JSON.stringify(occurrence))), pendingSeq: seq })
    .where(and(leaseGuard(claim), isNull(subscriptions.pendingEncrypted))).returning())[0]
}

export async function acknowledgeClaim(claim: McpEventSubscription): Promise<void> {
  if (claim.pendingSeq == null) return
  await db.update(subscriptions).set({ cursorSeq: claim.pendingSeq, pendingEncrypted: null, pendingSeq: null, attemptCount: 0,
    nextAttemptAt: new Date(), leaseOwner: null, leaseUntil: null }).where(leaseGuard(claim))
}

export async function settleIdle(claim: McpEventSubscription, through: number): Promise<void> {
  await db.update(subscriptions).set({ cursorSeq: through, nextAttemptAt: new Date(Date.now() + 2_000), leaseOwner: null, leaseUntil: null })
    .where(and(leaseGuard(claim), isNull(subscriptions.pendingEncrypted)))
}

export async function persistGap(claim: McpEventSubscription, seq: number): Promise<void> {
  await db.update(subscriptions).set({ gapSeq: seq, leaseOwner: null, leaseUntil: null })
    .where(and(leaseGuard(claim), isNull(subscriptions.pendingEncrypted)))
}

export async function failClaim(claim: McpEventSubscription, retryAt: Date, terminal = false): Promise<void> {
  await db.update(subscriptions).set({ attemptCount: claim.attemptCount + 1, nextAttemptAt: retryAt,
    stopped: terminal, leaseOwner: null, leaseUntil: null }).where(leaseGuard(claim))
}

export async function fenceClaim(claim: McpEventSubscription): Promise<void> {
  await db.update(subscriptions).set({ stopped: true, generation: sql`${subscriptions.generation} + 1`, leaseOwner: null, leaseUntil: null })
    .where(leaseGuard(claim))
}
