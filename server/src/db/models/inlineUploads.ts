import {
  and,
  asc,
  count,
  desc,
  eq,
  getTableColumns,
  gt,
  isNotNull,
  isNull,
  inArray,
  lt,
  lte,
  or,
  sql,
} from "drizzle-orm"
import { createHash, randomBytes } from "node:crypto"
import { db } from "@in/server/db"
import {
  documents,
  files,
  inlineProtocolAuthKeys,
  inlineUploadParts,
  inlineUploadStorageParts,
  inlineUploads,
  photos,
  photoSizes,
  sessions,
  videos,
  voices,
  type DbInlineUpload,
} from "@in/server/db/schema"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { INLINE_TRANSFER_PART_SIZE, INLINE_UPLOAD_MAX_PARTS } from "@inline-chat/protocol/transfers"

export const INLINE_UPLOAD_PART_SIZE = INLINE_TRANSFER_PART_SIZE
export { INLINE_UPLOAD_MAX_PARTS }
export const INLINE_UPLOAD_IDLE_TTL_MS = 24 * 60 * 60 * 1_000
export const INLINE_UPLOAD_HARD_TTL_MS = 7 * 24 * 60 * 60 * 1_000
// Provider operations are independently deadline-bounded and the lock token
// fences every durable transition. A short renewable lease keeps crash
// recovery prompt without allowing a stale worker to publish.
export const INLINE_UPLOAD_PROCESSING_LEASE_MS = 30_000
const INLINE_UPLOAD_PUBLICATION_PREFIX = "native-uploads/v1"

export type InlineUploadKind = "photo" | "video" | "document" | "voice"

export type InlineUploadOwner = {
  userId: number
  accountSessionId: number
  permanentAuthKeyId?: Uint8Array
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

export type InlineUploadStateRecord = InlineUploadRecord & {
  expired: boolean
}

export type InlineUploadPartRecord = {
  partIndex: number
  byteCount: number
  sha256: Uint8Array
  storedByteCount: number
  storedSha256: Uint8Array
  objectKey: string
}

export type InlineUploadStoragePartRecord = {
  storageUploadId: string
  partNumber: number
  storedByteCount: number
  storedSha256: Uint8Array
  etag: string
  completedAt: Date
}

export type InlineUploadPartTarget = Pick<
  DbInlineUpload,
  | "id"
  | "byteCount"
  | "partSize"
  | "partCount"
  | "status"
  | "expiresAt"
  | "hardExpiresAt"
  | "storageFormat"
> & {
  expired: boolean
}

export type InlineUploadStorageWork = {
  upload: InlineUploadRecord
  parts: InlineUploadPartRecord[]
  storageParts: InlineUploadStoragePartRecord[]
}

export type InlineUploadProcessingClaim = InlineUploadStorageWork & {
  lockToken: Uint8Array
}

export type InlineUploadPartAcceptance = {
  kind: "accepted" | "already-present" | "conflict" | "terminal"
  /** Object key already owned by the durable manifest, if one exists. */
  durableObjectKey?: string
}

export class InlineUploadAdmissionCapacityError extends Error {}
export class InlineUploadAdmissionOwnerInvalidError extends Error {}
export class InlineUploadStorageConflictError extends Error {}

type InlineUploadPublicationFile = {
  record: {
    fileUniqueId: string
    userId: number
    pathEncrypted: Buffer
    pathIv: Buffer
    pathTag: Buffer
    nameEncrypted: Buffer
    nameIv: Buffer
    nameTag: Buffer
    fileType: InlineUploadKind
    fileSize: number
    width?: number
    height?: number
    mimeType: string
  }
  path: string
  fileName: string
}

export type InlineUploadPublication = {
  file: InlineUploadPublicationFile
  media:
    | {
      kind: "photo"
      format: "jpeg" | "png"
      width: number
      height: number
      stripped: Buffer | null
      strippedIv: Buffer | null
      strippedTag: Buffer | null
    }
    | {
      kind: "video"
      width: number
      height: number
      duration: number
      photoId?: bigint
      isAnimated: boolean
      hasAudio?: boolean
    }
    | {
      kind: "document"
      fileName: Buffer
      fileNameIv: Buffer
      fileNameTag: Buffer
      photoId?: bigint
    }
    | {
      kind: "voice"
      duration: number
      waveform: Buffer
    }
}

export const inlineUploadFileUniqueId = (
  upload: { uploadId: Uint8Array; kind: string },
): string => {
  let typePrefix: string
  switch (upload.kind) {
    case "photo": typePrefix = "P"; break
    case "video": typePrefix = "V"; break
    case "document": typePrefix = "D"; break
    case "voice": typePrefix = "V"; break
    default: throw new Error("Upload kind is invalid")
  }
  const digest = createHash("sha256")
    .update(upload.kind)
    .update(upload.uploadId)
    .digest("base64url")
    .slice(0, 21)
  return `IN${typePrefix}${digest}`
}

export const inlineUploadPublicationPath = (fileUniqueId: string): string =>
  `${INLINE_UPLOAD_PUBLICATION_PREFIX}/${fileUniqueId}/body`

const sameBytes = (left: Uint8Array, right: Uint8Array): boolean =>
  Buffer.from(left).equals(Buffer.from(right))

const databaseTimestamp = (value: string | Date | undefined): Date => {
  const timestamp = value instanceof Date ? value : value ? new Date(value) : undefined
  if (!timestamp || Number.isNaN(timestamp.getTime())) throw new Error("Database clock unavailable")
  return timestamp
}

const sameOptionalBytes = (left: Uint8Array | null, right?: Uint8Array): boolean =>
  left === null ? right === undefined : right !== undefined && sameBytes(left, right)

const ownerKeyMatches = (owner: InlineUploadOwner) => owner.permanentAuthKeyId
  ? eq(inlineUploads.permanentAuthKeyId, Buffer.from(owner.permanentAuthKeyId))
  : isNull(inlineUploads.permanentAuthKeyId)

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

const uploadPartRecord = (part: typeof inlineUploadParts.$inferSelect): InlineUploadPartRecord => ({
  ...part,
  sha256: Uint8Array.from(part.sha256),
  // Old servers intentionally leave stored integrity null during the rolling
  // compatibility window. Such rows are legacy identity frames.
  storedByteCount: part.storedByteCount ?? part.byteCount,
  storedSha256: Uint8Array.from(part.storedSha256 ?? part.sha256),
})

const storagePartRecord = (
  part: typeof inlineUploadStorageParts.$inferSelect,
): InlineUploadStoragePartRecord => ({
  ...part,
  storedSha256: Uint8Array.from(part.storedSha256),
})

const decryptRequiredText = (input: {
  encrypted: Buffer | null
  iv: Buffer | null
  authTag: Buffer | null
}): string => {
  if (!input.encrypted || !input.iv || !input.authTag) {
    throw new InlineUploadPublicationConflictError()
  }
  try {
    return decrypt({ encrypted: input.encrypted, iv: input.iv, authTag: input.authTag })
  } catch {
    throw new InlineUploadPublicationConflictError()
  }
}

const assertPublicationFileMatches = (
  existing: typeof files.$inferSelect,
  expected: InlineUploadPublicationFile,
): void => {
  const record = expected.record
  if (existing.fileUniqueId !== record.fileUniqueId ||
      existing.userId !== record.userId ||
      existing.fileType !== record.fileType ||
      existing.fileSize !== record.fileSize ||
      existing.mimeType !== record.mimeType ||
      (existing.width ?? undefined) !== record.width ||
      (existing.height ?? undefined) !== record.height ||
      decryptRequiredText({
        encrypted: existing.pathEncrypted,
        iv: existing.pathIv,
        authTag: existing.pathTag,
      }) !== expected.path ||
      decryptRequiredText({
        encrypted: existing.nameEncrypted,
        iv: existing.nameIv,
        authTag: existing.nameTag,
      }) !== expected.fileName) {
    throw new InlineUploadPublicationConflictError()
  }
}

export class InlineUploadRepository {
  async hasClientUpload(owner: InlineUploadOwner, clientUploadId: Uint8Array): Promise<boolean> {
    if (clientUploadId.length !== 16) return false
    const row = (await db.select({ id: inlineUploads.id }).from(inlineUploads).where(and(
      eq(inlineUploads.userId, owner.userId),
      eq(inlineUploads.accountSessionId, owner.accountSessionId),
      ownerKeyMatches(owner),
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
        inArray(inlineUploads.status, ["uploading", "processing"]),
        gt(inlineUploads.expiresAt, now),
        gt(inlineUploads.hardExpiresAt, now),
      ))
    return value
  }

  async activeReservedBytes(owner: InlineUploadOwner): Promise<bigint> {
    const now = new Date()
    const rows = await db.select({ byteCount: inlineUploads.byteCount })
      .from(inlineUploads)
      .where(and(
        eq(inlineUploads.userId, owner.userId),
        eq(inlineUploads.accountSessionId, owner.accountSessionId),
        inArray(inlineUploads.status, ["uploading", "processing"]),
        gt(inlineUploads.expiresAt, now),
        gt(inlineUploads.hardExpiresAt, now),
      ))
    return rows.reduce((total, row) => total + row.byteCount, 0n)
  }

  async resolveOwner(input: {
    userId: number
    accountSessionId: number
    permanentAuthKeyId?: Uint8Array
  }): Promise<InlineUploadOwner | undefined> {
    if (!input.permanentAuthKeyId) {
      const activeSession = (await db.select({ id: sessions.id }).from(sessions).where(and(
        eq(sessions.id, input.accountSessionId),
        eq(sessions.userId, input.userId),
        isNull(sessions.revoked),
      )).limit(1))[0]
      return activeSession ? {
        userId: input.userId,
        accountSessionId: input.accountSessionId,
      } : undefined
    }

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
        eq(inlineProtocolAuthKeys.authKeyId, Buffer.from(input.permanentAuthKeyId)),
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

  async create(
    owner: InlineUploadOwner,
    metadata: InlineUploadMetadata,
    admission?: { maxActiveCount: number; maxReservedBytes: bigint },
  ): Promise<{
    upload: InlineUploadRecord
    created: boolean
  }> {
    return db.transaction(async (tx) => {
      const now = new Date()
      if (admission) {
        const [activeSession] = await tx.select({ id: sessions.id }).from(sessions).where(and(
          eq(sessions.id, owner.accountSessionId),
          eq(sessions.userId, owner.userId),
          isNull(sessions.revoked),
        )).for("update").limit(1)
        if (!activeSession) throw new InlineUploadAdmissionOwnerInvalidError()
      }

      const existing = (await tx.select().from(inlineUploads).where(and(
        eq(inlineUploads.accountSessionId, owner.accountSessionId),
        eq(inlineUploads.clientUploadId, Buffer.from(metadata.clientUploadId)),
      )).limit(1))[0]
      if (existing) {
        if (existing.userId !== owner.userId ||
            !sameOptionalBytes(existing.permanentAuthKeyId, owner.permanentAuthKeyId) ||
            !sameMetadata(existing, metadata)) {
          throw new InlineUploadMetadataConflictError()
        }
        const acceptedParts = (await tx.select({ partIndex: inlineUploadParts.partIndex })
          .from(inlineUploadParts)
          .where(eq(inlineUploadParts.uploadDbId, existing.id))
          .orderBy(asc(inlineUploadParts.partIndex)))
          .map(({ partIndex }) => partIndex)
        return { upload: { ...existing, acceptedParts }, created: false }
      }

      if (admission) {
        const active = await tx.select({ byteCount: inlineUploads.byteCount })
          .from(inlineUploads)
          .where(and(
            eq(inlineUploads.userId, owner.userId),
            eq(inlineUploads.accountSessionId, owner.accountSessionId),
            inArray(inlineUploads.status, ["uploading", "processing"]),
            gt(inlineUploads.expiresAt, now),
            gt(inlineUploads.hardExpiresAt, now),
          ))
        const reservedBytes = active.reduce((total, row) => total + row.byteCount, 0n)
        if (active.length >= admission.maxActiveCount ||
            reservedBytes + metadata.byteCount > admission.maxReservedBytes) {
          throw new InlineUploadAdmissionCapacityError()
        }
      }

      const uploadId = randomBytes(16)
      const partCount = Number((metadata.byteCount + BigInt(INLINE_UPLOAD_PART_SIZE - 1)) /
        BigInt(INLINE_UPLOAD_PART_SIZE))
      const resultFileUniqueId = inlineUploadFileUniqueId({ uploadId, kind: metadata.kind })
      const [inserted] = await tx.insert(inlineUploads).values({
        uploadId,
        clientUploadId: Buffer.from(metadata.clientUploadId),
        permanentAuthKeyId: owner.permanentAuthKeyId
          ? Buffer.from(owner.permanentAuthKeyId)
          : null,
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
        storageFormat: "identity_v1",
        resultFileUniqueId,
        expiresAt: new Date(now.getTime() + INLINE_UPLOAD_IDLE_TTL_MS),
        hardExpiresAt: new Date(now.getTime() + INLINE_UPLOAD_HARD_TTL_MS),
      }).onConflictDoNothing({
        target: [inlineUploads.accountSessionId, inlineUploads.clientUploadId],
      }).returning()

      const row = inserted ?? (await tx.select().from(inlineUploads).where(and(
        eq(inlineUploads.accountSessionId, owner.accountSessionId),
        eq(inlineUploads.clientUploadId, Buffer.from(metadata.clientUploadId)),
      )).limit(1))[0]
      if (!row || row.userId !== owner.userId ||
          !sameOptionalBytes(row.permanentAuthKeyId, owner.permanentAuthKeyId) ||
          !sameMetadata(row, metadata)) {
        throw new InlineUploadMetadataConflictError()
      }
      const acceptedParts = inserted
        ? []
        : (await tx.select({ partIndex: inlineUploadParts.partIndex })
          .from(inlineUploadParts)
          .where(eq(inlineUploadParts.uploadDbId, row.id))
          .orderBy(asc(inlineUploadParts.partIndex)))
          .map(({ partIndex }) => partIndex)
      return { upload: { ...row, acceptedParts }, created: inserted !== undefined }
    })
  }

  async get(uploadId: Uint8Array, owner: InlineUploadOwner): Promise<InlineUploadStateRecord | undefined> {
    if (uploadId.length !== 16) return undefined
    const result = (await db.select({
      ...getTableColumns(inlineUploads),
      databaseNow: sql<Date>`CURRENT_TIMESTAMP`,
    }).from(inlineUploads).where(and(
      eq(inlineUploads.uploadId, Buffer.from(uploadId)),
      eq(inlineUploads.userId, owner.userId),
      eq(inlineUploads.accountSessionId, owner.accountSessionId),
      ownerKeyMatches(owner),
    )).limit(1))[0]
    if (!result) return undefined
    const { databaseNow, ...row } = result
    const now = databaseTimestamp(databaseNow)
    return {
      ...row,
      acceptedParts: await acceptedPartsFor(row.id),
      expired: row.expiresAt <= now || row.hardExpiresAt <= now,
    }
  }

  async getPartTarget(
    uploadId: Uint8Array,
    owner: InlineUploadOwner,
  ): Promise<InlineUploadPartTarget | undefined> {
    if (uploadId.length !== 16) return undefined
    const result = (await db.select({
      id: inlineUploads.id,
      byteCount: inlineUploads.byteCount,
      partSize: inlineUploads.partSize,
      partCount: inlineUploads.partCount,
      status: inlineUploads.status,
      expiresAt: inlineUploads.expiresAt,
      hardExpiresAt: inlineUploads.hardExpiresAt,
      storageFormat: inlineUploads.storageFormat,
      databaseNow: sql<Date>`CURRENT_TIMESTAMP`,
    }).from(inlineUploads).where(and(
      eq(inlineUploads.uploadId, Buffer.from(uploadId)),
      eq(inlineUploads.userId, owner.userId),
      eq(inlineUploads.accountSessionId, owner.accountSessionId),
      ownerKeyMatches(owner),
    )).limit(1))[0]
    if (!result) return undefined
    const { databaseNow, ...upload } = result
    const now = databaseTimestamp(databaseNow)
    return {
      ...upload,
      expired: upload.expiresAt <= now || upload.hardExpiresAt <= now,
    }
  }

  async getPart(uploadDbId: number, partIndex: number): Promise<InlineUploadPartRecord | undefined> {
    const row = (await db.select().from(inlineUploadParts).where(and(
      eq(inlineUploadParts.uploadDbId, uploadDbId),
      eq(inlineUploadParts.partIndex, partIndex),
    )).limit(1))[0]
    return row ? uploadPartRecord(row) : undefined
  }

  async completedPhotoId(fileUniqueId: string, owner: InlineUploadOwner): Promise<number | undefined> {
    const row = (await db.select({ mediaId: inlineUploads.resultMediaId }).from(inlineUploads).where(and(
      eq(inlineUploads.resultFileUniqueId, fileUniqueId),
      eq(inlineUploads.kind, "photo"),
      eq(inlineUploads.status, "complete"),
      eq(inlineUploads.userId, owner.userId),
      eq(inlineUploads.accountSessionId, owner.accountSessionId),
      ownerKeyMatches(owner),
    )).limit(1))[0]
    return row?.mediaId ?? undefined
  }

  async acceptPart(input: {
    upload: Pick<InlineUploadRecord, "id">
    partIndex: number
    byteCount: number
    sha256: Uint8Array
    storedByteCount: number
    storedSha256: Uint8Array
    objectKey: string
  }): Promise<InlineUploadPartAcceptance> {
    return db.transaction(async (tx) => {
      const [clock] = await tx.execute<{ now: string | Date }>(sql`
        select CURRENT_TIMESTAMP as now
      `)
      const now = databaseTimestamp(clock?.now)
      const [locked] = await tx.select().from(inlineUploads)
        .where(eq(inlineUploads.id, input.upload.id)).for("update").limit(1)
      const existing = locked
        ? (await tx.select().from(inlineUploadParts).where(and(
          eq(inlineUploadParts.uploadDbId, locked.id),
          eq(inlineUploadParts.partIndex, input.partIndex),
        )).limit(1))[0]
        : undefined
      if (!locked || locked.status !== "uploading" || locked.expiresAt <= now ||
          locked.hardExpiresAt <= now) {
        return { kind: "terminal", durableObjectKey: existing?.objectKey }
      }
      const [inserted] = await tx.insert(inlineUploadParts).values({
        uploadDbId: locked.id,
        partIndex: input.partIndex,
        byteCount: input.byteCount,
        sha256: Buffer.from(input.sha256),
        storedByteCount: input.storedByteCount,
        storedSha256: Buffer.from(input.storedSha256),
        objectKey: input.objectKey,
      }).onConflictDoNothing({
        target: [inlineUploadParts.uploadDbId, inlineUploadParts.partIndex],
      }).returning({ partIndex: inlineUploadParts.partIndex })
      if (!inserted) {
        if (!existing || existing.byteCount !== input.byteCount ||
            !sameBytes(existing.sha256, input.sha256) ||
            (existing.storedByteCount ?? existing.byteCount) !== input.storedByteCount ||
            !sameBytes(existing.storedSha256 ?? existing.sha256, input.storedSha256)) {
          return { kind: "conflict", durableObjectKey: existing?.objectKey }
        }
        return { kind: "already-present", durableObjectKey: existing.objectKey }
      }
      const nextExpiry = new Date(Math.min(
        locked.hardExpiresAt.getTime(),
        now.getTime() + INLINE_UPLOAD_IDLE_TTL_MS,
      ))
      await tx.update(inlineUploads).set({ lastPartAt: now, expiresAt: nextExpiry })
        .where(eq(inlineUploads.id, locked.id))
      return { kind: "accepted", durableObjectKey: input.objectKey }
    })
  }

  async requestFinish(uploadId: Uint8Array, owner: InlineUploadOwner): Promise<
    | { kind: "missing"; partIndices: number[] }
    | { kind: "processing" }
    | { kind: "queued"; uploadDbId: number }
    | { kind: "complete"; upload: InlineUploadRecord }
    | { kind: "failed"; upload: InlineUploadRecord }
    | { kind: "rejected" }
  > {
    if (uploadId.length !== 16) return { kind: "rejected" }
    return db.transaction(async (tx) => {
      const [clock] = await tx.execute<{ now: string | Date }>(sql`
        select CURRENT_TIMESTAMP as now
      `)
      const now = databaseTimestamp(clock?.now)
      const [row] = await tx.select().from(inlineUploads).where(and(
        eq(inlineUploads.uploadId, Buffer.from(uploadId)),
        eq(inlineUploads.userId, owner.userId),
        eq(inlineUploads.accountSessionId, owner.accountSessionId),
        ownerKeyMatches(owner),
      )).for("update").limit(1)
      if (!row || row.status === "canceled") {
        return { kind: "rejected" } as const
      }
      const parts = await tx.select().from(inlineUploadParts)
        .where(eq(inlineUploadParts.uploadDbId, row.id))
        .orderBy(asc(inlineUploadParts.partIndex))
      const upload = { ...row, acceptedParts: parts.map(({ partIndex }) => partIndex) }
      if (row.status === "complete") return { kind: "complete", upload } as const
      if (row.status === "failed") return { kind: "failed", upload } as const
      if (row.status === "processing") return { kind: "processing" } as const
      if (row.expiresAt <= now || row.hardExpiresAt <= now) return { kind: "rejected" } as const
      const accepted = new Set(parts.map(({ partIndex }) => partIndex))
      const missing = Array.from({ length: row.partCount }, (_, index) => index)
        .filter((index) => !accepted.has(index))
      if (missing.length > 0) return { kind: "missing", partIndices: missing } as const
      const resultFileUniqueId = row.resultFileUniqueId ?? inlineUploadFileUniqueId(row)
      await tx.update(inlineUploads).set({
        status: "processing",
        resultFileUniqueId,
        retryAt: now,
        attempts: 0,
      }).where(eq(inlineUploads.id, row.id))
      return { kind: "queued", uploadDbId: row.id } as const
    })
  }

  async claimProcessing(uploadDbId?: number): Promise<InlineUploadProcessingClaim | undefined> {
    return db.transaction(async (tx) => {
      const [clock] = await tx.execute<{ now: string | Date }>(sql`
        select CURRENT_TIMESTAMP as now
      `)
      const now = databaseTimestamp(clock?.now)
      const staleAt = new Date(now.getTime() - INLINE_UPLOAD_PROCESSING_LEASE_MS)
      const conditions = [
        eq(inlineUploads.status, "processing"),
        or(isNull(inlineUploads.retryAt), lte(inlineUploads.retryAt, now)),
        or(
          isNull(inlineUploads.lockToken),
          isNull(inlineUploads.lockedAt),
          lte(inlineUploads.lockedAt, staleAt),
        ),
      ]
      if (uploadDbId !== undefined) conditions.push(eq(inlineUploads.id, uploadDbId))
      const [row] = await tx.select().from(inlineUploads)
        .where(and(...conditions))
        .orderBy(asc(inlineUploads.retryAt), asc(inlineUploads.createdAt))
        .limit(1)
        .for("update", { skipLocked: true })
      if (!row) return undefined

      const lockToken = randomBytes(32)
      const [claimed] = await tx.update(inlineUploads).set({
        lockToken,
        lockedAt: now,
      }).where(and(
        eq(inlineUploads.id, row.id),
        eq(inlineUploads.status, "processing"),
      )).returning()
      if (!claimed) return undefined

      const parts = await tx.select().from(inlineUploadParts)
        .where(eq(inlineUploadParts.uploadDbId, row.id))
        .orderBy(asc(inlineUploadParts.partIndex))
      const storageParts = claimed.storageUploadId
        ? await tx.select().from(inlineUploadStorageParts).where(and(
          eq(inlineUploadStorageParts.uploadDbId, row.id),
          eq(inlineUploadStorageParts.storageUploadId, claimed.storageUploadId),
        )).orderBy(asc(inlineUploadStorageParts.partNumber))
        : []
      return {
        upload: { ...claimed, acceptedParts: parts.map(({ partIndex }) => partIndex) },
        lockToken: Uint8Array.from(lockToken),
        parts: parts.map(uploadPartRecord),
        storageParts: storageParts.map(storagePartRecord),
      }
    })
  }

  async claimUploadingCompaction(uploadDbId: number): Promise<InlineUploadProcessingClaim | undefined> {
    return db.transaction(async (tx) => {
      const [clock] = await tx.execute<{ now: string | Date }>(sql`
        select CURRENT_TIMESTAMP as now
      `)
      const now = databaseTimestamp(clock?.now)
      const staleAt = new Date(now.getTime() - INLINE_UPLOAD_PROCESSING_LEASE_MS)
      const [row] = await tx.select().from(inlineUploads).where(and(
        eq(inlineUploads.id, uploadDbId),
        eq(inlineUploads.status, "uploading"),
        isNotNull(inlineUploads.storageFormat),
        or(
          isNull(inlineUploads.lockToken),
          isNull(inlineUploads.lockedAt),
          lte(inlineUploads.lockedAt, staleAt),
        ),
      )).for("update", { skipLocked: true }).limit(1)
      if (!row) return undefined

      const lockToken = randomBytes(32)
      const [claimed] = await tx.update(inlineUploads).set({
        lockToken,
        lockedAt: now,
      }).where(and(
        eq(inlineUploads.id, row.id),
        eq(inlineUploads.status, "uploading"),
      )).returning()
      if (!claimed) return undefined

      const parts = await tx.select().from(inlineUploadParts)
        .where(eq(inlineUploadParts.uploadDbId, row.id))
        .orderBy(asc(inlineUploadParts.partIndex))
      const storageParts = claimed.storageUploadId
        ? await tx.select().from(inlineUploadStorageParts).where(and(
          eq(inlineUploadStorageParts.uploadDbId, row.id),
          eq(inlineUploadStorageParts.storageUploadId, claimed.storageUploadId),
        )).orderBy(asc(inlineUploadStorageParts.partNumber))
        : []
      return {
        upload: { ...claimed, acceptedParts: parts.map(({ partIndex }) => partIndex) },
        lockToken: Uint8Array.from(lockToken),
        parts: parts.map(uploadPartRecord),
        storageParts: storageParts.map(storagePartRecord),
      }
    })
  }

  async getStorageWork(uploadDbId: number): Promise<InlineUploadStorageWork | undefined> {
    const row = (await db.select().from(inlineUploads).where(and(
      eq(inlineUploads.id, uploadDbId),
      inArray(inlineUploads.status, ["uploading", "processing"]),
    )).limit(1))[0]
    if (!row) return undefined
    const parts = await db.select().from(inlineUploadParts)
      .where(eq(inlineUploadParts.uploadDbId, row.id))
      .orderBy(asc(inlineUploadParts.partIndex))
    const storageParts = row.storageUploadId
      ? await db.select().from(inlineUploadStorageParts).where(and(
        eq(inlineUploadStorageParts.uploadDbId, row.id),
        eq(inlineUploadStorageParts.storageUploadId, row.storageUploadId),
      )).orderBy(asc(inlineUploadStorageParts.partNumber))
      : []
    return {
      upload: { ...row, acceptedParts: parts.map(({ partIndex }) => partIndex) },
      parts: parts.map(uploadPartRecord),
      storageParts: storageParts.map(storagePartRecord),
    }
  }

  async installStorageSession(input: {
    uploadDbId: number
    expectedStorageUploadId: string | null
    storageUploadId: string
    lockToken?: Uint8Array
  }): Promise<{ installed: boolean; storageUploadId?: string }> {
    return db.transaction(async (tx) => {
      const [row] = await tx.select().from(inlineUploads)
        .where(eq(inlineUploads.id, input.uploadDbId)).for("update").limit(1)
      if (!row) return { installed: false }
      const ownsStatus = input.lockToken
        ? (row.status === "uploading" || row.status === "processing") &&
          row.lockToken && sameBytes(row.lockToken, input.lockToken)
        : row.status === "uploading"
      if (!ownsStatus) return { installed: false }
      if (row.storageUploadId !== input.expectedStorageUploadId) {
        return { installed: false, storageUploadId: row.storageUploadId ?? undefined }
      }
      await tx.delete(inlineUploadStorageParts)
        .where(eq(inlineUploadStorageParts.uploadDbId, row.id))
      await tx.update(inlineUploads).set({ storageUploadId: input.storageUploadId })
        .where(eq(inlineUploads.id, row.id))
      return { installed: true, storageUploadId: input.storageUploadId }
    })
  }

  async resetStorageSession(input: {
    uploadDbId: number
    storageUploadId: string
    lockToken: Uint8Array
  }): Promise<boolean> {
    return db.transaction(async (tx) => {
      const [row] = await tx.select().from(inlineUploads).where(and(
        eq(inlineUploads.id, input.uploadDbId),
        eq(inlineUploads.status, "processing"),
        eq(inlineUploads.lockToken, Buffer.from(input.lockToken)),
      )).for("update").limit(1)
      if (!row || row.storageUploadId !== input.storageUploadId) return false
      await tx.delete(inlineUploadStorageParts)
        .where(eq(inlineUploadStorageParts.uploadDbId, row.id))
      await tx.update(inlineUploads).set({ storageUploadId: null })
        .where(eq(inlineUploads.id, row.id))
      return true
    })
  }

  async recordStoragePart(input: {
    uploadDbId: number
    storageUploadId: string
    partNumber: number
    storedByteCount: number
    storedSha256: Uint8Array
    etag: string
    lockToken?: Uint8Array
  }): Promise<"recorded" | "already-present" | "stale"> {
    return db.transaction(async (tx) => {
      const [row] = await tx.select({
        status: inlineUploads.status,
        storageUploadId: inlineUploads.storageUploadId,
        lockToken: inlineUploads.lockToken,
      }).from(inlineUploads).where(eq(inlineUploads.id, input.uploadDbId))
        .for("update").limit(1)
      if (!row || row.storageUploadId !== input.storageUploadId) return "stale"
      const ownsStatus = input.lockToken
        ? (row.status === "uploading" || row.status === "processing") &&
          row.lockToken && sameBytes(row.lockToken, input.lockToken)
        : row.status === "uploading"
      if (!ownsStatus) return "stale"
      const [inserted] = await tx.insert(inlineUploadStorageParts).values({
        uploadDbId: input.uploadDbId,
        storageUploadId: input.storageUploadId,
        partNumber: input.partNumber,
        storedByteCount: input.storedByteCount,
        storedSha256: Buffer.from(input.storedSha256),
        etag: input.etag,
      }).onConflictDoNothing({
        target: [inlineUploadStorageParts.uploadDbId, inlineUploadStorageParts.partNumber],
      }).returning({ partNumber: inlineUploadStorageParts.partNumber })
      if (inserted) return "recorded"
      const existing = (await tx.select().from(inlineUploadStorageParts).where(and(
        eq(inlineUploadStorageParts.uploadDbId, input.uploadDbId),
        eq(inlineUploadStorageParts.partNumber, input.partNumber),
      )).limit(1))[0]
      if (existing?.storageUploadId === input.storageUploadId &&
          existing.storedByteCount === input.storedByteCount &&
          sameBytes(existing.storedSha256, input.storedSha256) &&
          existing.etag === input.etag) return "already-present"
      throw new InlineUploadStorageConflictError()
    })
  }

  async scheduleProcessingRetry(input: {
    uploadDbId: number
    lockToken: Uint8Array
    retryDelayMs: number
  }): Promise<boolean> {
    const rows = await db.update(inlineUploads).set({
      attempts: sql`${inlineUploads.attempts} + 1`,
      retryAt: sql<Date>`CURRENT_TIMESTAMP + (${input.retryDelayMs} * interval '1 millisecond')`,
      lockToken: null,
      lockedAt: null,
    }).where(and(
      eq(inlineUploads.id, input.uploadDbId),
      eq(inlineUploads.status, "processing"),
      eq(inlineUploads.lockToken, Buffer.from(input.lockToken)),
    )).returning({ id: inlineUploads.id })
    return rows.length === 1
  }

  async releaseProcessingClaim(input: { uploadDbId: number; lockToken: Uint8Array }): Promise<boolean> {
    const rows = await db.update(inlineUploads).set({
      // NULL is the canonical "ready now" value. Using CURRENT_TIMESTAMP here
      // can retain sub-millisecond precision that the JS claim clock cannot
      // represent, briefly making an intentionally released row unclaimable.
      retryAt: null,
      lockToken: null,
      lockedAt: null,
    }).where(and(
      eq(inlineUploads.id, input.uploadDbId),
      inArray(inlineUploads.status, ["uploading", "processing"]),
      eq(inlineUploads.lockToken, Buffer.from(input.lockToken)),
    )).returning({ id: inlineUploads.id })
    return rows.length === 1
  }

  async publishComplete(input: {
    uploadDbId: number
    lockToken: Uint8Array
    publication: InlineUploadPublication
  }): Promise<{ fileUniqueId: string; mediaId: number } | undefined> {
    return db.transaction(async (tx) => {
      const [upload] = await tx.select().from(inlineUploads).where(and(
        eq(inlineUploads.id, input.uploadDbId),
        eq(inlineUploads.status, "processing"),
        eq(inlineUploads.lockToken, Buffer.from(input.lockToken)),
      )).for("update").limit(1)
      if (!upload) return undefined

      const publication = input.publication
      if (upload.kind !== publication.media.kind ||
          upload.kind !== publication.file.record.fileType ||
          upload.resultFileUniqueId !== publication.file.record.fileUniqueId ||
          publication.file.path !== inlineUploadPublicationPath(publication.file.record.fileUniqueId) ||
          upload.userId !== publication.file.record.userId ||
          publication.file.record.fileSize !== Number(upload.byteCount)) {
        throw new InlineUploadPublicationConflictError()
      }

      const [insertedFile] = await tx.insert(files)
        .values(publication.file.record)
        .onConflictDoNothing({ target: files.fileUniqueId })
        .returning()
      const file = insertedFile ?? (await tx.select().from(files)
        .where(eq(files.fileUniqueId, publication.file.record.fileUniqueId))
        .for("update")
        .limit(1))[0]
      if (!file) throw new InlineUploadPublicationConflictError()
      assertPublicationFileMatches(file, publication.file)

      let mediaId: number
      switch (publication.media.kind) {
        case "photo": {
          const sizeRows = await tx.select().from(photoSizes)
            .where(and(eq(photoSizes.fileId, file.id), eq(photoSizes.size, "f")))
            .limit(2)
          const existingSize = sizeRows[0]
          if (sizeRows.length > 1) throw new InlineUploadPublicationConflictError()
          if (existingSize) {
            if (existingSize.photoId === null) throw new InlineUploadPublicationConflictError()
            const [photo] = await tx.select().from(photos)
              .where(eq(photos.id, existingSize.photoId))
              .limit(1)
            if (!photo || photo.format !== publication.media.format ||
                photo.width !== publication.media.width || photo.height !== publication.media.height) {
              throw new InlineUploadPublicationConflictError()
            }
            mediaId = photo.id
          } else {
            const [photo] = await tx.insert(photos).values({
              format: publication.media.format,
              width: publication.media.width,
              height: publication.media.height,
              stripped: publication.media.stripped,
              strippedIv: publication.media.strippedIv,
              strippedTag: publication.media.strippedTag,
              date: new Date(),
            }).returning()
            if (!photo) throw new InlineUploadPublicationConflictError()
            await tx.insert(photoSizes).values({
              fileId: file.id,
              photoId: photo.id,
              size: "f",
              width: publication.media.width,
              height: publication.media.height,
            })
            mediaId = photo.id
          }
          break
        }
        case "video": {
          const existing = await tx.select().from(videos)
            .where(eq(videos.fileId, file.id))
            .limit(2)
          if (existing.length > 1) throw new InlineUploadPublicationConflictError()
          const video = existing[0] ?? (await tx.insert(videos).values({
            fileId: file.id,
            width: publication.media.width,
            height: publication.media.height,
            duration: publication.media.duration,
            photoId: publication.media.photoId,
            isAnimated: publication.media.isAnimated,
            hasAudio: publication.media.hasAudio,
            date: new Date(),
          }).returning())[0]
          if (!video || video.width !== publication.media.width ||
              video.height !== publication.media.height ||
              video.duration !== publication.media.duration ||
              video.photoId !== (publication.media.photoId ?? null) ||
              video.isAnimated !== publication.media.isAnimated ||
              video.hasAudio !== (publication.media.hasAudio ?? null)) {
            throw new InlineUploadPublicationConflictError()
          }
          mediaId = video.id
          break
        }
        case "document": {
          const existing = await tx.select().from(documents)
            .where(eq(documents.fileId, file.id))
            .limit(2)
          if (existing.length > 1) throw new InlineUploadPublicationConflictError()
          const document = existing[0] ?? (await tx.insert(documents).values({
            fileId: file.id,
            fileName: publication.media.fileName,
            fileNameIv: publication.media.fileNameIv,
            fileNameTag: publication.media.fileNameTag,
            photoId: publication.media.photoId,
            date: new Date(),
          }).returning())[0]
          if (!document || document.photoId !== (publication.media.photoId ?? null) ||
              decryptRequiredText({
                encrypted: document.fileName,
                iv: document.fileNameIv,
                authTag: document.fileNameTag,
              }) !== publication.file.fileName) {
            throw new InlineUploadPublicationConflictError()
          }
          mediaId = document.id
          break
        }
        case "voice": {
          const existing = await tx.select().from(voices)
            .where(eq(voices.fileId, file.id))
            .limit(2)
          if (existing.length > 1) throw new InlineUploadPublicationConflictError()
          const voice = existing[0] ?? (await tx.insert(voices).values({
            fileId: file.id,
            duration: publication.media.duration,
            waveform: publication.media.waveform,
            date: new Date(),
          }).returning())[0]
          if (!voice || voice.duration !== publication.media.duration ||
              !voice.waveform || !sameBytes(voice.waveform, publication.media.waveform)) {
            throw new InlineUploadPublicationConflictError()
          }
          mediaId = voice.id
          break
        }
      }

      const [completed] = await tx.update(inlineUploads).set({
        status: "complete",
        resultMediaId: mediaId,
        completedAt: new Date(),
        retryAt: null,
        lockToken: null,
        lockedAt: null,
      }).where(and(
        eq(inlineUploads.id, upload.id),
        eq(inlineUploads.status, "processing"),
        eq(inlineUploads.lockToken, Buffer.from(input.lockToken)),
      )).returning({ id: inlineUploads.id })
      if (!completed) throw new InlineUploadPublicationConflictError()
      return { fileUniqueId: publication.file.record.fileUniqueId, mediaId }
    })
  }

  async renew(
    input: { uploadDbId: number; lockToken: Uint8Array },
    signal?: AbortSignal,
  ): Promise<boolean> {
    signal?.throwIfAborted()
    const query = db.$client<{ id: number }[]>`
      update inline_uploads
      set locked_at = CURRENT_TIMESTAMP
      where id = ${input.uploadDbId}
        and status in ('uploading', 'processing')
        and lock_token = ${Buffer.from(input.lockToken)}
      returning id
    `
    const cancel = () => query.cancel()
    signal?.addEventListener("abort", cancel, { once: true })
    try {
      const rows = await query.execute()
      signal?.throwIfAborted()
      return rows.length === 1
    } catch (cause) {
      if (signal?.aborted) throw signal.reason
      throw cause
    } finally {
      signal?.removeEventListener("abort", cancel)
    }
  }

  async fail(input: {
    uploadDbId: number
    lockToken: Uint8Array
    code: string
    retryable: boolean
  }): Promise<boolean> {
    const rows = await db.update(inlineUploads).set({
      status: "failed",
      failureCode: input.code,
      failureRetryable: input.retryable,
      retryAt: null,
      lockToken: null,
      lockedAt: null,
    }).where(and(
      eq(inlineUploads.id, input.uploadDbId),
      eq(inlineUploads.status, "processing"),
      eq(inlineUploads.lockToken, Buffer.from(input.lockToken)),
    )).returning({ id: inlineUploads.id })
    return rows.length === 1
  }

  async cancel(uploadId: Uint8Array, owner: InlineUploadOwner): Promise<{
    result: { canceled: boolean; alreadyTerminal: boolean }
    upload: InlineUploadRecord
  } | undefined> {
    if (uploadId.length !== 16) return undefined
    return db.transaction(async (tx) => {
      const [row] = await tx.select().from(inlineUploads).where(and(
        eq(inlineUploads.uploadId, Buffer.from(uploadId)),
        eq(inlineUploads.userId, owner.userId),
        eq(inlineUploads.accountSessionId, owner.accountSessionId),
        ownerKeyMatches(owner),
      )).for("update").limit(1)
      if (!row) return undefined
      const upload = (status: InlineUploadRecord["status"] = row.status): InlineUploadRecord => ({
        ...row,
        status,
        acceptedParts: [],
      })
      if (row.status === "complete" || row.status === "failed" || row.status === "canceled") {
        return {
          result: { canceled: row.status === "canceled", alreadyTerminal: true },
          upload: upload(),
        }
      }
      // Finalization owns the terminal transition once it has claimed the row.
      // Canceling here would revoke its fence and delete staging bytes while the
      // finalizer may already be assembling or publishing permanent media.
      if (row.status === "processing") {
        return {
          result: { canceled: false, alreadyTerminal: false },
          upload: upload(),
        }
      }
      await tx.update(inlineUploads).set({
        status: "canceled",
        canceledAt: new Date(),
        lockToken: null,
        lockedAt: null,
      }).where(eq(inlineUploads.id, row.id))
      return {
        result: { canceled: true, alreadyTerminal: false },
        upload: upload("canceled"),
      }
    })
  }

  async listExpired(limit = 100): Promise<Array<{ id: number }>> {
    return db.select({ id: inlineUploads.id }).from(inlineUploads)
      .where(and(
        inArray(inlineUploads.status, ["uploading", "complete", "failed", "canceled"]),
        or(
          lt(inlineUploads.expiresAt, sql<Date>`CURRENT_TIMESTAMP`),
          lt(inlineUploads.hardExpiresAt, sql<Date>`CURRENT_TIMESTAMP`),
        ),
        or(isNull(inlineUploads.lockToken),
          lt(
            inlineUploads.lockedAt,
            sql<Date>`CURRENT_TIMESTAMP - (${INLINE_UPLOAD_PROCESSING_LEASE_MS} * interval '1 millisecond')`,
          )),
      ))
      .orderBy(asc(inlineUploads.expiresAt))
      .limit(limit)
  }

  async parts(uploadDbId: number): Promise<InlineUploadPartRecord[]> {
    return (await db.select().from(inlineUploadParts)
      .where(eq(inlineUploadParts.uploadDbId, uploadDbId))
      .orderBy(asc(inlineUploadParts.partIndex)))
      .map(uploadPartRecord)
  }

  async claimExpiredCleanup(uploadDbId: number): Promise<{
    cleanupToken: Uint8Array
    upload: InlineUploadRecord
  } | undefined> {
    return db.transaction(async (tx) => {
      const [clock] = await tx.execute<{ now: string | Date }>(sql`
        select CURRENT_TIMESTAMP as now
      `)
      const now = databaseTimestamp(clock?.now)
      const [row] = await tx.select().from(inlineUploads)
        .where(eq(inlineUploads.id, uploadDbId)).for("update").limit(1)
      if (!row || (row.expiresAt > now && row.hardExpiresAt > now)) return undefined
      if (row.status === "processing") return undefined
      // Processing and cleanup use the same lease fields. A fresh cleanup
      // owner must not be stolen by another process while it deletes parts.
      if (row.lockToken && (!row.lockedAt ||
          row.lockedAt > new Date(now.getTime() - INLINE_UPLOAD_PROCESSING_LEASE_MS))) {
        return undefined
      }
      // Completion is durable even if cleanup only partly succeeds. Older
      // cleanup attempts may have changed status but retained resultMediaId.
      const completed = row.status === "complete" || row.resultMediaId !== null
      const cleanupToken = randomBytes(32)
      const [claimed] = await tx.update(inlineUploads).set({
        status: completed ? "complete" : "canceled",
        canceledAt: completed ? row.canceledAt : row.canceledAt ?? now,
        lockToken: cleanupToken,
        lockedAt: now,
      }).where(eq(inlineUploads.id, uploadDbId)).returning({ id: inlineUploads.id })
      return claimed
        ? {
          cleanupToken: Uint8Array.from(cleanupToken),
          upload: { ...row, status: completed ? "complete" : "canceled", acceptedParts: [] },
        }
        : undefined
    })
  }

  async removeCleanupClaim(uploadDbId: number, cleanupToken: Uint8Array): Promise<boolean> {
    const rows = await db.delete(inlineUploads).where(and(
      eq(inlineUploads.id, uploadDbId),
      inArray(inlineUploads.status, ["canceled", "complete"]),
      eq(inlineUploads.lockToken, Buffer.from(cleanupToken)),
    )).returning({ id: inlineUploads.id })
    return rows.length === 1
  }

  async releaseCleanupClaim(uploadDbId: number, cleanupToken: Uint8Array): Promise<boolean> {
    const rows = await db.update(inlineUploads).set({
      lockToken: null,
      lockedAt: null,
    }).where(and(
      eq(inlineUploads.id, uploadDbId),
      inArray(inlineUploads.status, ["canceled", "complete"]),
      eq(inlineUploads.lockToken, Buffer.from(cleanupToken)),
    )).returning({ id: inlineUploads.id })
    return rows.length === 1
  }
}

export class InlineUploadMetadataConflictError extends Error {
  constructor() {
    super("The client upload identifier is already bound to different metadata")
    this.name = "InlineUploadMetadataConflictError"
  }
}

export class InlineUploadPublicationConflictError extends Error {
  constructor() {
    super("The upload publication identity conflicts with existing permanent media")
    this.name = "InlineUploadPublicationConflictError"
  }
}
