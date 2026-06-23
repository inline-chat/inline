import { createHash } from "node:crypto"

import { db } from "@in/server/db"
import { richMediaPublicUrlFailures } from "@in/server/db/schema"
import { and, eq, gt } from "drizzle-orm"

export type RichMediaPublicUrlKind = "photo" | "video" | "document" | "voice"

export type RichMediaPublicUrlBackoff = {
  failureCount: number
  retryAfter: Date
}

export type RichMediaPublicUrlFailureStore = {
  activeBackoff(input: {
    kind: RichMediaPublicUrlKind
    publicUrl: string
    now: Date
  }): Promise<RichMediaPublicUrlBackoff | null>
  recordFailure(input: {
    kind: RichMediaPublicUrlKind
    publicUrl: string
    reason: string
    now: Date
  }): Promise<void>
  clearFailure(input: {
    kind: RichMediaPublicUrlKind
    publicUrl: string
  }): Promise<void>
}

const backoffStepsMs = [
  5 * 60 * 1000,
  15 * 60 * 1000,
  60 * 60 * 1000,
  6 * 60 * 60 * 1000,
  24 * 60 * 60 * 1000,
]
const maxErrorLength = 512

export const dbRichMediaPublicUrlFailureStore: RichMediaPublicUrlFailureStore = {
  async activeBackoff(input) {
    const [row] = await db
      .select({
        failureCount: richMediaPublicUrlFailures.failureCount,
        retryAfter: richMediaPublicUrlFailures.retryAfter,
      })
      .from(richMediaPublicUrlFailures)
      .where(
        and(
          eq(richMediaPublicUrlFailures.kind, input.kind),
          eq(richMediaPublicUrlFailures.urlHash, hashPublicMediaUrl(input.publicUrl)),
          gt(richMediaPublicUrlFailures.retryAfter, input.now),
        ),
      )
      .limit(1)

    return row ?? null
  },

  async recordFailure(input) {
    const now = input.now
    const urlHash = hashPublicMediaUrl(input.publicUrl)
    const [existing] = await db
      .select({ failureCount: richMediaPublicUrlFailures.failureCount })
      .from(richMediaPublicUrlFailures)
      .where(and(eq(richMediaPublicUrlFailures.kind, input.kind), eq(richMediaPublicUrlFailures.urlHash, urlHash)))
      .limit(1)

    const failureCount = Math.max(1, (existing?.failureCount ?? 0) + 1)
    const retryAfter = new Date(now.getTime() + backoffMsForFailureCount(failureCount))
    const values = {
      kind: input.kind,
      urlHash,
      urlHost: safeUrlHost(input.publicUrl),
      failureCount,
      lastError: truncateError(input.reason),
      lastFailedAt: now,
      retryAfter,
      updatedAt: now,
    }

    await db
      .insert(richMediaPublicUrlFailures)
      .values(values)
      .onConflictDoUpdate({
        target: [richMediaPublicUrlFailures.kind, richMediaPublicUrlFailures.urlHash],
        set: {
          urlHost: values.urlHost,
          failureCount: values.failureCount,
          lastError: values.lastError,
          lastFailedAt: values.lastFailedAt,
          retryAfter: values.retryAfter,
          updatedAt: values.updatedAt,
        },
      })
  },

  async clearFailure(input) {
    await db
      .delete(richMediaPublicUrlFailures)
      .where(
        and(
          eq(richMediaPublicUrlFailures.kind, input.kind),
          eq(richMediaPublicUrlFailures.urlHash, hashPublicMediaUrl(input.publicUrl)),
        ),
      )
  },
}

export function hashPublicMediaUrl(url: string): Buffer {
  return createHash("sha256").update(url).digest()
}

export function backoffMsForFailureCount(failureCount: number): number {
  const index = Math.max(0, Math.min(failureCount - 1, backoffStepsMs.length - 1))
  return backoffStepsMs[index]!
}

function truncateError(reason: string): string {
  const normalized = reason.replace(/\s+/g, " ").trim()
  return normalized.length > maxErrorLength ? normalized.slice(0, maxErrorLength) : normalized
}

function safeUrlHost(value: string): string | null {
  try {
    return new URL(value).host
  } catch {
    return null
  }
}
