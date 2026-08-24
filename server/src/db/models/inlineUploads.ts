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
import { createHash, randomBytes } from "node:crypto"
import { db } from "@in/server/db"
import {
  documents,
  files,
  inlineProtocolAuthKeys,
  inlineUploadParts,
  inlineUploads,
  photos,
  photoSizes,
  sessions,
  videos,
  voices,
  type DbInlineUpload,
} from "@in/server/db/schema"
import { decrypt } from "@in/server/modules/encryption/encryption"

export const INLINE_UPLOAD_PART_SIZE = 512 * 1_024
export const INLINE_UPLOAD_MAX_PARTS = 1_000
export const INLINE_UPLOAD_IDLE_TTL_MS = 24 * 60 * 60 * 1_000
export const INLINE_UPLOAD_HARD_TTL_MS = 7 * 24 * 60 * 60 * 1_000
const INLINE_UPLOAD_PROCESSING_LEASE_MS = 5 * 60 * 1_000
const INLINE_UPLOAD_PUBLICATION_PREFIX = "native-uploads/v1"

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

export type InlineUploadPartTarget = Pick<
  DbInlineUpload,
  "id" | "byteCount" | "partSize" | "partCount" | "status" | "expiresAt" | "hardExpiresAt"
>

export type InlineUploadPartAcceptance = {
  kind: "accepted" | "already-present" | "conflict" | "terminal"
  /** Object key already owned by the durable manifest, if one exists. */
  durableObjectKey?: string
}

export class InlineUploadAdmissionCapacityError extends Error {}
export class InlineUploadAdmissionOwnerInvalidError extends Error {}

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
            !sameBytes(existing.permanentAuthKeyId, owner.permanentAuthKeyId) ||
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
      const [inserted] = await tx.insert(inlineUploads).values({
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

      const row = inserted ?? (await tx.select().from(inlineUploads).where(and(
        eq(inlineUploads.accountSessionId, owner.accountSessionId),
        eq(inlineUploads.clientUploadId, Buffer.from(metadata.clientUploadId)),
      )).limit(1))[0]
      if (!row || row.userId !== owner.userId ||
          !sameBytes(row.permanentAuthKeyId, owner.permanentAuthKeyId) ||
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

  async getPartTarget(
    uploadId: Uint8Array,
    owner: InlineUploadOwner,
  ): Promise<InlineUploadPartTarget | undefined> {
    if (uploadId.length !== 16) return undefined
    return (await db.select({
      id: inlineUploads.id,
      byteCount: inlineUploads.byteCount,
      partSize: inlineUploads.partSize,
      partCount: inlineUploads.partCount,
      status: inlineUploads.status,
      expiresAt: inlineUploads.expiresAt,
      hardExpiresAt: inlineUploads.hardExpiresAt,
    }).from(inlineUploads).where(and(
      eq(inlineUploads.uploadId, Buffer.from(uploadId)),
      eq(inlineUploads.userId, owner.userId),
      eq(inlineUploads.accountSessionId, owner.accountSessionId),
      eq(inlineUploads.permanentAuthKeyId, Buffer.from(owner.permanentAuthKeyId)),
    )).limit(1))[0]
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
    upload: Pick<InlineUploadRecord, "id">
    partIndex: number
    byteCount: number
    sha256: Uint8Array
    objectKey: string
  }): Promise<InlineUploadPartAcceptance> {
    return db.transaction(async (tx) => {
      const now = new Date()
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
        objectKey: input.objectKey,
      }).onConflictDoNothing({
        target: [inlineUploadParts.uploadDbId, inlineUploadParts.partIndex],
      }).returning({ partIndex: inlineUploadParts.partIndex })
      if (!inserted) {
        if (!existing || existing.byteCount !== input.byteCount ||
            !sameBytes(existing.sha256, input.sha256)) {
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
      const resultFileUniqueId = row.resultFileUniqueId ?? inlineUploadFileUniqueId(row)
      await tx.update(inlineUploads).set({
        status: "processing",
        resultFileUniqueId,
        lockToken,
        lockedAt: now,
      }).where(eq(inlineUploads.id, row.id))
      return {
        kind: "claimed",
        upload: {
          ...upload,
          status: "processing",
          resultFileUniqueId,
          lockToken,
          lockedAt: now,
        },
        lockToken: Uint8Array.from(lockToken),
        parts: parts.map((part) => ({ ...part, sha256: Uint8Array.from(part.sha256) })),
      } as const
    })
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
          upload.userId !== publication.file.record.userId) {
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

  async renew(input: { uploadDbId: number; lockToken: Uint8Array }): Promise<boolean> {
    const rows = await db.update(inlineUploads).set({
      lockedAt: new Date(),
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
      // Finalization owns the terminal transition once it has claimed the row.
      // Canceling here would revoke its fence and delete staging bytes while the
      // finalizer may already be assembling or publishing permanent media.
      if (row.status === "processing") {
        return { canceled: false, alreadyTerminal: false }
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

  async listExpired(limit = 100): Promise<Array<{ id: number }>> {
    const now = new Date()
    return db.select({ id: inlineUploads.id }).from(inlineUploads)
      .where(or(lt(inlineUploads.expiresAt, now), lt(inlineUploads.hardExpiresAt, now)))
      .orderBy(asc(inlineUploads.expiresAt))
      .limit(limit)
  }

  async parts(uploadDbId: number): Promise<InlineUploadPartRecord[]> {
    return (await db.select().from(inlineUploadParts)
      .where(eq(inlineUploadParts.uploadDbId, uploadDbId))
      .orderBy(asc(inlineUploadParts.partIndex)))
      .map((part) => ({ ...part, sha256: Uint8Array.from(part.sha256) }))
  }

  async claimExpiredCleanup(uploadDbId: number): Promise<{
    cleanupToken: Uint8Array
    upload: InlineUploadRecord
  } | undefined> {
    return db.transaction(async (tx) => {
      const now = new Date()
      const [row] = await tx.select().from(inlineUploads)
        .where(eq(inlineUploads.id, uploadDbId)).for("update").limit(1)
      if (!row || (row.expiresAt > now && row.hardExpiresAt > now)) return undefined
      if (row.status === "processing" && row.lockedAt &&
          row.lockedAt > new Date(now.getTime() - INLINE_UPLOAD_PROCESSING_LEASE_MS)) {
        return undefined
      }
      const cleanupToken = randomBytes(32)
      const [claimed] = await tx.update(inlineUploads).set({
        status: "canceled",
        canceledAt: row.canceledAt ?? now,
        lockToken: cleanupToken,
        lockedAt: now,
      }).where(eq(inlineUploads.id, uploadDbId)).returning({ id: inlineUploads.id })
      return claimed
        ? {
          cleanupToken: Uint8Array.from(cleanupToken),
          upload: { ...row, acceptedParts: [] },
        }
        : undefined
    })
  }

  async removeCleanupClaim(uploadDbId: number, cleanupToken: Uint8Array): Promise<boolean> {
    const rows = await db.delete(inlineUploads).where(and(
      eq(inlineUploads.id, uploadDbId),
      eq(inlineUploads.status, "canceled"),
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
