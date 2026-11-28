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
  filePartHashes,
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
import { isValidPartHashes, partHashesFromManifest } from "@in/server/modules/files/partHashes"
import { MAX_FILE_SIZE } from "@in/server/config"
import { MEDIA_UPLOAD_MAX_BYTES } from "@in/server/modules/files/limits"
import { INLINE_TRANSFER_PART_SIZE, INLINE_UPLOAD_MAX_PARTS } from "@inline-chat/protocol/transfers"

export const INLINE_UPLOAD_PART_SIZE = INLINE_TRANSFER_PART_SIZE
export { INLINE_UPLOAD_MAX_PARTS }
export const INLINE_UPLOAD_IDLE_TTL_MS = 24 * 60 * 60 * 1_000
export const INLINE_UPLOAD_HARD_TTL_MS = 7 * 24 * 60 * 60 * 1_000
/**
 * Idle lifetime of an upload whose size is not known yet (a video streaming while it encodes). It
 * reserves its kind's maximum against the session, and a client that dies mid-encode never
 * cancels it; each stored block, and naming the size, extend it.
 */
export const INLINE_UPLOAD_UNSIZED_IDLE_TTL_MS = 60 * 60 * 1_000
// Provider operations are independently deadline-bounded and the lock token
// fences every durable transition. A short renewable lease keeps crash
// recovery prompt without allowing a stale worker to publish.
export const INLINE_UPLOAD_PROCESSING_LEASE_MS = 30_000
const INLINE_UPLOAD_PUBLICATION_PREFIX = "native-uploads/v1"

/**
 * Uploads whose parts this server holds in memory and writes to storage once, ten parts (5 MiB)
 * at a time, straight into the final object: no staging objects and no per-part rows. A process
 * that dies loses only the blocks it had not written yet, and the client resends those parts.
 */
export const BLOCKS_STORAGE_FORMAT = "blocks_v1"
export type InlineUploadStorageFormat = "identity_v1" | typeof BLOCKS_STORAGE_FORMAT
/** Parts per block; one block is one part of the final object's multipart session. */
export const INLINE_UPLOAD_PARTS_PER_BLOCK = 10
/**
 * The storage row of a `blocks_v1` upload of one block, written with a single PutObject at its
 * final key instead of a multipart session.
 */
export const WHOLE_OBJECT_STORAGE_UPLOAD_ID = "object"

/** The largest size an upload of this kind may reach; reserved while its size is unknown. */
export const inlineUploadMaximumByteCount = (kind: InlineUploadKind): bigint =>
  BigInt(Math.min(MAX_FILE_SIZE, MEDIA_UPLOAD_MAX_BYTES[kind]))

/** Parts an upload of this kind may have; the bound while its size is unknown. */
export const inlineUploadMaximumPartCount = (kind: InlineUploadKind): number => Math.min(
  INLINE_UPLOAD_MAX_PARTS,
  Number((inlineUploadMaximumByteCount(kind) + BigInt(INLINE_TRANSFER_PART_SIZE - 1)) /
    BigInt(INLINE_TRANSFER_PART_SIZE)),
)

const PART_HASH_BYTES = 32

/**
 * Parts a `blocks_v1` upload holds in storage. A block row lists a hash per part it holds, so it
 * covers that many parts from its first; a whole-object row covers the file from part 0. Rows of
 * another (abandoned) multipart session cover nothing.
 */
/** `files.part_hashes` from a `blocks_v1` upload's block rows, in order; undefined if any is absent. */
const blockPartHashes = (
  storageParts: readonly InlineUploadStoragePartRecord[],
  fileSize: number,
): Buffer | undefined => {
  const hashes = Buffer.concat(storageParts.map((part) => Buffer.from(part.partHashes ?? new Uint8Array())))
  return isValidPartHashes(hashes, fileSize) ? hashes : undefined
}

export const storedBlockParts = (
  upload: { storageUploadId: string | null },
  storageParts: readonly { storageUploadId: string; partNumber: number; partHashes: Uint8Array | null }[],
): number[] => {
  const parts: number[] = []
  for (const block of storageParts) {
    if (block.storageUploadId !== WHOLE_OBJECT_STORAGE_UPLOAD_ID &&
        block.storageUploadId !== upload.storageUploadId) continue
    const count = Math.floor((block.partHashes?.byteLength ?? 0) / PART_HASH_BYTES)
    const first = block.storageUploadId === WHOLE_OBJECT_STORAGE_UPLOAD_ID
      ? 0
      : (block.partNumber - 1) * INLINE_UPLOAD_PARTS_PER_BLOCK
    for (let index = first; index < first + count; index++) parts.push(index)
  }
  return [...new Set(parts)].sort((left, right) => left - right)
}

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
  /** Null while the client streams a file of unknown size; the finish names it. */
  byteCount: bigint | null
  /** Optional on `blocks_v1`: the transport already checks every message. */
  sha256: Uint8Array | null
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
  /** `blocks_v1`: the SHA-256 of each part in the block, concatenated. */
  partHashes: Uint8Array | null
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
  | "storageUploadId"
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
  // A size named at finish was unknown at create; the create's replay still matches.
  (row.byteCount === metadata.byteCount ||
    (metadata.byteCount === null && row.storageFormat === BLOCKS_STORAGE_FORMAT)) &&
  sameOptionalBytes(row.sha256, metadata.sha256 ?? undefined) &&
  row.kind === metadata.kind &&
  // A create may leave the thumbnail to finish; its replay then matches the finished row too.
  (row.thumbnailFileUniqueId === (metadata.thumbnailFileUniqueId ?? null) ||
    (metadata.thumbnailFileUniqueId === undefined && row.status !== "uploading")) &&
  row.videoWidth === (metadata.videoWidth ?? null) &&
  row.videoHeight === (metadata.videoHeight ?? null) &&
  row.duration === (metadata.duration ?? null) &&
  row.isAnimated === (metadata.isAnimated ?? null) &&
  row.hasAudio === (metadata.hasAudio ?? null) &&
  sameOptionalBytes(row.waveform, metadata.waveform)

const isUniqueViolation = (error: unknown): boolean => {
  for (let cause: unknown = error, depth = 0; cause && depth < 4; depth++) {
    if (typeof cause === "object" && (cause as { code?: unknown }).code === "23505") return true
    cause = typeof cause === "object" ? (cause as { cause?: unknown }).cause : undefined
  }
  return false
}

/** A lease older than this, measured on the database clock, may be taken over. */
const staleLeaseCutoff = sql<Date>`CURRENT_TIMESTAMP - (${INLINE_UPLOAD_PROCESSING_LEASE_MS} * interval '1 millisecond')`

type Queryable = Pick<typeof db, "select">

/** Storage rows of the upload's current session, plus a whole-object row. */
const storagePartsFor = async (
  client: Queryable,
  row: { id: number; storageUploadId: string | null },
): Promise<InlineUploadStoragePartRecord[]> => {
  const sessions = [WHOLE_OBJECT_STORAGE_UPLOAD_ID, ...(row.storageUploadId ? [row.storageUploadId] : [])]
  return (await client.select().from(inlineUploadStorageParts).where(and(
    eq(inlineUploadStorageParts.uploadDbId, row.id),
    inArray(inlineUploadStorageParts.storageUploadId, sessions),
  )).orderBy(asc(inlineUploadStorageParts.partNumber))).map(storagePartRecord)
}

/** Parts in storage: `blocks_v1` from its block rows, older formats from their part manifest. */
const acceptedPartsFor = async (
  row: { id: number; storageFormat: string | null; storageUploadId: string | null },
  client: Queryable = db,
): Promise<number[]> => {
  if (row.storageFormat === BLOCKS_STORAGE_FORMAT) return storedBlockParts(row, await storagePartsFor(client, row))
  return (await client.select({ partIndex: inlineUploadParts.partIndex })
    .from(inlineUploadParts)
    .where(eq(inlineUploadParts.uploadDbId, row.id))
    .orderBy(asc(inlineUploadParts.partIndex)))
    .map(({ partIndex }) => partIndex)
}

const uploadPartRecord = (part: typeof inlineUploadParts.$inferSelect): InlineUploadPartRecord => ({
  ...part,
  sha256: Uint8Array.from(part.sha256),
  // Old servers intentionally leave stored integrity null during the rolling
  // compatibility window. Such rows are legacy identity frames.
  storedByteCount: part.storedByteCount ?? part.byteCount,
  storedSha256: Uint8Array.from(part.storedSha256 ?? part.sha256),
})

function storagePartRecord(
  part: typeof inlineUploadStorageParts.$inferSelect,
): InlineUploadStoragePartRecord {
  return {
    ...part,
    storedSha256: Uint8Array.from(part.storedSha256),
    partHashes: part.partHashes ? Uint8Array.from(part.partHashes) : null,
  }
}

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
    return rows.reduce((total, row) => total + (row.byteCount ?? 0n), 0n)
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
    /** The client's proposed upload ID (CreateUploadInput.upload_id); random when absent. */
    proposedUploadId?: Uint8Array,
    storageFormat: InlineUploadStorageFormat = "identity_v1",
  ): Promise<{
    upload: InlineUploadRecord
    created: boolean
  }> {
    // Only `blocks_v1` stores without a size or digest.
    if (storageFormat !== BLOCKS_STORAGE_FORMAT && (metadata.byteCount === null || metadata.sha256 === null)) {
      throw new InlineUploadMetadataConflictError()
    }
    try {
      return await this.#create(owner, metadata, admission, proposedUploadId, storageFormat)
    } catch (error) {
      // Two creates proposing one ID at once: the second falls back to a server-picked ID.
      if (proposedUploadId === undefined || !isUniqueViolation(error)) throw error
      return await this.#create(owner, metadata, admission, undefined, storageFormat)
    }
  }

  async #create(
    owner: InlineUploadOwner,
    metadata: InlineUploadMetadata,
    admission: { maxActiveCount: number; maxReservedBytes: bigint } | undefined,
    proposedUploadId: Uint8Array | undefined,
    storageFormat: InlineUploadStorageFormat,
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
        const acceptedParts = await acceptedPartsFor(existing, tx)
        return { upload: { ...existing, acceptedParts }, created: false }
      }

      if (admission) {
        const active = await tx.select({ byteCount: inlineUploads.byteCount, kind: inlineUploads.kind })
          .from(inlineUploads)
          .where(and(
            eq(inlineUploads.userId, owner.userId),
            eq(inlineUploads.accountSessionId, owner.accountSessionId),
            inArray(inlineUploads.status, ["uploading", "processing"]),
            gt(inlineUploads.expiresAt, now),
            gt(inlineUploads.hardExpiresAt, now),
          ))
        // An upload whose size is unknown reserves the most its kind may reach.
        const reservedBytes = active.reduce((total, row) =>
          total + (row.byteCount ?? inlineUploadMaximumByteCount(row.kind as InlineUploadKind)), 0n)
        const requestedBytes = metadata.byteCount ?? inlineUploadMaximumByteCount(metadata.kind)
        if (active.length >= admission.maxActiveCount ||
            reservedBytes + requestedBytes > admission.maxReservedBytes) {
          throw new InlineUploadAdmissionCapacityError()
        }
      }

      // A proposed ID another upload already holds falls back to a random one; the client sees a
      // different ID in the result and waits for create replies from then on.
      const proposedTaken = proposedUploadId !== undefined && (await tx.select({ id: inlineUploads.id })
        .from(inlineUploads)
        .where(eq(inlineUploads.uploadId, Buffer.from(proposedUploadId)))
        .limit(1)).length > 0
      const uploadId = proposedUploadId && !proposedTaken ? Buffer.from(proposedUploadId) : randomBytes(16)
      const partCount = metadata.byteCount === null ? null : Number((metadata.byteCount +
        BigInt(INLINE_UPLOAD_PART_SIZE - 1)) / BigInt(INLINE_UPLOAD_PART_SIZE))
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
        sha256: metadata.sha256 ? Buffer.from(metadata.sha256) : null,
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
        storageFormat,
        resultFileUniqueId,
        expiresAt: new Date(now.getTime() +
          (metadata.byteCount === null ? INLINE_UPLOAD_UNSIZED_IDLE_TTL_MS : INLINE_UPLOAD_IDLE_TTL_MS)),
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
      const acceptedParts = inserted ? [] : await acceptedPartsFor(row, tx)
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
      acceptedParts: await acceptedPartsFor(row),
      expired: row.expiresAt <= now || row.hardExpiresAt <= now,
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

  /** Immutable upload geometry plus accepted part indices, in one statement. */
  async getPartGeometry(
    uploadId: Uint8Array,
    owner: InlineUploadOwner,
  ): Promise<(InlineUploadPartTarget & { acceptedParts: number[] }) | undefined> {
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
      storageUploadId: inlineUploads.storageUploadId,
      databaseNow: sql<Date>`CURRENT_TIMESTAMP`,
      acceptedParts: sql<number[]>`coalesce((
        select array_agg(p.part_index order by p.part_index)
        from inline_upload_parts p where p.upload_id = ${inlineUploads.id}
      ), '{}'::integer[])`,
    }).from(inlineUploads).where(and(
      eq(inlineUploads.uploadId, Buffer.from(uploadId)),
      eq(inlineUploads.userId, owner.userId),
      eq(inlineUploads.accountSessionId, owner.accountSessionId),
      ownerKeyMatches(owner),
    )).limit(1))[0]
    if (!result) return undefined
    const { databaseNow, acceptedParts, ...upload } = result
    const now = databaseTimestamp(databaseNow)
    return {
      ...upload,
      acceptedParts: upload.storageFormat === BLOCKS_STORAGE_FORMAT
        ? await acceptedPartsFor({ id: upload.id, storageFormat: upload.storageFormat,
          storageUploadId: upload.storageUploadId })
        : acceptedParts.map(Number),
      expired: upload.expiresAt <= now || upload.hardExpiresAt <= now,
    }
  }

  /**
   * Accepts one part in a single statement without locking the upload row. The
   * primary key `(upload_id, part_index)` arbitrates concurrent saves, and the
   * idle-expiry bump runs at most once an hour per upload to bound row churn.
   * Returns `terminal` when no live upload matches the owner, `accepted` when
   * this call inserted the part, and otherwise the existing manifest outcome.
   */
  async acceptPartFast(input: {
    uploadId: Uint8Array
    owner: InlineUploadOwner
    uploadDbId: number
    partIndex: number
    byteCount: number
    sha256: Uint8Array
    storedByteCount: number
    storedSha256: Uint8Array
    objectKey: string
  }): Promise<InlineUploadPartAcceptance> {
    const permanentAuthKeyId = input.owner.permanentAuthKeyId ? Buffer.from(input.owner.permanentAuthKeyId) : null
    const [row] = await db.execute<{ targeted: string | number; inserted: string | number }>(sql`
      with target as (
        select id from inline_uploads
        where upload_id = ${Buffer.from(input.uploadId)}
          and user_id = ${input.owner.userId}
          and account_session_id = ${input.owner.accountSessionId}
          and permanent_auth_key_id is not distinct from ${permanentAuthKeyId}::bytea
          and status = 'uploading' and expires_at > now() and hard_expires_at > now()
      ),
      inserted as (
        insert into inline_upload_parts
          (upload_id, part_index, byte_count, sha256, stored_byte_count, stored_sha256, object_key)
        select id, ${input.partIndex}, ${input.byteCount}, ${Buffer.from(input.sha256)},
          ${input.storedByteCount}, ${Buffer.from(input.storedSha256)}, ${input.objectKey}
        from target
        on conflict (upload_id, part_index) do nothing
        returning upload_id
      ),
      bumped as (
        update inline_uploads u
        set last_part_at = now(),
            expires_at = least(u.hard_expires_at, now() + interval '24 hours')
        from inserted
        where u.id = inserted.upload_id
          and (u.last_part_at is null or u.last_part_at < now() - interval '1 hour')
        returning u.id
      )
      select (select count(*) from target) as targeted, (select count(*) from inserted) as inserted
    `)
    if (Number(row?.targeted ?? 0) === 0) {
      // Staging keys are content-addressed, so a resend after finish wrote the
      // same key a durable part may own. Report that owner so it is not removed.
      const existing = await this.getPart(input.uploadDbId, input.partIndex)
      return { kind: "terminal", durableObjectKey: existing?.objectKey }
    }
    if (Number(row?.inserted ?? 0) === 1) return { kind: "accepted", durableObjectKey: input.objectKey }
    const existing = await this.getPart(input.uploadDbId, input.partIndex)
    if (!existing || existing.byteCount !== input.byteCount || !sameBytes(existing.sha256, input.sha256) ||
        existing.storedByteCount !== input.storedByteCount || !sameBytes(existing.storedSha256, input.storedSha256)) {
      return { kind: "conflict", durableObjectKey: existing?.objectKey }
    }
    return { kind: "already-present", durableObjectKey: existing.objectKey }
  }

  async requestFinish(
    uploadId: Uint8Array,
    owner: InlineUploadOwner,
    /** Names the thumbnail when the create did not (FinishUploadInput.thumbnail_file_unique_id). */
    thumbnailFileUniqueId?: string,
    /** `blocks_v1`: parts this process holds in blocks still incomplete; not reported missing. */
    heldParts: ReadonlySet<number> = new Set(),
  ): Promise<
    | { kind: "missing"; partIndices: number[] }
    | { kind: "processing" }
    | { kind: "pending" }
    | { kind: "queued"; uploadDbId: number; byteCount: bigint; partCount: number; uploadKind: InlineUploadKind }
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
      const upload = { ...row, acceptedParts: await acceptedPartsFor(row, tx) }
      if (row.status === "complete") return { kind: "complete", upload } as const
      if (row.status === "failed") return { kind: "failed", upload } as const
      if (row.status === "processing") return { kind: "processing" } as const
      if (row.expiresAt <= now || row.hardExpiresAt <= now) return { kind: "rejected" } as const
      // The size is set before finishing (setSize) when the create did not name it.
      if (row.partCount === null || row.byteCount === null) return { kind: "rejected" } as const
      // `blocks_v1` reaches processing only once every byte is in storage: a part held here in a
      // block that cannot be written yet is not missing, but it does not count as stored either.
      const accepted = new Set(upload.acceptedParts)
      const notStored = Array.from({ length: row.partCount }, (_, index) => index)
        .filter((index) => !accepted.has(index))
      const missing = notStored.filter((index) => !heldParts.has(index))
      if (missing.length > 0) return { kind: "missing", partIndices: missing } as const
      // Every part is here but a block is not stored yet: the next finish writes it.
      if (notStored.length > 0) return { kind: "pending" } as const
      if (thumbnailFileUniqueId !== undefined &&
          ((row.kind !== "video" && row.kind !== "document") ||
           (row.thumbnailFileUniqueId !== null && row.thumbnailFileUniqueId !== thumbnailFileUniqueId))) {
        return { kind: "rejected" } as const
      }
      const resultFileUniqueId = row.resultFileUniqueId ?? inlineUploadFileUniqueId(row)
      await tx.update(inlineUploads).set({
        status: "processing",
        resultFileUniqueId,
        retryAt: now,
        attempts: 0,
        ...(thumbnailFileUniqueId !== undefined ? { thumbnailFileUniqueId } : {}),
      }).where(eq(inlineUploads.id, row.id))
      return {
        kind: "queued",
        uploadDbId: row.id,
        byteCount: row.byteCount,
        partCount: row.partCount,
        uploadKind: row.kind as InlineUploadKind,
      } as const
    })
  }

  /**
   * Names the size of a `blocks_v1` upload created without one. Returns false when the upload is
   * not this owner's, not uploading, or already has a different size; a matching size is a no-op.
   */
  async setSize(uploadDbId: number, byteCount: bigint, partCount: number): Promise<boolean> {
    const rows = await db.update(inlineUploads).set({
      byteCount,
      partCount,
      expiresAt: sql<Date>`greatest(${inlineUploads.expiresAt},
        least(${inlineUploads.hardExpiresAt}, CURRENT_TIMESTAMP + interval '24 hours'))`,
    }).where(and(
      eq(inlineUploads.id, uploadDbId),
      eq(inlineUploads.status, "uploading"),
      eq(inlineUploads.storageFormat, BLOCKS_STORAGE_FORMAT),
      or(isNull(inlineUploads.byteCount), eq(inlineUploads.byteCount, byteCount)),
    )).returning({ id: inlineUploads.id })
    return rows.length === 1
  }

  async claimProcessing(uploadDbId?: number): Promise<InlineUploadProcessingClaim | undefined> {
    return db.transaction(async (tx) => {
      // CURRENT_TIMESTAMP is the transaction start inside this transaction, so
      // the filter and the lease write below share one clock without a
      // separate round trip; the worker polls this statement continuously.
      const conditions = [
        eq(inlineUploads.status, "processing"),
        or(isNull(inlineUploads.retryAt), lte(inlineUploads.retryAt, sql<Date>`CURRENT_TIMESTAMP`)),
        or(
          isNull(inlineUploads.lockToken),
          isNull(inlineUploads.lockedAt),
          lte(inlineUploads.lockedAt, staleLeaseCutoff),
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
        lockedAt: sql<Date>`CURRENT_TIMESTAMP`,
      }).where(and(
        eq(inlineUploads.id, row.id),
        eq(inlineUploads.status, "processing"),
      )).returning()
      if (!claimed) return undefined

      const parts = await tx.select().from(inlineUploadParts)
        .where(eq(inlineUploadParts.uploadDbId, row.id))
        .orderBy(asc(inlineUploadParts.partIndex))
      const storageParts = await storagePartsFor(tx, claimed)
      return {
        upload: { ...claimed, acceptedParts: claimed.storageFormat === BLOCKS_STORAGE_FORMAT
          ? storedBlockParts(claimed, storageParts)
          : parts.map(({ partIndex }) => partIndex) },
        lockToken: Uint8Array.from(lockToken),
        parts: parts.map(uploadPartRecord),
        storageParts,
      }
    })
  }

  async claimUploadingCompaction(uploadDbId: number): Promise<InlineUploadProcessingClaim | undefined> {
    return db.transaction(async (tx) => {
      const [row] = await tx.select().from(inlineUploads).where(and(
        eq(inlineUploads.id, uploadDbId),
        eq(inlineUploads.status, "uploading"),
        isNotNull(inlineUploads.storageFormat),
        or(
          isNull(inlineUploads.lockToken),
          isNull(inlineUploads.lockedAt),
          lte(inlineUploads.lockedAt, staleLeaseCutoff),
        ),
      )).for("update", { skipLocked: true }).limit(1)
      if (!row) return undefined

      const lockToken = randomBytes(32)
      const [claimed] = await tx.update(inlineUploads).set({
        lockToken,
        lockedAt: sql<Date>`CURRENT_TIMESTAMP`,
      }).where(and(
        eq(inlineUploads.id, row.id),
        eq(inlineUploads.status, "uploading"),
      )).returning()
      if (!claimed) return undefined

      const parts = await tx.select().from(inlineUploadParts)
        .where(eq(inlineUploadParts.uploadDbId, row.id))
        .orderBy(asc(inlineUploadParts.partIndex))
      const storageParts = await storagePartsFor(tx, claimed)
      return {
        upload: { ...claimed, acceptedParts: claimed.storageFormat === BLOCKS_STORAGE_FORMAT
          ? storedBlockParts(claimed, storageParts)
          : parts.map(({ partIndex }) => partIndex) },
        lockToken: Uint8Array.from(lockToken),
        parts: parts.map(uploadPartRecord),
        storageParts,
      }
    })
  }

  async getCanceledStorageWork(uploadDbId: number): Promise<InlineUploadStorageWork | undefined> {
    const [row] = await db.select().from(inlineUploads).where(and(
      eq(inlineUploads.id, uploadDbId),
      eq(inlineUploads.status, "canceled"),
      isNull(inlineUploads.resultMediaId),
    )).limit(1)
    if (!row) return undefined
    return { upload: { ...row, acceptedParts: [] }, parts: await this.parts(uploadDbId), storageParts: [] }
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
    const storageParts = await storagePartsFor(db, row)
    return {
      upload: { ...row, acceptedParts: row.storageFormat === BLOCKS_STORAGE_FORMAT
        ? storedBlockParts(row, storageParts)
        : parts.map(({ partIndex }) => partIndex) },
      parts: parts.map(uploadPartRecord),
      storageParts,
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
    /** `blocks_v1`: the block's part hashes. */
    partHashes?: Uint8Array
  }): Promise<"recorded" | "already-present" | "stale"> {
    return db.transaction(async (tx) => {
      const [row] = await tx.select({
        status: inlineUploads.status,
        storageUploadId: inlineUploads.storageUploadId,
        lockToken: inlineUploads.lockToken,
      }).from(inlineUploads).where(eq(inlineUploads.id, input.uploadDbId))
        .for("update").limit(1)
      // A whole-object write has no session; it is recorded only while none was started.
      const session = input.storageUploadId === WHOLE_OBJECT_STORAGE_UPLOAD_ID ? null : input.storageUploadId
      if (!row || row.storageUploadId !== session) return "stale"
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
        partHashes: input.partHashes ? Buffer.from(input.partHashes) : null,
        etag: input.etag,
      }).onConflictDoNothing({
        target: [inlineUploadStorageParts.uploadDbId, inlineUploadStorageParts.partNumber],
      }).returning({ partNumber: inlineUploadStorageParts.partNumber })
      if (inserted) {
        // `blocks_v1` has no part rows to keep an active upload from idling out; its blocks do.
        if (row.status === "uploading") {
          await tx.update(inlineUploads).set({
            lastPartAt: sql<Date>`CURRENT_TIMESTAMP`,
            expiresAt: sql<Date>`least(${inlineUploads.hardExpiresAt}, CURRENT_TIMESTAMP + case
              when ${inlineUploads.byteCount} is null then interval '1 hour' else interval '24 hours' end)`,
          }).where(eq(inlineUploads.id, input.uploadDbId))
        }
        return "recorded"
      }
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

      // Range hashes come from the bytes hashed at receipt, never from storage.
      const partHashes = upload.storageFormat === BLOCKS_STORAGE_FORMAT
        ? blockPartHashes(await storagePartsFor(tx, upload), Number(upload.byteCount))
        : partHashesFromManifest(await tx.select({
          partIndex: inlineUploadParts.partIndex,
          byteCount: inlineUploadParts.byteCount,
          sha256: inlineUploadParts.sha256,
        }).from(inlineUploadParts)
          .where(eq(inlineUploadParts.uploadDbId, upload.id))
          .orderBy(asc(inlineUploadParts.partIndex)), Number(upload.byteCount))
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
      if (partHashes) {
        await tx.insert(filePartHashes).values({ fileId: file.id, hashes: partHashes })
          .onConflictDoNothing({ target: filePartHashes.fileId })
      }

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
      // The row lock serializes cancel with publishComplete. If cancellation
      // wins, clear the lease fence so a late finalizer cannot publish media.
      await tx.update(inlineUploads).set({
        status: "canceled",
        canceledAt: new Date(),
        lockToken: null,
        lockedAt: null,
      }).where(eq(inlineUploads.id, row.id))
      return {
        result: { canceled: true, alreadyTerminal: false },
        upload: { ...upload("canceled"), lockToken: null, lockedAt: null },
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
