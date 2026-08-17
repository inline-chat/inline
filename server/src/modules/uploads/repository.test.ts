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
  InlineUploadRepository,
} from "@in/server/db/models/inlineUploads"
import { inlineUploads } from "@in/server/db/schema"
import { makeAuthorizationKeyCipher } from "@in/server/modules/inlineProtocol/keyCipher"

setDefaultTimeout(20_000)

const authorizationKeys = () => new PermanentAuthorizationKeyRepository(
  makeAuthorizationKeyCipher({
    activeId: "test",
    keys: new Map([["test", new Uint8Array(32).fill(0x31)]]),
  }),
)

describe("native upload repository", () => {
  setupTestLifecycle()

  test("reconciles out-of-order parts and caches a completed result", async () => {
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
    })).toBe("accepted")
    expect((await repository.get(created.upload.uploadId, owner))?.acceptedParts).toEqual([1])

    const first = bytes.subarray(0, INLINE_UPLOAD_PART_SIZE)
    const firstDigest = createHash("sha256").update(first).digest()
    expect(await repository.acceptPart({
      upload: created.upload,
      partIndex: 0,
      byteCount: first.length,
      sha256: firstDigest,
      objectKey: "part-0",
    })).toBe("accepted")
    expect(await repository.acceptPart({
      upload: created.upload,
      partIndex: 0,
      byteCount: first.length,
      sha256: firstDigest,
      objectKey: "ignored-duplicate-key",
    })).toBe("already-present")

    const claim = await repository.claimFinish(created.upload.uploadId, owner)
    expect(claim.kind).toBe("claimed")
    if (claim.kind !== "claimed") throw new Error("Expected an upload finalization claim")
    expect(claim.parts.map(({ partIndex }) => partIndex)).toEqual([0, 1])
    expect(await repository.complete({
      uploadDbId: claim.upload.id,
      lockToken: claim.lockToken,
      fileUniqueId: "INDnative",
      mediaId: 44,
    })).toBe(true)

    const cached = await repository.claimFinish(created.upload.uploadId, owner)
    expect(cached.kind).toBe("complete")
    if (cached.kind === "complete") {
      expect(cached.upload.resultFileUniqueId).toBe("INDnative")
      expect(cached.upload.resultMediaId).toBe(44)
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
    expect((await repository.listExpired()).map(({ id }) => id)).toContain(created.upload.id)

    expect(await repository.cancel(created.upload.uploadId, owner))
      .toEqual({ canceled: true, alreadyTerminal: false })
    expect(await repository.cancel(created.upload.uploadId, owner))
      .toEqual({ canceled: true, alreadyTerminal: true })
    expect(await repository.claimFinish(created.upload.uploadId, owner))
      .toEqual({ kind: "rejected" })
  })
})
