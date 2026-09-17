import { and, asc, eq, gt, isNotNull, ne } from "drizzle-orm"
import { db } from "../../src/db"
import { messages } from "../../src/db/schema/messages"
import { decrypt, encrypt } from "../../src/modules/encryption/encryption"

export type BackfillSummary = {
  scanned: number; migrated: number; verified: number; conflicts: number; lastId: string; done: boolean
}

/** One bounded batch. No content, ciphertext or database errors leave this helper's result. */
export async function backfillMessageTextBatch(options: {
  apply: boolean; afterId?: bigint; batchSize?: number
}): Promise<BackfillSummary> {
  const size = options.batchSize ?? 100
  const afterId = options.afterId ?? 0n
  if (!Number.isSafeInteger(size) || size < 1 || size > 500 || afterId < 0n || afterId > 9_223_372_036_854_775_807n) {
    throw new Error("Invalid backfill bounds")
  }
  return db.transaction(async (tx) => {
    const rows = await tx.select({
      id: messages.globalId, text: messages.text,
      encrypted: messages.textEncrypted, iv: messages.textIv, authTag: messages.textTag,
    }).from(messages).where(and(gt(messages.globalId, afterId), isNotNull(messages.text), ne(messages.text, "")))
      .orderBy(asc(messages.globalId)).limit(size).for(options.apply ? "update" : "share")
    const result: BackfillSummary = { scanned: rows.length, migrated: 0, verified: 0, conflicts: 0,
      lastId: (rows.at(-1)?.id ?? afterId).toString(), done: rows.length < size }
    for (const row of rows) {
      // Partial or disagreeing ciphertext is never overwritten by guessing which copy is authoritative.
      const hasCipher = row.encrypted !== null || row.iv !== null || row.authTag !== null
      try {
        if (row.text === null) continue
        let sealed
        if (hasCipher) {
          if (!row.encrypted || !row.iv || !row.authTag) { result.conflicts++; continue }
          sealed = { encrypted: row.encrypted, iv: row.iv, authTag: row.authTag }
          if (decrypt(sealed) !== row.text) { result.conflicts++; continue }
        } else {
          sealed = encrypt(row.text)
          if (decrypt(sealed) !== row.text) { result.conflicts++; continue }
        }
        if (!options.apply) { result.verified++; continue }
        if (!hasCipher) {
          await tx.update(messages).set({ textEncrypted: sealed.encrypted, textIv: sealed.iv, textTag: sealed.authTag })
            .where(eq(messages.globalId, row.id))
        }
        // Verify the persisted representation under the same row lock before clearing its source.
        const [stored] = await tx.select({ encrypted: messages.textEncrypted, iv: messages.textIv, authTag: messages.textTag })
          .from(messages).where(eq(messages.globalId, row.id))
        if (!stored?.encrypted || !stored.iv || !stored.authTag ||
          decrypt({ encrypted: stored.encrypted, iv: stored.iv, authTag: stored.authTag }) !== row.text) {
          throw new Error("Persisted encryption verification failed")
        }
        await tx.update(messages).set({ text: null }).where(eq(messages.globalId, row.id))
        result.migrated++
      } catch (error) {
        // SQL/verification errors during mutation abort the whole batch; callers must not print them.
        if (options.apply) throw error
        result.conflicts++
      }
    }
    return result
  })
}
