import { authKeyId as deriveAuthKeyId, equalBytes, type EstablishedAuthorizationKey } from "@inline-chat/protocol/secure"
import { and, count, eq, exists, gt, isNotNull, isNull, ne, or, sql } from "drizzle-orm"
import { createHash, timingSafeEqual } from "node:crypto"
import { db } from "@in/server/db"
import {
  inlineProtocolAuthChallenges,
  inlineProtocolAuthKeys,
  inlineProtocolRequests,
  type DbInlineProtocolAuthKey,
} from "@in/server/db/schema/inlineProtocol"
import { sessions } from "@in/server/db/schema/sessions"
import type { AuthorizationKeyCipher } from "@in/server/modules/inlineProtocol/keyCipher"
import { InlineProtocolKeyStoreError, InlineProtocolReplayError } from "@in/server/modules/inlineProtocol/errors"
import { MAX_REPLAY_RESULT_BYTES, type ReplayIdentity, type ReplayResultCipher } from "@in/server/modules/inlineProtocol/replayCipher"

const DEFAULT_REPLAY_TTL_MS = 10 * 60 * 1_000
const MAX_RESULT_BYTES = MAX_REPLAY_RESULT_BYTES

export type PermanentAuthorizationKey = {
  key: Uint8Array
  keyId: Uint8Array
  currentServerSalt: bigint
  previousServerSalt?: bigint
  userId?: number
  accountSessionId?: number
  createdAt: Date
  expiresAt?: Date
}

export class PermanentAuthorizationKeyRepository {
  constructor(private readonly cipher: AuthorizationKeyCipher) {}

  async create(key: EstablishedAuthorizationKey): Promise<"created" | "collision"> {
    if (key.temporary || key.key.length !== 256 || key.keyId.length !== 8 ||
        !equalBytes(deriveAuthKeyId(key.key), key.keyId)) {
      throw new InlineProtocolKeyStoreError({ operation: "create_permanent_shape" })
    }
    try {
      const inserted = await db.insert(inlineProtocolAuthKeys).values({
        authKeyId: Buffer.from(key.keyId),
        authKeyEncrypted: this.cipher.wrap(key.keyId, key.key),
        keyEncryptionKeyId: this.cipher.activeKeyId,
        currentServerSalt: key.serverSalt,
        expiresAt: key.expiresAt === undefined ? null : new Date(key.expiresAt * 1000),
      }).onConflictDoNothing().returning({ authKeyId: inlineProtocolAuthKeys.authKeyId })
      return inserted.length === 1 ? "created" : "collision"
    } catch (cause) {
      if (cause instanceof InlineProtocolKeyStoreError) throw cause
      throw new InlineProtocolKeyStoreError({ operation: "create_permanent", cause })
    }
  }

  async getActive(authKeyId: Uint8Array, now = new Date()): Promise<PermanentAuthorizationKey | undefined> {
    if (authKeyId.length !== 8) return undefined
    let row: DbInlineProtocolAuthKey | undefined
    try {
      row = (await db.select().from(inlineProtocolAuthKeys).where(and(
        eq(inlineProtocolAuthKeys.authKeyId, Buffer.from(authKeyId)),
        isNull(inlineProtocolAuthKeys.revokedAt),
        or(isNull(inlineProtocolAuthKeys.expiresAt), gt(inlineProtocolAuthKeys.expiresAt, now)),
        or(
          isNull(inlineProtocolAuthKeys.accountSessionId),
          exists(db.select({ one: sql`1` }).from(sessions).where(and(
            eq(sessions.id, inlineProtocolAuthKeys.accountSessionId),
            eq(sessions.userId, inlineProtocolAuthKeys.userId),
            isNull(sessions.revoked),
          ))),
        ),
      )).limit(1))[0]
    } catch (cause) {
      throw new InlineProtocolKeyStoreError({ operation: "load_permanent", cause })
    }
    if (!row) return undefined
    const key = this.cipher.unwrap(authKeyId, row.keyEncryptionKeyId, row.authKeyEncrypted)
    if (!equalBytes(deriveAuthKeyId(key), authKeyId)) {
      key.fill(0)
      throw new InlineProtocolKeyStoreError({ operation: "verify_permanent_key_id" })
    }
    return {
      key,
      keyId: Uint8Array.from(row.authKeyId),
      currentServerSalt: row.currentServerSalt,
      previousServerSalt: row.previousServerSalt ?? undefined,
      userId: row.userId ?? undefined,
      accountSessionId: row.accountSessionId ?? undefined,
      createdAt: row.createdAt,
      expiresAt: row.expiresAt ?? undefined,
    }
  }

  async rewrapBatch(limit = 100): Promise<{ rewrapped: number; remaining: number }> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 1_000) {
      throw new InlineProtocolKeyStoreError({ operation: "rewrap_batch_limit" })
    }
    try {
      const rewrapped = await db.transaction(async (tx) => {
        const rows = await tx.select({
          authKeyId: inlineProtocolAuthKeys.authKeyId,
          authKeyEncrypted: inlineProtocolAuthKeys.authKeyEncrypted,
          keyEncryptionKeyId: inlineProtocolAuthKeys.keyEncryptionKeyId,
        }).from(inlineProtocolAuthKeys)
          .where(ne(inlineProtocolAuthKeys.keyEncryptionKeyId, this.cipher.activeKeyId))
          .limit(limit)
        let changed = 0
        for (const row of rows) {
          const plaintext = this.cipher.unwrap(row.authKeyId, row.keyEncryptionKeyId, row.authKeyEncrypted)
          try {
            const updated = await tx.update(inlineProtocolAuthKeys).set({
              authKeyEncrypted: this.cipher.wrap(row.authKeyId, plaintext),
              keyEncryptionKeyId: this.cipher.activeKeyId,
            }).where(and(
              eq(inlineProtocolAuthKeys.authKeyId, row.authKeyId),
              eq(inlineProtocolAuthKeys.keyEncryptionKeyId, row.keyEncryptionKeyId),
            )).returning({ authKeyId: inlineProtocolAuthKeys.authKeyId })
            changed += updated.length
          } finally {
            plaintext.fill(0)
          }
        }
        return changed
      })
      const [{ value: remaining = 0 } = { value: 0 }] = await db.select({ value: count() })
        .from(inlineProtocolAuthKeys)
        .where(ne(inlineProtocolAuthKeys.keyEncryptionKeyId, this.cipher.activeKeyId))
      return { rewrapped, remaining }
    } catch (cause) {
      if (cause instanceof InlineProtocolKeyStoreError) throw cause
      throw new InlineProtocolKeyStoreError({ operation: "rewrap_batch", cause })
    }
  }

  async countUsingKeyEncryptionKey(keyEncryptionKeyId: string): Promise<number> {
    try {
      const [{ value = 0 } = { value: 0 }] = await db.select({ value: count() })
        .from(inlineProtocolAuthKeys)
        .where(eq(inlineProtocolAuthKeys.keyEncryptionKeyId, keyEncryptionKeyId))
      return value
    } catch (cause) {
      throw new InlineProtocolKeyStoreError({ operation: "count_key_encryption_key_usage", cause })
    }
  }

  async authorize(authKeyId: Uint8Array, userId: number, accountSessionId: number): Promise<boolean> {
    try {
      const updated = await db.update(inlineProtocolAuthKeys).set({
        userId,
        accountSessionId,
        authorizedAt: new Date(),
        lastUsedAt: new Date(),
      }).where(and(
        eq(inlineProtocolAuthKeys.authKeyId, Buffer.from(authKeyId)),
        isNull(inlineProtocolAuthKeys.revokedAt),
        or(isNull(inlineProtocolAuthKeys.userId), eq(inlineProtocolAuthKeys.userId, userId)),
        or(isNull(inlineProtocolAuthKeys.accountSessionId), eq(inlineProtocolAuthKeys.accountSessionId, accountSessionId)),
      )).returning({ authKeyId: inlineProtocolAuthKeys.authKeyId })
      return updated.length === 1
    } catch (cause) {
      throw new InlineProtocolKeyStoreError({ operation: "authorize_permanent", cause })
    }
  }

  async rotateServerSalt(authKeyId: Uint8Array, currentServerSalt: bigint): Promise<boolean> {
    try {
      const existing = (await db.select({ currentServerSalt: inlineProtocolAuthKeys.currentServerSalt })
        .from(inlineProtocolAuthKeys)
        .where(and(
          eq(inlineProtocolAuthKeys.authKeyId, Buffer.from(authKeyId)),
          isNull(inlineProtocolAuthKeys.revokedAt),
        ))
        .limit(1))[0]
      if (!existing) return false
      const updated = await db.update(inlineProtocolAuthKeys).set({
        previousServerSalt: existing.currentServerSalt,
        currentServerSalt,
        serverSaltUpdatedAt: new Date(),
      }).where(and(
        eq(inlineProtocolAuthKeys.authKeyId, Buffer.from(authKeyId)),
        eq(inlineProtocolAuthKeys.currentServerSalt, existing.currentServerSalt),
        isNull(inlineProtocolAuthKeys.revokedAt),
      )).returning({ authKeyId: inlineProtocolAuthKeys.authKeyId })
      return updated.length === 1
    } catch (cause) {
      throw new InlineProtocolKeyStoreError({ operation: "rotate_server_salt", cause })
    }
  }

  async revoke(authKeyId: Uint8Array): Promise<boolean> {
    try {
      return db.transaction(async (tx) => {
        const now = new Date()
        const updated = await tx.update(inlineProtocolAuthKeys).set({ revokedAt: now }).where(and(
          eq(inlineProtocolAuthKeys.authKeyId, Buffer.from(authKeyId)),
          isNull(inlineProtocolAuthKeys.revokedAt),
        )).returning({ accountSessionId: inlineProtocolAuthKeys.accountSessionId })
        if (updated.length !== 1) return false
        const accountSessionId = updated[0]?.accountSessionId
        if (accountSessionId !== null && accountSessionId !== undefined) {
          await tx.update(sessions).set({ revoked: now }).where(and(
            eq(sessions.id, accountSessionId),
            isNull(sessions.revoked),
          ))
        }
        return true
      })
    } catch (cause) {
      throw new InlineProtocolKeyStoreError({ operation: "revoke_permanent", cause })
    }
  }
}

const AUTH_PEPPER_RETIREMENT_HORIZON_MS = 10 * 60 * 1_000

export const countInlineProtocolChallengesBlockingPepperRetirement = async (
  pepperKeyId: string,
  now = new Date(),
): Promise<number> => {
  try {
    const [{ value = 0 } = { value: 0 }] = await db.select({ value: count() })
      .from(inlineProtocolAuthChallenges)
      .where(and(
        eq(inlineProtocolAuthChallenges.pepperKeyId, pepperKeyId),
        or(
          and(
            isNull(inlineProtocolAuthChallenges.consumedAt),
            gt(inlineProtocolAuthChallenges.expiresAt, now),
          ),
          gt(
            inlineProtocolAuthChallenges.createdAt,
            new Date(now.getTime() - AUTH_PEPPER_RETIREMENT_HORIZON_MS),
          ),
        ),
      ))
    return value
  } catch (cause) {
    throw new InlineProtocolKeyStoreError({ operation: "count_auth_pepper_usage", cause })
  }
}

export type ReplayClaim =
  | { kind: "claimed" }
  | { kind: "in_flight" }
  | { kind: "completed"; resultBody: Uint8Array }
  | { kind: "digest_mismatch" }

export class InlineProtocolReplayRepository {
  constructor(private readonly storage: { cipher?: ReplayResultCipher; encryptWrites: boolean } = { encryptWrites: false }) {
    if (storage.encryptWrites && !storage.cipher) throw new InlineProtocolReplayError({ operation: "missing_result_cipher" })
  }

  private decode(identity: ReplayIdentity, body: Buffer, format: number): Uint8Array {
    if (format === 0) return Uint8Array.from(body)
    if (format !== 1 || !this.storage.cipher) throw new InlineProtocolReplayError({ operation: "unsupported_result_format" })
    return this.storage.cipher.decrypt(identity, body)
  }

  private encode(identity: ReplayIdentity, body: Uint8Array, previousFormat = 0) {
    // Compatible-reader rollback must never turn an encrypted result back into plaintext.
    if (this.storage.encryptWrites || previousFormat === 1) {
      if (!this.storage.cipher) throw new InlineProtocolReplayError({ operation: "missing_result_cipher" })
      return { resultBody: this.storage.cipher.encrypt(identity, body), resultFormat: 1 }
    }
    if (previousFormat !== 0) throw new InlineProtocolReplayError({ operation: "unsupported_result_format" })
    return { resultBody: Buffer.from(body), resultFormat: 0 }
  }

  async claim(input: {
    authKeyId: Uint8Array
    protocolSessionId: bigint
    messageId: bigint
    authenticatedBody: Uint8Array
    now?: Date
    ttlMs?: number
  }): Promise<ReplayClaim> {
    const digest = createHash("sha256").update(input.authenticatedBody).digest()
    const now = input.now ?? new Date()
    try {
      const inserted = await db.insert(inlineProtocolRequests).values({
        authKeyId: Buffer.from(input.authKeyId),
        protocolSessionId: input.protocolSessionId,
        messageId: input.messageId,
        requestDigest: digest,
        expiresAt: new Date(now.getTime() + (input.ttlMs ?? DEFAULT_REPLAY_TTL_MS)),
      }).onConflictDoNothing().returning({ messageId: inlineProtocolRequests.messageId })
      if (inserted.length === 1) return { kind: "claimed" }
      const existing = (await db.select({
        requestDigest: inlineProtocolRequests.requestDigest,
        resultBody: inlineProtocolRequests.resultBody,
        resultFormat: inlineProtocolRequests.resultFormat,
      }).from(inlineProtocolRequests).where(and(
        eq(inlineProtocolRequests.authKeyId, Buffer.from(input.authKeyId)),
        eq(inlineProtocolRequests.protocolSessionId, input.protocolSessionId),
        eq(inlineProtocolRequests.messageId, input.messageId),
      )).limit(1))[0]
      if (!existing) throw new InlineProtocolReplayError({ operation: "claim_lost" })
      if (existing.requestDigest.length !== digest.length || !timingSafeEqual(existing.requestDigest, digest)) {
        return { kind: "digest_mismatch" }
      }
      return existing.resultBody === null
        ? { kind: "in_flight" }
        : { kind: "completed", resultBody: this.decode(input, existing.resultBody, existing.resultFormat) }
    } catch (cause) {
      if (cause instanceof InlineProtocolReplayError) throw cause
      throw new InlineProtocolReplayError({ operation: "claim" })
    }
  }

  async complete(input: {
    authKeyId: Uint8Array
    protocolSessionId: bigint
    messageId: bigint
    resultBody: Uint8Array
  }): Promise<boolean> {
    if (input.resultBody.length > MAX_RESULT_BYTES) throw new InlineProtocolReplayError({ operation: "complete_size" })
    try {
      const updated = await db.update(inlineProtocolRequests).set({
        ...this.encode(input, input.resultBody),
        completedAt: new Date(),
      }).where(and(
        eq(inlineProtocolRequests.authKeyId, Buffer.from(input.authKeyId)),
        eq(inlineProtocolRequests.protocolSessionId, input.protocolSessionId),
        eq(inlineProtocolRequests.messageId, input.messageId),
        isNull(inlineProtocolRequests.resultBody),
      )).returning({ messageId: inlineProtocolRequests.messageId })
      return updated.length === 1
    } catch {
      throw new InlineProtocolReplayError({ operation: "complete" })
    }
  }

  async result(input: {
    authKeyId: Uint8Array
    protocolSessionId: bigint
    messageId: bigint
  }): Promise<Uint8Array | undefined> {
    try {
      const row = (await db.select({
        resultBody: inlineProtocolRequests.resultBody,
        resultFormat: inlineProtocolRequests.resultFormat,
      }).from(inlineProtocolRequests).where(and(
        eq(inlineProtocolRequests.authKeyId, Buffer.from(input.authKeyId)),
        eq(inlineProtocolRequests.protocolSessionId, input.protocolSessionId),
        eq(inlineProtocolRequests.messageId, input.messageId),
      )).limit(1))[0]
      return row?.resultBody === null || row?.resultBody === undefined
        ? undefined
        : this.decode(input, row.resultBody, row.resultFormat)
    } catch {
      throw new InlineProtocolReplayError({ operation: "result" })
    }
  }

  async isInFlight(input: {
    authKeyId: Uint8Array
    protocolSessionId: bigint
    messageId: bigint
  }): Promise<boolean> {
    try {
      const row = (await db.select({ messageId: inlineProtocolRequests.messageId })
        .from(inlineProtocolRequests)
        .where(and(
          eq(inlineProtocolRequests.authKeyId, Buffer.from(input.authKeyId)),
          eq(inlineProtocolRequests.protocolSessionId, input.protocolSessionId),
          eq(inlineProtocolRequests.messageId, input.messageId),
          isNull(inlineProtocolRequests.resultBody),
        )).limit(1))[0]
      return row !== undefined
    } catch {
      throw new InlineProtocolReplayError({ operation: "in_flight" })
    }
  }

  async replaceResult(input: {
    authKeyId: Uint8Array
    protocolSessionId: bigint
    messageId: bigint
    resultBody: Uint8Array
  }): Promise<boolean> {
    if (input.resultBody.length > MAX_RESULT_BYTES) throw new InlineProtocolReplayError({ operation: "replace_size" })
    try {
      return await db.transaction(async (tx) => {
        const identity = and(
          eq(inlineProtocolRequests.authKeyId, Buffer.from(input.authKeyId)),
          eq(inlineProtocolRequests.protocolSessionId, input.protocolSessionId),
          eq(inlineProtocolRequests.messageId, input.messageId),
        )
        const row = (await tx.select().from(inlineProtocolRequests).where(identity).for("update"))[0]
        if (!row?.resultBody) return false
        // Authenticate existing ciphertext before replacing it; corruption is never a cache miss.
        this.decode(input, row.resultBody, row.resultFormat)
        await tx.update(inlineProtocolRequests).set({
          ...this.encode(input, input.resultBody, row.resultFormat),
          completedAt: new Date(),
        }).where(identity)
        return true
      })
    } catch {
      throw new InlineProtocolReplayError({ operation: "replace_result" })
    }
  }

  /** Restartable local/operational tool primitive. Never runs as part of request handling. */
  async encryptCompletedBatch(limit = 10): Promise<number> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100 || !this.storage.encryptWrites || !this.storage.cipher) {
      throw new InlineProtocolReplayError({ operation: "encrypt_batch_configuration" })
    }
    try {
      return await db.transaction(async (tx) => {
        // Select identities only, then load one body at a time to bound retained response bytes.
        const rows = await tx.select({
          authKeyId: inlineProtocolRequests.authKeyId,
          protocolSessionId: inlineProtocolRequests.protocolSessionId,
          messageId: inlineProtocolRequests.messageId,
        }).from(inlineProtocolRequests)
          .where(and(eq(inlineProtocolRequests.resultFormat, 0), isNotNull(inlineProtocolRequests.resultBody)))
          .orderBy(inlineProtocolRequests.authKeyId, inlineProtocolRequests.protocolSessionId, inlineProtocolRequests.messageId)
          .limit(limit).for("update", { skipLocked: true })
        for (const identity of rows) {
          const condition = and(
            eq(inlineProtocolRequests.authKeyId, identity.authKeyId),
            eq(inlineProtocolRequests.protocolSessionId, identity.protocolSessionId),
            eq(inlineProtocolRequests.messageId, identity.messageId),
            eq(inlineProtocolRequests.resultFormat, 0),
          )
          const row = (await tx.select({ body: inlineProtocolRequests.resultBody }).from(inlineProtocolRequests).where(condition))[0]
          if (!row?.body) throw new InlineProtocolReplayError({ operation: "encrypt_batch_lost_row" })
          await tx.update(inlineProtocolRequests).set(this.encode(identity, row.body)).where(condition)
        }
        return rows.length
      })
    } catch {
      throw new InlineProtocolReplayError({ operation: "encrypt_completed_batch" })
    }
  }

  /**
   * Deletes only completed replay results. An expired in-flight claim may still
   * represent a running application handler, so deleting it without a durable
   * execution-owner fence would make its eventual completion ambiguous.
   */
  async cleanupExpiredCompleted(now = new Date(), limit = 1_000): Promise<number> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 10_000) {
      throw new InlineProtocolReplayError({ operation: "cleanup_limit" })
    }
    try {
      const deleted = await db.execute<{ messageId: bigint }>(sql`
        with expired as (
          select ctid
          from ${inlineProtocolRequests}
          where ${inlineProtocolRequests.expiresAt} <= ${now.toISOString()}::timestamptz
            and ${inlineProtocolRequests.resultBody} is not null
          order by ${inlineProtocolRequests.expiresAt}
          limit ${limit}
          for update skip locked
        )
        delete from ${inlineProtocolRequests} as request
        using expired
        where request.ctid = expired.ctid
        returning request.message_id as "messageId"
      `)
      return deleted.length
    } catch (cause) {
      if (cause instanceof InlineProtocolReplayError) throw cause
      throw new InlineProtocolReplayError({ operation: "cleanup_completed" })
    }
  }
}
