import {
  and,
  asc,
  count,
  desc,
  eq,
  gt,
  isNull,
  inArray,
  lt,
  or,
} from "drizzle-orm"
import { randomBytes } from "node:crypto"
import { db } from "@in/server/db"
import {
  inlineProtocolAuthKeys,
  inlineUploadParts,
  inlineUploads,
  sessions,
  type DbInlineUpload,
} from "@in/server/db/schema"

export const INLINE_UPLOAD_PART_SIZE = 512 * 1_024
export const INLINE_UPLOAD_MAX_PARTS = 1_000
export const INLINE_UPLOAD_IDLE_TTL_MS = 24 * 60 * 60 * 1_000
export const INLINE_UPLOAD_HARD_TTL_MS = 7 * 24 * 60 * 60 * 1_000
const INLINE_UPLOAD_PROCESSING_LEASE_MS = 5 * 60 * 1_000

export type InlineUploadKind = "photo" | "video" | "document" | "voice"

export type InlineUploadOwner = {
  userId: number
  accountSessionId: number
  permanentAuthKeyId: Uint8Array
}

export type InlineUploadMetadata = {
  clientUploadId: Uint8Array
  fileName: string
  mimeType: string
  byteCount: bigint
  sha256: Uint8Array
  kind: InlineUploadKind
  thumbnailFileUniqueId?: string
  videoWidth?: number
  videoHeight?: number
  duration?: number
  isAnimated?: boolean
  hasAudio?: boolean
  waveform?: Uint8Array
}

export type InlineUploadRecord = DbInlineUpload & {
  acceptedParts: number[]
}

export type InlineUploadPartRecord = {
  partIndex: number
  byteCount: number
  sha256: Uint8Array
  objectKey: string
}

const sameBytes = (left: Uint8Array, right: Uint8Array): boolean =>
  Buffer.from(left).equals(Buffer.from(right))

const sameOptionalBytes = (left: Uint8Array | null, right?: Uint8Array): boolean =>
  left === null ? right === undefined : right !== undefined && sameBytes(left, right)

const sameMetadata = (row: DbInlineUpload, metadata: InlineUploadMetadata): boolean =>
  row.fileName === metadata.fileName &&
  row.mimeType === metadata.mimeType &&
  row.byteCount === metadata.byteCount &&
  sameBytes(row.sha256, metadata.sha256) &&
  row.kind === metadata.kind &&
  row.thumbnailFileUniqueId === (metadata.thumbnailFileUniqueId ?? null) &&
  row.videoWidth === (metadata.videoWidth ?? null) &&
  row.videoHeight === (metadata.videoHeight ?? null) &&
  row.duration === (metadata.duration ?? null) &&
  row.isAnimated === (metadata.isAnimated ?? null) &&
  row.hasAudio === (metadata.hasAudio ?? null) &&
  sameOptionalBytes(row.waveform, metadata.waveform)

const acceptedPartsFor = async (uploadDbId: number): Promise<number[]> =>
  (await db.select({ partIndex: inlineUploadParts.partIndex })
    .from(inlineUploadParts)
    .where(eq(inlineUploadParts.uploadDbId, uploadDbId))
    .orderBy(asc(inlineUploadParts.partIndex)))
    .map(({ partIndex }) => partIndex)

export class InlineUploadRepository {
  async hasClientUpload(owner: InlineUploadOwner, clientUploadId: Uint8Array): Promise<boolean> {
    if (clientUploadId.length !== 16) return false
    const row = (await db.select({ id: inlineUploads.id }).from(inlineUploads).where(and(
      eq(inlineUploads.userId, owner.userId),
      eq(inlineUploads.accountSessionId, owner.accountSessionId),
      eq(inlineUploads.permanentAuthKeyId, Buffer.from(owner.permanentAuthKeyId)),
      eq(inlineUploads.clientUploadId, Buffer.from(clientUploadId)),
    )).limit(1))[0]
    return row !== undefined
  }

  async activeCount(owner: InlineUploadOwner): Promise<number> {
    const now = new Date()
    const [{ value = 0 } = { value: 0 }] = await db.select({ value: count() })
      .from(inlineUploads)
      .where(and(
        eq(inlineUploads.userId, owner.userId),
        eq(inlineUploads.accountSessionId, owner.accountSessionId),
        eq(inlineUploads.permanentAuthKeyId, Buffer.from(owner.permanentAuthKeyId)),
        inArray(inlineUploads.status, ["uploading", "processing"]),
        gt(inlineUploads.expiresAt, now),
        gt(inlineUploads.hardExpiresAt, now),
      ))
    return value
  }

  async resolveOwner(input: {
    userId: number
    accountSessionId: number
    permanentAuthKeyId?: Uint8Array
  }): Promise<InlineUploadOwner | undefined> {
    const now = new Date()
    const rows = await db.select({
      permanentAuthKeyId: inlineProtocolAuthKeys.authKeyId,
    }).from(inlineProtocolAuthKeys)
      .innerJoin(sessions, and(
        eq(sessions.id, input.accountSessionId),
        eq(sessions.userId, input.userId),
        isNull(sessions.revoked),
      ))
      .where(and(
        eq(inlineProtocolAuthKeys.userId, input.userId),
        eq(inlineProtocolAuthKeys.accountSessionId, input.accountSessionId),
        isNull(inlineProtocolAuthKeys.revokedAt),
        or(isNull(inlineProtocolAuthKeys.expiresAt), gt(inlineProtocolAuthKeys.expiresAt, now)),
        input.permanentAuthKeyId
          ? eq(inlineProtocolAuthKeys.authKeyId, Buffer.from(input.permanentAuthKeyId))
          : undefined,
      ))
      .orderBy(desc(inlineProtocolAuthKeys.createdAt))
      .limit(1)
    const row = rows[0]
    return row ? {
      userId: input.userId,
      accountSessionId: input.accountSessionId,
      permanentAuthKeyId: Uint8Array.from(row.permanentAuthKeyId),
    } : undefined
  }

  async create(owner: InlineUploadOwner, metadata: InlineUploadMetadata): Promise<{
    upload: InlineUploadRecord
    created: boolean
  }> {
    const now = new Date()
    const uploadId = randomBytes(16)
    const partCount = Number((metadata.byteCount + BigInt(INLINE_UPLOAD_PART_SIZE - 1)) /
      BigInt(INLINE_UPLOAD_PART_SIZE))
    const [inserted] = await db.insert(inlineUploads).values({
      uploadId,
      clientUploadId: Buffer.from(metadata.clientUploadId),
      permanentAuthKeyId: Buffer.from(owner.permanentAuthKeyId),
      userId: owner.userId,
      accountSessionId: owner.accountSessionId,
      fileName: metadata.fileName,
      mimeType: metadata.mimeType,
      byteCount: metadata.byteCount,
      sha256: Buffer.from(metadata.sha256),
      kind: metadata.kind,
      thumbnailFileUniqueId: metadata.thumbnailFileUniqueId,
      videoWidth: metadata.videoWidth,
      videoHeight: metadata.videoHeight,
      duration: metadata.duration,
      isAnimated: metadata.isAnimated,
      hasAudio: metadata.hasAudio,
      waveform: metadata.waveform ? Buffer.from(metadata.waveform) : undefined,
      partSize: INLINE_UPLOAD_PART_SIZE,
      partCount,
      expiresAt: new Date(now.getTime() + INLINE_UPLOAD_IDLE_TTL_MS),
      hardExpiresAt: new Date(now.getTime() + INLINE_UPLOAD_HARD_TTL_MS),
    }).onConflictDoNothing({
      target: [inlineUploads.accountSessionId, inlineUploads.clientUploadId],
    }).returning()

    const row = inserted ?? (await db.select().from(inlineUploads).where(and(
      eq(inlineUploads.accountSessionId, owner.accountSessionId),
      eq(inlineUploads.clientUploadId, Buffer.from(metadata.clientUploadId)),
    )).limit(1))[0]
    if (!row || row.userId !== owner.userId ||
        !sameBytes(row.permanentAuthKeyId, owner.permanentAuthKeyId) ||
        !sameMetadata(row, metadata)) {
      throw new InlineUploadMetadataConflictError()
    }
    return {
      upload: { ...row, acceptedParts: await acceptedPartsFor(row.id) },
      created: inserted !== undefined,
    }
  }

  async get(uploadId: Uint8Array, owner: InlineUploadOwner): Promise<InlineUploadRecord | undefined> {
    if (uploadId.length !== 16) return undefined
    const row = (await db.select().from(inlineUploads).where(and(
      eq(inlineUploads.uploadId, Buffer.from(uploadId)),
      eq(inlineUploads.userId, owner.userId),
      eq(inlineUploads.accountSessionId, owner.accountSessionId),
      eq(inlineUploads.permanentAuthKeyId, Buffer.from(owner.permanentAuthKeyId)),
    )).limit(1))[0]
    return row ? { ...row, acceptedParts: await acceptedPartsFor(row.id) } : undefined
  }

  async getPart(uploadDbId: number, partIndex: number): Promise<InlineUploadPartRecord | undefined> {
    const row = (await db.select().from(inlineUploadParts).where(and(
      eq(inlineUploadParts.uploadDbId, uploadDbId),
      eq(inlineUploadParts.partIndex, partIndex),
    )).limit(1))[0]
    return row ? { ...row, sha256: Uint8Array.from(row.sha256) } : undefined
  }

  async completedPhotoId(fileUniqueId: string, owner: InlineUploadOwner): Promise<number | undefined> {
    const row = (await db.select({ mediaId: inlineUploads.resultMediaId }).from(inlineUploads).where(and(
      eq(inlineUploads.resultFileUniqueId, fileUniqueId),
      eq(inlineUploads.kind, "photo"),
      eq(inlineUploads.status, "complete"),
      eq(inlineUploads.userId, owner.userId),
      eq(inlineUploads.accountSessionId, owner.accountSessionId),
      eq(inlineUploads.permanentAuthKeyId, Buffer.from(owner.permanentAuthKeyId)),
    )).limit(1))[0]
    return row?.mediaId ?? undefined
  }

  async acceptPart(input: {
    upload: InlineUploadRecord
    partIndex: number
    byteCount: number
    sha256: Uint8Array
    objectKey: string
  }): Promise<"accepted" | "already-present" | "conflict" | "terminal"> {
    return db.transaction(async (tx) => {
      const now = new Date()
      const [locked] = await tx.select().from(inlineUploads)
        .where(eq(inlineUploads.id, input.upload.id)).for("update").limit(1)
      if (!locked || locked.status !== "uploading" || locked.expiresAt <= now ||
          locked.hardExpiresAt <= now) return "terminal"
      const [inserted] = await tx.insert(inlineUploadParts).values({
        uploadDbId: locked.id,
        partIndex: input.partIndex,
        byteCount: input.byteCount,
        sha256: Buffer.from(input.sha256),
        objectKey: input.objectKey,
      }).onConflictDoNothing({
        target: [inlineUploadParts.uploadDbId, inlineUploadParts.partIndex],
      }).returning({ partIndex: inlineUploadParts.partIndex })
      if (!inserted) {
        const existing = (await tx.select().from(inlineUploadParts).where(and(
          eq(inlineUploadParts.uploadDbId, locked.id),
          eq(inlineUploadParts.partIndex, input.partIndex),
        )).limit(1))[0]
        if (!existing || existing.byteCount !== input.byteCount ||
            !sameBytes(existing.sha256, input.sha256)) return "conflict"
        return "already-present"
      }
      const nextExpiry = new Date(Math.min(
        locked.hardExpiresAt.getTime(),
        now.getTime() + INLINE_UPLOAD_IDLE_TTL_MS,
      ))
      await tx.update(inlineUploads).set({ lastPartAt: now, expiresAt: nextExpiry })
        .where(eq(inlineUploads.id, locked.id))
      return "accepted"
    })
  }

  async claimFinish(uploadId: Uint8Array, owner: InlineUploadOwner): Promise<
    | { kind: "missing"; partIndices: number[] }
    | { kind: "processing" }
    | { kind: "claimed"; upload: InlineUploadRecord; lockToken: Uint8Array; parts: InlineUploadPartRecord[] }
    | { kind: "complete"; upload: InlineUploadRecord }
    | { kind: "failed"; upload: InlineUploadRecord }
    | { kind: "rejected" }
  > {
    if (uploadId.length !== 16) return { kind: "rejected" }
    return db.transaction(async (tx) => {
      const now = new Date()
      const [row] = await tx.select().from(inlineUploads).where(and(
        eq(inlineUploads.uploadId, Buffer.from(uploadId)),
        eq(inlineUploads.userId, owner.userId),
        eq(inlineUploads.accountSessionId, owner.accountSessionId),
        eq(inlineUploads.permanentAuthKeyId, Buffer.from(owner.permanentAuthKeyId)),
      )).for("update").limit(1)
      if (!row || row.status === "canceled" || row.expiresAt <= now || row.hardExpiresAt <= now) {
        return { kind: "rejected" } as const
      }
      const parts = await tx.select().from(inlineUploadParts)
        .where(eq(inlineUploadParts.uploadDbId, row.id))
        .orderBy(asc(inlineUploadParts.partIndex))
      const upload = { ...row, acceptedParts: parts.map(({ partIndex }) => partIndex) }
      if (row.status === "complete") return { kind: "complete", upload } as const
      if (row.status === "failed") return { kind: "failed", upload } as const
      if (row.status === "processing" && row.lockedAt &&
          row.lockedAt > new Date(now.getTime() - INLINE_UPLOAD_PROCESSING_LEASE_MS)) {
        return { kind: "processing" } as const
      }
      const accepted = new Set(parts.map(({ partIndex }) => partIndex))
      const missing = Array.from({ length: row.partCount }, (_, index) => index)
        .filter((index) => !accepted.has(index))
      if (missing.length > 0) return { kind: "missing", partIndices: missing } as const
      const lockToken = randomBytes(32)
      await tx.update(inlineUploads).set({
        status: "processing",
        lockToken,
        lockedAt: now,
      }).where(eq(inlineUploads.id, row.id))
      return {
        kind: "claimed",
        upload,
        lockToken: Uint8Array.from(lockToken),
        parts: parts.map((part) => ({ ...part, sha256: Uint8Array.from(part.sha256) })),
      } as const
    })
  }

  async complete(input: {
    uploadDbId: number
    lockToken: Uint8Array
    fileUniqueId: string
    mediaId: number
  }): Promise<boolean> {
    const rows = await db.update(inlineUploads).set({
      status: "complete",
      resultFileUniqueId: input.fileUniqueId,
      resultMediaId: input.mediaId,
      completedAt: new Date(),
      lockToken: null,
      lockedAt: null,
    }).where(and(
      eq(inlineUploads.id, input.uploadDbId),
      eq(inlineUploads.status, "processing"),
      eq(inlineUploads.lockToken, Buffer.from(input.lockToken)),
    )).returning({ id: inlineUploads.id })
    return rows.length === 1
  }

  async fail(input: {
    uploadDbId: number
    lockToken: Uint8Array
    code: string
    retryable: boolean
  }): Promise<void> {
    await db.update(inlineUploads).set({
      status: "failed",
      failureCode: input.code,
      failureRetryable: input.retryable,
      lockToken: null,
      lockedAt: null,
    }).where(and(
      eq(inlineUploads.id, input.uploadDbId),
      eq(inlineUploads.status, "processing"),
      eq(inlineUploads.lockToken, Buffer.from(input.lockToken)),
    ))
  }

  async release(input: { uploadDbId: number; lockToken: Uint8Array }): Promise<void> {
    await db.update(inlineUploads).set({
      status: "uploading",
      lockToken: null,
      lockedAt: null,
    }).where(and(
      eq(inlineUploads.id, input.uploadDbId),
      eq(inlineUploads.status, "processing"),
      eq(inlineUploads.lockToken, Buffer.from(input.lockToken)),
    ))
  }

  async cancel(uploadId: Uint8Array, owner: InlineUploadOwner): Promise<{
    canceled: boolean
    alreadyTerminal: boolean
  } | undefined> {
    if (uploadId.length !== 16) return undefined
    return db.transaction(async (tx) => {
      const [row] = await tx.select().from(inlineUploads).where(and(
        eq(inlineUploads.uploadId, Buffer.from(uploadId)),
        eq(inlineUploads.userId, owner.userId),
        eq(inlineUploads.accountSessionId, owner.accountSessionId),
        eq(inlineUploads.permanentAuthKeyId, Buffer.from(owner.permanentAuthKeyId)),
      )).for("update").limit(1)
      if (!row) return undefined
      if (row.status === "complete" || row.status === "failed" || row.status === "canceled") {
        return { canceled: row.status === "canceled", alreadyTerminal: true }
      }
      await tx.update(inlineUploads).set({
        status: "canceled",
        canceledAt: new Date(),
        lockToken: null,
        lockedAt: null,
      }).where(eq(inlineUploads.id, row.id))
      return { canceled: true, alreadyTerminal: false }
    })
  }

  async listExpired(limit = 100): Promise<InlineUploadRecord[]> {
    const now = new Date()
    const rows = await db.select().from(inlineUploads)
      .where(or(lt(inlineUploads.expiresAt, now), lt(inlineUploads.hardExpiresAt, now)))
      .orderBy(asc(inlineUploads.expiresAt))
      .limit(limit)
    return Promise.all(rows.map(async (row) => ({
      ...row,
      acceptedParts: await acceptedPartsFor(row.id),
    })))
  }

  async parts(uploadDbId: number): Promise<InlineUploadPartRecord[]> {
    return (await db.select().from(inlineUploadParts)
      .where(eq(inlineUploadParts.uploadDbId, uploadDbId))
      .orderBy(asc(inlineUploadParts.partIndex)))
      .map((part) => ({ ...part, sha256: Uint8Array.from(part.sha256) }))
  }

  async remove(uploadDbId: number): Promise<void> {
    await db.delete(inlineUploads).where(eq(inlineUploads.id, uploadDbId))
  }
}

export class InlineUploadMetadataConflictError extends Error {
  constructor() {
    super("The client upload identifier is already bound to different metadata")
    this.name = "InlineUploadMetadataConflictError"
  }
}
