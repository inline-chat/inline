import { and, eq, exists, gt, isNull, lt, or, sql } from "drizzle-orm"
import { createHash, randomBytes, timingSafeEqual } from "node:crypto"
import { db } from "@in/server/db"
import { inlineProtocolAuthKeys, inlineProtocolUploads, sessions } from "@in/server/db/schema"

const UPLOAD_TTL_MS = 10 * 60 * 1_000
const UPLOAD_LEASE_MS = 5 * 60 * 1_000

const hashCapability = (capability: Uint8Array): Buffer =>
  createHash("sha256").update(capability).digest()

const sameBytes = (left: Uint8Array, right: Uint8Array): boolean =>
  left.length === right.length && timingSafeEqual(left, right)

export type InlineProtocolUploadIdentity = {
  userId: number
  accountSessionId: number
  permanentAuthKeyId: Uint8Array
  temporaryAuthKeyId: Uint8Array
}

export type InlineProtocolUploadOwner = Omit<InlineProtocolUploadIdentity, "temporaryAuthKeyId">

export type InlineProtocolUploadMetadata = {
  fileName: string
  mimeType: string
  byteCount: bigint
  sha256: Uint8Array
  kind: "photo" | "video" | "document" | "voice"
}

export type ClaimedInlineProtocolUpload = InlineProtocolUploadIdentity & InlineProtocolUploadMetadata & {
  uploadId: Uint8Array
  lockToken: Uint8Array
}

export type InlineProtocolUploadClaim =
  | { kind: "claimed"; upload: ClaimedInlineProtocolUpload }
  | { kind: "busy" }
  | { kind: "complete"; fileUniqueId: string }
  | { kind: "rejected" }

export class InlineProtocolUploadRepository {
  async create(identity: InlineProtocolUploadIdentity, metadata: InlineProtocolUploadMetadata): Promise<{
    uploadId: Uint8Array
    capability: Uint8Array
    expiresAt: Date
  }> {
    const uploadId = randomBytes(16)
    const capability = randomBytes(32)
    const expiresAt = new Date(Date.now() + UPLOAD_TTL_MS)
    await db.insert(inlineProtocolUploads).values({
      uploadId,
      capabilityHash: hashCapability(capability),
      permanentAuthKeyId: Buffer.from(identity.permanentAuthKeyId),
      issuingTemporaryAuthKeyId: Buffer.from(identity.temporaryAuthKeyId),
      userId: identity.userId,
      accountSessionId: identity.accountSessionId,
      fileName: metadata.fileName,
      mimeType: metadata.mimeType,
      byteCount: metadata.byteCount,
      sha256: Buffer.from(metadata.sha256),
      kind: metadata.kind,
      expiresAt,
    })
    return {
      uploadId: Uint8Array.from(uploadId),
      capability: Uint8Array.from(capability),
      expiresAt,
    }
  }

  async claim(uploadId: Uint8Array, capability: Uint8Array): Promise<InlineProtocolUploadClaim> {
    if (uploadId.length !== 16 || capability.length !== 32) return { kind: "rejected" }
    const capabilityHash = hashCapability(capability)
    const lockToken = randomBytes(32)
    const now = new Date()
    const staleBefore = new Date(now.getTime() - UPLOAD_LEASE_MS)
    const permanentAuthorizationIsActive = exists(
      db.select({ one: sql`1` }).from(inlineProtocolAuthKeys).where(and(
        eq(inlineProtocolAuthKeys.authKeyId, inlineProtocolUploads.permanentAuthKeyId),
        eq(inlineProtocolAuthKeys.userId, inlineProtocolUploads.userId),
        eq(inlineProtocolAuthKeys.accountSessionId, inlineProtocolUploads.accountSessionId),
        isNull(inlineProtocolAuthKeys.revokedAt),
      )),
    )
    const accountSessionIsActive = exists(
      db.select({ one: sql`1` }).from(sessions).where(and(
        eq(sessions.id, inlineProtocolUploads.accountSessionId),
        eq(sessions.userId, inlineProtocolUploads.userId),
        isNull(sessions.revoked),
      )),
    )
    const claimed = (await db.update(inlineProtocolUploads).set({
      status: "uploading",
      lockToken,
      lockedAt: now,
    }).where(and(
      eq(inlineProtocolUploads.uploadId, Buffer.from(uploadId)),
      eq(inlineProtocolUploads.capabilityHash, capabilityHash),
      gt(inlineProtocolUploads.expiresAt, now),
      permanentAuthorizationIsActive,
      accountSessionIsActive,
      or(
        eq(inlineProtocolUploads.status, "pending"),
        and(
          eq(inlineProtocolUploads.status, "uploading"),
          or(isNull(inlineProtocolUploads.lockedAt), lt(inlineProtocolUploads.lockedAt, staleBefore)),
        ),
      ),
    )).returning())[0]
    if (claimed) {
      return {
        kind: "claimed",
        upload: {
          uploadId: Uint8Array.from(claimed.uploadId),
          lockToken: Uint8Array.from(lockToken),
          userId: claimed.userId,
          accountSessionId: claimed.accountSessionId,
          permanentAuthKeyId: Uint8Array.from(claimed.permanentAuthKeyId),
          temporaryAuthKeyId: Uint8Array.from(claimed.issuingTemporaryAuthKeyId),
          fileName: claimed.fileName,
          mimeType: claimed.mimeType,
          byteCount: claimed.byteCount,
          sha256: Uint8Array.from(claimed.sha256),
          kind: claimed.kind as InlineProtocolUploadMetadata["kind"],
        },
      }
    }

    const existing = (await db.select({
      capabilityHash: inlineProtocolUploads.capabilityHash,
      status: inlineProtocolUploads.status,
      fileUniqueId: inlineProtocolUploads.fileUniqueId,
      expiresAt: inlineProtocolUploads.expiresAt,
    }).from(inlineProtocolUploads)
      .innerJoin(inlineProtocolAuthKeys, and(
        eq(inlineProtocolAuthKeys.authKeyId, inlineProtocolUploads.permanentAuthKeyId),
        eq(inlineProtocolAuthKeys.userId, inlineProtocolUploads.userId),
        eq(inlineProtocolAuthKeys.accountSessionId, inlineProtocolUploads.accountSessionId),
        isNull(inlineProtocolAuthKeys.revokedAt),
      ))
      .innerJoin(sessions, and(
        eq(sessions.id, inlineProtocolUploads.accountSessionId),
        eq(sessions.userId, inlineProtocolUploads.userId),
        isNull(sessions.revoked),
      ))
      .where(eq(inlineProtocolUploads.uploadId, Buffer.from(uploadId)))
      .limit(1))[0]
    if (!existing || existing.expiresAt <= now || !sameBytes(existing.capabilityHash, capabilityHash)) {
      return { kind: "rejected" }
    }
    if (existing.status === "complete" && existing.fileUniqueId) {
      return { kind: "complete", fileUniqueId: existing.fileUniqueId }
    }
    return existing.status === "uploading" ? { kind: "busy" } : { kind: "rejected" }
  }

  async complete(upload: ClaimedInlineProtocolUpload, fileUniqueId: string): Promise<boolean> {
    const completed = await db.update(inlineProtocolUploads).set({
      status: "complete",
      fileUniqueId,
      completedAt: new Date(),
      lockToken: null,
      lockedAt: null,
    }).where(and(
      eq(inlineProtocolUploads.uploadId, Buffer.from(upload.uploadId)),
      eq(inlineProtocolUploads.status, "uploading"),
      eq(inlineProtocolUploads.lockToken, Buffer.from(upload.lockToken)),
      exists(db.select({ one: sql`1` }).from(inlineProtocolAuthKeys).where(and(
        eq(inlineProtocolAuthKeys.authKeyId, inlineProtocolUploads.permanentAuthKeyId),
        eq(inlineProtocolAuthKeys.userId, inlineProtocolUploads.userId),
        eq(inlineProtocolAuthKeys.accountSessionId, inlineProtocolUploads.accountSessionId),
        isNull(inlineProtocolAuthKeys.revokedAt),
      ))),
      exists(db.select({ one: sql`1` }).from(sessions).where(and(
        eq(sessions.id, inlineProtocolUploads.accountSessionId),
        eq(sessions.userId, inlineProtocolUploads.userId),
        isNull(sessions.revoked),
      ))),
    )).returning({ uploadId: inlineProtocolUploads.uploadId })
    return completed.length === 1
  }

  async release(upload: ClaimedInlineProtocolUpload): Promise<void> {
    await db.update(inlineProtocolUploads).set({
      status: "pending",
      lockToken: null,
      lockedAt: null,
    }).where(and(
      eq(inlineProtocolUploads.uploadId, Buffer.from(upload.uploadId)),
      eq(inlineProtocolUploads.status, "uploading"),
      eq(inlineProtocolUploads.lockToken, Buffer.from(upload.lockToken)),
    ))
  }

  async finish(uploadId: Uint8Array, identity: InlineProtocolUploadOwner): Promise<
    | { kind: "pending" }
    | { kind: "complete"; fileUniqueId: string }
    | { kind: "rejected" }
  > {
    if (uploadId.length !== 16) return { kind: "rejected" }
    const row = (await db.select().from(inlineProtocolUploads).where(and(
      eq(inlineProtocolUploads.uploadId, Buffer.from(uploadId)),
      eq(inlineProtocolUploads.userId, identity.userId),
      eq(inlineProtocolUploads.accountSessionId, identity.accountSessionId),
      eq(inlineProtocolUploads.permanentAuthKeyId, Buffer.from(identity.permanentAuthKeyId)),
    )).limit(1))[0]
    if (!row || row.expiresAt <= new Date()) return { kind: "rejected" }
    if (row.status === "complete" && row.fileUniqueId) {
      return { kind: "complete", fileUniqueId: row.fileUniqueId }
    }
    return row.status === "pending" || row.status === "uploading"
      ? { kind: "pending" }
      : { kind: "rejected" }
  }
}
