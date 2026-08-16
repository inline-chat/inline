import { authKeyId as deriveAuthKeyId, equalBytes, type EstablishedAuthorizationKey } from "@inline-chat/protocol/secure"
import { and, count, eq, exists, gt, isNull, lte, ne, or, sql } from "drizzle-orm"
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

const DEFAULT_REPLAY_TTL_MS = 10 * 60 * 1_000
const MAX_RESULT_BYTES = 16 * 1024 * 1024

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
      const reclaimed = await db.update(inlineProtocolRequests).set({
        requestDigest: digest,
        resultBody: null,
        claimedAt: now,
        completedAt: null,
        expiresAt: new Date(now.getTime() + (input.ttlMs ?? DEFAULT_REPLAY_TTL_MS)),
      }).where(and(
        eq(inlineProtocolRequests.authKeyId, Buffer.from(input.authKeyId)),
        eq(inlineProtocolRequests.protocolSessionId, input.protocolSessionId),
        eq(inlineProtocolRequests.messageId, input.messageId),
        lte(inlineProtocolRequests.expiresAt, now),
      )).returning({ messageId: inlineProtocolRequests.messageId })
      if (reclaimed.length === 1) return { kind: "claimed" }
      const existing = (await db.select({
        requestDigest: inlineProtocolRequests.requestDigest,
        resultBody: inlineProtocolRequests.resultBody,
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
        : { kind: "completed", resultBody: Uint8Array.from(existing.resultBody) }
    } catch (cause) {
      if (cause instanceof InlineProtocolReplayError) throw cause
      throw new InlineProtocolReplayError({ operation: "claim", cause })
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
        resultBody: Buffer.from(input.resultBody),
        completedAt: new Date(),
      }).where(and(
        eq(inlineProtocolRequests.authKeyId, Buffer.from(input.authKeyId)),
        eq(inlineProtocolRequests.protocolSessionId, input.protocolSessionId),
        eq(inlineProtocolRequests.messageId, input.messageId),
        isNull(inlineProtocolRequests.resultBody),
      )).returning({ messageId: inlineProtocolRequests.messageId })
      return updated.length === 1
    } catch (cause) {
      throw new InlineProtocolReplayError({ operation: "complete", cause })
    }
  }
}
