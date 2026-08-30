import { createHash } from "node:crypto"
import { describe, expect, setDefaultTimeout, test } from "bun:test"
import { eq } from "drizzle-orm"
import { authKeyId } from "@inline-chat/protocol/secure"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { PermanentAuthorizationKeyRepository } from "@in/server/db/models/inlineProtocol"
import {
  INLINE_UPLOAD_PART_SIZE,
  InlineUploadMetadataConflictError,
  InlineUploadPublicationConflictError,
  InlineUploadRepository,
  inlineUploadFileUniqueId,
  inlineUploadPublicationPath,
  type InlineUploadPublication,
  type InlineUploadRecord,
} from "@in/server/db/models/inlineUploads"
import {
  documents,
  files,
  inlineUploads,
  photoSizes,
  videos,
  voices,
} from "@in/server/db/schema"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { makeAuthorizationKeyCipher } from "@in/server/modules/inlineProtocol/keyCipher"

setDefaultTimeout(60_000)

const authorizationKeys = () => new PermanentAuthorizationKeyRepository(
  makeAuthorizationKeyCipher({
    activeId: "test",
    keys: new Map([["test", new Uint8Array(32).fill(0x31)]]),
  }),
)

const publicationFile = (
  upload: InlineUploadRecord,
  fileType: InlineUploadPublication["file"]["record"]["fileType"],
): InlineUploadPublication["file"] => {
  if (!upload.resultFileUniqueId) throw new Error("Expected a reserved publication identity")
  const path = inlineUploadPublicationPath(upload.resultFileUniqueId)
  const encryptedPath = encrypt(path)
  const encryptedName = encrypt(upload.fileName)
  return {
    record: {
      fileUniqueId: upload.resultFileUniqueId,
      userId: upload.userId,
      pathEncrypted: encryptedPath.encrypted,
      pathIv: encryptedPath.iv,
      pathTag: encryptedPath.authTag,
      nameEncrypted: encryptedName.encrypted,
      nameIv: encryptedName.iv,
      nameTag: encryptedName.authTag,
      fileType,
      fileSize: Number(upload.byteCount),
      mimeType: upload.mimeType,
    },
    path,
    fileName: upload.fileName,
  }
}

const publicationFor = (upload: InlineUploadRecord): InlineUploadPublication => {
  switch (upload.kind) {
    case "photo": return {
      file: publicationFile(upload, "photo"),
      media: {
        kind: "photo",
        format: "png",
        width: 16,
        height: 12,
        stripped: null,
        strippedIv: null,
        strippedTag: null,
      },
    }
    case "video": return {
      file: publicationFile(upload, "video"),
      media: {
        kind: "video",
        width: 20,
        height: 10,
        duration: 4,
        isAnimated: false,
        hasAudio: true,
      },
    }
    case "document": {
      const encryptedName = encrypt(upload.fileName)
      return {
        file: publicationFile(upload, "document"),
        media: {
          kind: "document",
          fileName: encryptedName.encrypted,
          fileNameIv: encryptedName.iv,
          fileNameTag: encryptedName.authTag,
        },
      }
    }
    case "voice": return {
      file: publicationFile(upload, "voice"),
      media: { kind: "voice", duration: 3, waveform: Buffer.from([1, 2, 3]) },
    }
    default: throw new Error("Unexpected upload kind")
  }
}

describe("native upload repository", () => {
  setupTestLifecycle()

  test("isolates legacy session ownership from V3 permanent-key ownership", async () => {
    const user = await testUtils.createUser("native-upload-carrier-owners@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const permanentKey = new Uint8Array(256).fill(0x45)
    const permanentKeyId = authKeyId(permanentKey)
    const keys = authorizationKeys()
    await keys.create({ key: permanentKey, keyId: permanentKeyId, serverSalt: 5n, temporary: false })
    await keys.authorize(permanentKeyId, user.id, account.session.id)

    const legacyOwner = {
      userId: user.id,
      accountSessionId: account.session.id,
    }
    const v3Owner = {
      ...legacyOwner,
      permanentAuthKeyId: permanentKeyId,
    }
    const repository = new InlineUploadRepository()
    const metadata = (clientByte: number) => ({
      clientUploadId: new Uint8Array(16).fill(clientByte),
      fileName: `owner-${clientByte}.bin`,
      mimeType: "application/octet-stream",
      byteCount: 1n,
      sha256: createHash("sha256").update(new Uint8Array([clientByte])).digest(),
      kind: "document" as const,
    })

    const legacyUpload = await repository.create(legacyOwner, metadata(21))
    const v3Upload = await repository.create(v3Owner, metadata(22))

    expect(await repository.get(legacyUpload.upload.uploadId, legacyOwner)).toBeDefined()
    expect(await repository.get(legacyUpload.upload.uploadId, v3Owner)).toBeUndefined()
    expect(await repository.get(v3Upload.upload.uploadId, v3Owner)).toBeDefined()
    expect(await repository.get(v3Upload.upload.uploadId, legacyOwner)).toBeUndefined()
  })

  test("reconciles parts and deterministically publishes through the current fence", async () => {
    const user = await testUtils.createUser("native-upload@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const permanentKey = new Uint8Array(256).fill(0x41)
    const permanentKeyId = authKeyId(permanentKey)
    const keys = authorizationKeys()
    await keys.create({ key: permanentKey, keyId: permanentKeyId, serverSalt: 1n, temporary: false })
    await keys.authorize(permanentKeyId, user.id, account.session.id)

    const owner = {
      userId: user.id,
      accountSessionId: account.session.id,
      permanentAuthKeyId: permanentKeyId,
    }
    const repository = new InlineUploadRepository()
    const byteCount = INLINE_UPLOAD_PART_SIZE + 3
    const bytes = new Uint8Array(byteCount).fill(7)
    const metadata = {
      clientUploadId: new Uint8Array(16).fill(1),
      fileName: "proof.bin",
      mimeType: "application/octet-stream",
      byteCount: BigInt(byteCount),
      sha256: createHash("sha256").update(bytes).digest(),
      kind: "document" as const,
    }

    const created = await repository.create(owner, metadata)
    expect(created.created).toBe(true)
    expect(created.upload.partCount).toBe(2)
    const repeated = await repository.create(owner, metadata)
    expect(repeated.created).toBe(false)
    expect(repeated.upload.uploadId).toEqual(created.upload.uploadId)

    await expect(repository.create(owner, { ...metadata, fileName: "changed.bin" }))
      .rejects.toBeInstanceOf(InlineUploadMetadataConflictError)
    expect(await repository.claimFinish(created.upload.uploadId, owner))
      .toEqual({ kind: "missing", partIndices: [0, 1] })

    const second = bytes.subarray(INLINE_UPLOAD_PART_SIZE)
    expect(await repository.acceptPart({
      upload: created.upload,
      partIndex: 1,
      byteCount: second.length,
      sha256: createHash("sha256").update(second).digest(),
      objectKey: "part-1",
    })).toEqual({ kind: "accepted", durableObjectKey: "part-1" })
    expect((await repository.get(created.upload.uploadId, owner))?.acceptedParts).toEqual([1])
    const partTarget = await repository.getPartTarget(created.upload.uploadId, owner)
    expect(Object.keys(partTarget ?? {}).sort()).toEqual([
      "byteCount",
      "expiresAt",
      "hardExpiresAt",
      "id",
      "partCount",
      "partSize",
      "status",
    ])

    const first = bytes.subarray(0, INLINE_UPLOAD_PART_SIZE)
    const firstDigest = createHash("sha256").update(first).digest()
    expect(await repository.acceptPart({
      upload: created.upload,
      partIndex: 0,
      byteCount: first.length,
      sha256: firstDigest,
      objectKey: "part-0",
    })).toEqual({ kind: "accepted", durableObjectKey: "part-0" })
    expect(await repository.acceptPart({
      upload: created.upload,
      partIndex: 0,
      byteCount: first.length,
      sha256: firstDigest,
      objectKey: "ignored-duplicate-key",
    })).toEqual({ kind: "already-present", durableObjectKey: "part-0" })

    const claim = await repository.claimFinish(created.upload.uploadId, owner)
    expect(claim.kind).toBe("claimed")
    if (claim.kind !== "claimed") throw new Error("Expected an upload finalization claim")
    expect(claim.parts.map(({ partIndex }) => partIndex)).toEqual([0, 1])
    const fileUniqueId = inlineUploadFileUniqueId({ uploadId: created.upload.uploadId, kind: "document" })
    expect(claim.upload.resultFileUniqueId).toBe(fileUniqueId)
    const publication = publicationFor(claim.upload)

    await repository.release({ uploadDbId: claim.upload.id, lockToken: claim.lockToken })
    const reclaimed = await repository.claimFinish(created.upload.uploadId, owner)
    expect(reclaimed.kind).toBe("claimed")
    if (reclaimed.kind !== "claimed") throw new Error("Expected a replacement finalization claim")
    expect(reclaimed.upload.resultFileUniqueId).toBe(fileUniqueId)

    expect(await repository.publishComplete({
      uploadDbId: claim.upload.id,
      lockToken: claim.lockToken,
      publication,
    })).toBeUndefined()
    expect(await db.select().from(files).where(eq(files.fileUniqueId, fileUniqueId))).toHaveLength(0)

    await expect(repository.publishComplete({
      uploadDbId: reclaimed.upload.id,
      lockToken: reclaimed.lockToken,
      publication: {
        ...publication,
        file: { ...publication.file, path: `unexpected/${fileUniqueId}` },
      },
    })).rejects.toBeInstanceOf(InlineUploadPublicationConflictError)
    expect(await db.select().from(files).where(eq(files.fileUniqueId, fileUniqueId))).toHaveLength(0)

    // Treat the successful result as lost. A subsequent finish claim must
    // reconcile from the committed upload row without publishing again.
    await repository.publishComplete({
      uploadDbId: reclaimed.upload.id,
      lockToken: reclaimed.lockToken,
      publication: publicationFor(reclaimed.upload),
    })

    const cached = await repository.claimFinish(created.upload.uploadId, owner)
    expect(cached.kind).toBe("complete")
    if (cached.kind === "complete") {
      expect(cached.upload.resultFileUniqueId).toBe(fileUniqueId)
      expect(cached.upload.resultMediaId).toBeDefined()
    }
    const storedFiles = await db.select().from(files).where(eq(files.fileUniqueId, fileUniqueId))
    expect(storedFiles).toHaveLength(1)
    expect(await db.select().from(documents).where(eq(documents.fileId, storedFiles[0]!.id))).toHaveLength(1)

    await db.update(inlineUploads).set({ expiresAt: new Date(0) })
      .where(eq(inlineUploads.id, reclaimed.upload.id))
    const cleanupClaim = await repository.claimExpiredCleanup(reclaimed.upload.id)
    expect(cleanupClaim?.upload.status).toBe("complete")
    expect(await repository.claimExpiredCleanup(reclaimed.upload.id)).toBeUndefined()
    expect((await repository.listExpired()).map(({ id }) => id)).not.toContain(reclaimed.upload.id)
    // Simulate a cleanup crash after deleting only some staging parts. A new
    // owner must still see completion and preserve the permanent publication.
    await db.update(inlineUploads).set({ lockedAt: new Date(0) })
      .where(eq(inlineUploads.id, reclaimed.upload.id))
    const retriedCleanup = await repository.claimExpiredCleanup(reclaimed.upload.id)
    expect(retriedCleanup?.upload.status).toBe("complete")
    expect(retriedCleanup?.upload.resultMediaId).toBeDefined()
    expect((await repository.get(created.upload.uploadId, owner))?.status).toBe("complete")
    expect(await repository.removeCleanupClaim(
      reclaimed.upload.id,
      cleanupClaim!.cleanupToken,
    )).toBe(false)
    // Recover an interrupted cleanup created by the older implementation that
    // incorrectly changed a completed row to canceled.
    await db.update(inlineUploads).set({ status: "canceled", lockedAt: new Date(0) })
      .where(eq(inlineUploads.id, reclaimed.upload.id))
    const recoveredCleanup = await repository.claimExpiredCleanup(reclaimed.upload.id)
    expect(recoveredCleanup?.upload.status).toBe("complete")
    expect(await repository.removeCleanupClaim(
      reclaimed.upload.id,
      retriedCleanup!.cleanupToken,
    )).toBe(false)
    expect(await repository.removeCleanupClaim(
      reclaimed.upload.id,
      recoveredCleanup!.cleanupToken,
    )).toBe(true)
    expect(await db.select().from(files).where(eq(files.fileUniqueId, fileUniqueId))).toHaveLength(1)
  })

  test("publishes every native media kind inside the fenced transaction", async () => {
    const user = await testUtils.createUser("native-upload-media-kinds@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const permanentKey = new Uint8Array(256).fill(0x44)
    const permanentKeyId = authKeyId(permanentKey)
    const keys = authorizationKeys()
    await keys.create({ key: permanentKey, keyId: permanentKeyId, serverSalt: 4n, temporary: false })
    await keys.authorize(permanentKeyId, user.id, account.session.id)
    const owner = {
      userId: user.id,
      accountSessionId: account.session.id,
      permanentAuthKeyId: permanentKeyId,
    }
    const repository = new InlineUploadRepository()
    const kinds = ["photo", "video", "document", "voice"] as const

    for (const [index, kind] of kinds.entries()) {
      const bytes = new Uint8Array([index + 1, index + 2, index + 3])
      const created = await repository.create(owner, {
        clientUploadId: new Uint8Array(16).fill(index + 10),
        fileName: `${kind}.bin`,
        mimeType: "application/octet-stream",
        byteCount: BigInt(bytes.length),
        sha256: createHash("sha256").update(bytes).digest(),
        kind,
      })
      await repository.acceptPart({
        upload: created.upload,
        partIndex: 0,
        byteCount: bytes.length,
        sha256: createHash("sha256").update(bytes).digest(),
        objectKey: `${kind}-part`,
      })
      const claim = await repository.claimFinish(created.upload.uploadId, owner)
      expect(claim.kind).toBe("claimed")
      if (claim.kind !== "claimed") throw new Error("Expected an upload finalization claim")
      const fileUniqueId = claim.upload.resultFileUniqueId
      if (!fileUniqueId) throw new Error("Expected a reserved publication identity")
      const result = await repository.publishComplete({
        uploadDbId: claim.upload.id,
        lockToken: claim.lockToken,
        publication: publicationFor(claim.upload),
      })
      expect(result?.fileUniqueId).toBe(fileUniqueId)
      const [storedFile] = await db.select().from(files)
        .where(eq(files.fileUniqueId, fileUniqueId))
      expect(storedFile).toBeDefined()
      if (!storedFile) throw new Error("Expected a published file")
      const mediaRows = kind === "photo"
        ? await db.select().from(photoSizes).where(eq(photoSizes.fileId, storedFile.id))
        : kind === "video"
          ? await db.select().from(videos).where(eq(videos.fileId, storedFile.id))
          : kind === "document"
            ? await db.select().from(documents).where(eq(documents.fileId, storedFile.id))
            : await db.select().from(voices).where(eq(voices.fileId, storedFile.id))
      expect(mediaRows).toHaveLength(1)
    }
  })

  test("cancel is idempotent and terminal", async () => {
    const user = await testUtils.createUser("native-upload-cancel@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const permanentKey = new Uint8Array(256).fill(0x42)
    const permanentKeyId = authKeyId(permanentKey)
    const keys = authorizationKeys()
    await keys.create({ key: permanentKey, keyId: permanentKeyId, serverSalt: 2n, temporary: false })
    await keys.authorize(permanentKeyId, user.id, account.session.id)
    const owner = {
      userId: user.id,
      accountSessionId: account.session.id,
      permanentAuthKeyId: permanentKeyId,
    }
    const repository = new InlineUploadRepository()
    const created = await repository.create(owner, {
      clientUploadId: new Uint8Array(16).fill(2),
      fileName: "cancel.bin",
      mimeType: "application/octet-stream",
      byteCount: 3n,
      sha256: createHash("sha256").update(new Uint8Array([1, 2, 3])).digest(),
      kind: "document",
    })

    expect(await repository.activeCount(owner)).toBe(1)
    await db.update(inlineUploads).set({ expiresAt: new Date(0) })
      .where(eq(inlineUploads.id, created.upload.id))
    expect(await repository.activeCount(owner)).toBe(0)
    const expired = await repository.listExpired()
    expect(expired.map(({ id }) => id)).toContain(created.upload.id)
    expect(expired.every((row) => Object.keys(row).length === 1)).toBe(true)

    expect(await repository.cancel(created.upload.uploadId, owner))
      .toEqual({ canceled: true, alreadyTerminal: false })
    expect(await repository.cancel(created.upload.uploadId, owner))
      .toEqual({ canceled: true, alreadyTerminal: true })
    expect(await repository.claimFinish(created.upload.uploadId, owner))
      .toEqual({ kind: "rejected" })
  })

  test("processing finalization owns cancellation and expired cleanup through its fence", async () => {
    const user = await testUtils.createUser("native-upload-fence@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const permanentKey = new Uint8Array(256).fill(0x43)
    const permanentKeyId = authKeyId(permanentKey)
    const keys = authorizationKeys()
    await keys.create({ key: permanentKey, keyId: permanentKeyId, serverSalt: 3n, temporary: false })
    await keys.authorize(permanentKeyId, user.id, account.session.id)
    const owner = {
      userId: user.id,
      accountSessionId: account.session.id,
      permanentAuthKeyId: permanentKeyId,
    }
    const repository = new InlineUploadRepository()
    const bytes = new Uint8Array([4, 5, 6])
    const created = await repository.create(owner, {
      clientUploadId: new Uint8Array(16).fill(3),
      fileName: "fenced.bin",
      mimeType: "application/octet-stream",
      byteCount: BigInt(bytes.length),
      sha256: createHash("sha256").update(bytes).digest(),
      kind: "document",
    })
    await repository.acceptPart({
      upload: created.upload,
      partIndex: 0,
      byteCount: bytes.length,
      sha256: createHash("sha256").update(bytes).digest(),
      objectKey: "fenced-part",
    })
    const claim = await repository.claimFinish(created.upload.uploadId, owner)
    expect(claim.kind).toBe("claimed")
    if (claim.kind !== "claimed") throw new Error("Expected an upload finalization claim")

    expect(await repository.cancel(created.upload.uploadId, owner))
      .toEqual({ canceled: false, alreadyTerminal: false })
    expect(await repository.renew({ uploadDbId: claim.upload.id, lockToken: claim.lockToken }))
      .toBe(true)
    expect(await repository.renew({ uploadDbId: claim.upload.id, lockToken: new Uint8Array(32) }))
      .toBe(false)

    await db.update(inlineUploads).set({ expiresAt: new Date(0) })
      .where(eq(inlineUploads.id, claim.upload.id))
    expect(await repository.claimExpiredCleanup(claim.upload.id)).toBeUndefined()

    await db.update(inlineUploads).set({ lockedAt: null, expiresAt: new Date(Date.now() + 60_000) })
      .where(eq(inlineUploads.id, claim.upload.id))
    expect(await repository.claimFinish(created.upload.uploadId, owner)).toEqual({ kind: "processing" })
    await db.update(inlineUploads).set({ expiresAt: new Date(0) })
      .where(eq(inlineUploads.id, claim.upload.id))
    expect(await repository.claimExpiredCleanup(claim.upload.id)).toBeUndefined()
    expect((await repository.listExpired()).map(({ id }) => id)).not.toContain(claim.upload.id)

    await db.update(inlineUploads).set({ lockedAt: new Date(Date.now() - 6 * 60 * 1_000) })
      .where(eq(inlineUploads.id, claim.upload.id))
    const cleanupClaim = await repository.claimExpiredCleanup(claim.upload.id)
    expect(cleanupClaim?.upload.status).toBe("processing")
    expect(await repository.claimExpiredCleanup(claim.upload.id)).toBeUndefined()
    expect(await repository.renew({ uploadDbId: claim.upload.id, lockToken: claim.lockToken }))
      .toBe(false)
    expect(await repository.removeCleanupClaim(claim.upload.id, cleanupClaim!.cleanupToken)).toBe(true)
  })
})
