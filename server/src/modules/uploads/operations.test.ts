import { createHash } from "node:crypto"
import { describe, expect, setDefaultTimeout, test } from "bun:test"
import { eq } from "drizzle-orm"
import { RpcError_Code, UploadKind, UploadStatus, type UploadComplete } from "@inline-chat/protocol/core"
import { authKeyId } from "@inline-chat/protocol/secure"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { PermanentAuthorizationKeyRepository } from "@in/server/db/models/inlineProtocol"
import {
  InlineUploadRepository,
  inlineUploadPublicationPath,
} from "@in/server/db/models/inlineUploads"
import { inlineUploads, sessions } from "@in/server/db/schema"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { makeAuthorizationKeyCipher } from "@in/server/modules/inlineProtocol/keyCipher"
import type { HandlerContext } from "@in/server/realtime/types"
import type { MediaUploadFinalizer } from "./finalizer"
import { MEDIA_UPLOAD_MAX_BYTES } from "@in/server/modules/files/metadata"
import { NativeUploadOperations } from "./operations"
import { countTransferWork } from "@in/server/modules/transfers/trace"
import { INLINE_TRANSFER_PART_SIZE } from "@inline-chat/protocol/transfers"
import { sql } from "drizzle-orm"
import { UploadPartStorageUnavailableError, type UploadPartStore } from "./partStore"
import { UPLOAD_PIECE_GRANULARITY, UploadPartIntake, UploadPieceAssembler } from "./intake"

setDefaultTimeout(60_000)

const authorizationKeys = () => new PermanentAuthorizationKeyRepository(
  makeAuthorizationKeyCipher({
    activeId: "test",
    keys: new Map([["test", new Uint8Array(32).fill(0x31)]]),
  }),
)

const context = (
  userId: number,
  sessionId: number,
  permanentAuthKeyId?: Uint8Array,
): HandlerContext => ({
  userId,
  sessionId,
  connectionId: "native-upload-test",
  sendRaw: () => {},
  sendRpcReply: () => {},
  inlineProtocol: permanentAuthKeyId ? { permanentAuthKeyId } : undefined,
})

class MemoryPartStore implements UploadPartStore {
  readonly objects = new Map<string, Uint8Array>()
  afterPut?: () => Promise<void>

  async put(input: {
    uploadId: Uint8Array
    partIndex: number
    sha256: Uint8Array
    data: Uint8Array
  }): Promise<string> {
    const key = `${Buffer.from(input.uploadId).toString("hex")}/${input.partIndex}`
    this.objects.set(key, input.data.slice())
    await this.afterPut?.()
    return key
  }

  async read(key: string): Promise<Uint8Array> {
    const bytes = this.objects.get(key)
    if (!bytes) throw new Error("missing test object")
    return bytes.slice()
  }

  async remove(key: string): Promise<void> {
    this.objects.delete(key)
  }
}

const complete = (fileUniqueId: string): UploadComplete => ({
  fileUniqueId,
  media: { oneofKind: undefined },
})

const finalizer: MediaUploadFinalizer = {
  async preparePublication({ upload, parts, assertOwnership }) {
    expect(parts.map(({ partIndex }) => partIndex)).toEqual([0])
    expect(upload.kind).toBe("document")
    expect(upload.resultFileUniqueId).toBeDefined()
    await assertOwnership()
    const fileUniqueId = upload.resultFileUniqueId!
    const path = inlineUploadPublicationPath(fileUniqueId)
    const encryptedPath = encrypt(path)
    const encryptedName = encrypt(upload.fileName)
    const encryptedDocumentName = encrypt(upload.fileName)
    return {
      file: {
        record: {
          fileUniqueId,
          userId: upload.userId,
          pathEncrypted: encryptedPath.encrypted,
          pathIv: encryptedPath.iv,
          pathTag: encryptedPath.authTag,
          nameEncrypted: encryptedName.encrypted,
          nameIv: encryptedName.iv,
          nameTag: encryptedName.authTag,
          fileType: "document",
          fileSize: Number(upload.byteCount),
          mimeType: upload.mimeType,
        },
        path,
        fileName: upload.fileName,
      },
      media: {
        kind: "document",
        fileName: encryptedDocumentName.encrypted,
        fileNameIv: encryptedDocumentName.iv,
        fileNameTag: encryptedDocumentName.authTag,
      },
    }
  },
  async prepareStoredPublication() {
    throw new Error("Stored publication is worker-owned in operations tests")
  },
  async prepareBufferedPublication() {
    throw new Error("Buffered publication is worker-owned in operations tests")
  },
  async discardPublication() {},
  async project(_kind, fileUniqueId) {
    return complete(fileUniqueId)
  },
}

describe("native upload operations", () => {
  setupTestLifecycle()

  test("reconciles an accepted part after a lost manifest commit response", async () => {
    class Repository extends InlineUploadRepository {
      override async acceptPartFast(
        input: Parameters<InlineUploadRepository["acceptPartFast"]>[0],
      ): ReturnType<InlineUploadRepository["acceptPartFast"]> {
        await super.acceptPartFast(input)
        throw new Error("commit response lost")
      }
    }
    const user = await testUtils.createUser("native-upload-commit-lost@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const store = new MemoryPartStore()
    const operations = new NativeUploadOperations(new Repository(), store, finalizer)
    const requestContext = context(user.id, account.session.id)
    const body = new Uint8Array([1, 2, 3])
    const created = await operations.create({
      clientUploadId: new Uint8Array(16).fill(61), fileName: "commit-lost.bin",
      mimeType: "application/octet-stream", byteCount: 3n,
      sha256: createHash("sha256").update(body).digest(), kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, requestContext)
    expect(await operations.savePart({ uploadId: created.uploadId, partIndex: 0, data: body }, requestContext))
      .toEqual({ alreadyPresent: true })
    expect(store.objects.size).toBe(1)
    expect((await operations.state({ uploadId: created.uploadId }, requestContext)).acceptedParts).toEqual([0])
  })

  test("retains an unmanifested object on DB failure so an identical save can safely retry", async () => {
    class Repository extends InlineUploadRepository {
      failAcceptance = true
      override async acceptPartFast(input: Parameters<InlineUploadRepository["acceptPartFast"]>[0]) {
        if (this.failAcceptance) throw new Error("database unavailable")
        return super.acceptPartFast(input)
      }
    }
    const user = await testUtils.createUser("native-upload-accept-unavailable@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const repository = new Repository()
    const store = new MemoryPartStore()
    const operations = new NativeUploadOperations(repository, store, finalizer)
    const requestContext = context(user.id, account.session.id)
    const body = new Uint8Array([4, 5, 6])
    const created = await operations.create({
      clientUploadId: new Uint8Array(16).fill(62), fileName: "accept-unavailable.bin",
      mimeType: "application/octet-stream", byteCount: 3n,
      sha256: createHash("sha256").update(body).digest(), kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, requestContext)
    const part = { uploadId: created.uploadId, partIndex: 0, data: body }
    await expect(operations.savePart(part, requestContext)).rejects.toThrow("database unavailable")
    expect(store.objects.size).toBe(1)
    repository.failAcceptance = false
    expect(await operations.savePart(part, requestContext)).toEqual({ alreadyPresent: false })
    expect(store.objects.size).toBe(1)
    expect((await operations.state({ uploadId: created.uploadId }, requestContext)).acceptedParts).toEqual([0])
  })

  test("requires a flat document name before reserving an upload", async () => {
    const operations = new NativeUploadOperations(new InlineUploadRepository(), new MemoryPartStore(), finalizer)
    await expect(operations.create({
      clientUploadId: new Uint8Array(16), fileName: "folder%2Fnotes.pdf", mimeType: "application/pdf",
      byteCount: 1n, sha256: new Uint8Array(32), kind: UploadKind.DOCUMENT, metadata: { oneofKind: undefined },
    }, context(1, 2))).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
  })

  test("rejects impossible media sizes before reserving quota or looking up an owner", async () => {
    let ownerLookups = 0
    class Repository extends InlineUploadRepository {
      override async resolveOwner() { ownerLookups += 1; return undefined }
    }
    const operations = new NativeUploadOperations(new Repository(), new MemoryPartStore(), finalizer)
    for (const [kind, maximum] of [
      [UploadKind.PHOTO, MEDIA_UPLOAD_MAX_BYTES.photo], [UploadKind.VIDEO, MEDIA_UPLOAD_MAX_BYTES.video],
      [UploadKind.DOCUMENT, MEDIA_UPLOAD_MAX_BYTES.document], [UploadKind.VOICE, MEDIA_UPLOAD_MAX_BYTES.voice],
    ] as const) {
      await expect(operations.create({
        clientUploadId: new Uint8Array(16), fileName: "too-large.bin", mimeType: "application/octet-stream",
        byteCount: BigInt(maximum) + 1n, sha256: new Uint8Array(32), kind, metadata: { oneofKind: undefined },
      }, context(1, 2))).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
    }
    expect(ownerLookups).toBe(0)
  })

  test.each([UploadKind.DOCUMENT, UploadKind.VIDEO])("reserves a 500 MB media file (%s) with valid multipart geometry", async (kind) => {
    const user = await testUtils.createUser("native-upload-500mb@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const operations = new NativeUploadOperations(new InlineUploadRepository(), new MemoryPartStore(), finalizer)
    const created = await operations.create({
      clientUploadId: new Uint8Array(16).fill(83), fileName: kind === UploadKind.VIDEO ? "boundary.mp4" : "boundary.zip",
      mimeType: kind === UploadKind.VIDEO ? "video/mp4" : "application/zip",
      byteCount: 500_000_000n, sha256: new Uint8Array(32).fill(83), kind,
      metadata: kind === UploadKind.VIDEO ? { oneofKind: "video", video: { width: 1280, height: 720, duration: 10, isAnimated: false, hasAudio: true } } : { oneofKind: undefined },
    }, context(user.id, account.session.id))
    expect(created.partSize).toBe(524_288)
    expect(created.partCount).toBe(954)
    expect((await operations.state({ uploadId: created.uploadId }, context(user.id, account.session.id))).status)
      .toBe(UploadStatus.UPLOADING)
  })

  test("accepts only JPEG or PNG as native photos while preserving WebP documents", async () => {
    const user = await testUtils.createUser("native-upload-photo-formats@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const operations = new NativeUploadOperations(
      new InlineUploadRepository(), new MemoryPartStore(), finalizer,
    )
    const requestContext = context(user.id, account.session.id)
    const base = {
      clientUploadId: new Uint8Array(16).fill(81),
      fileName: "image.webp",
      mimeType: "image/webp",
      byteCount: 1n,
      sha256: createHash("sha256").update(new Uint8Array([1])).digest(),
      metadata: { oneofKind: undefined } as const,
    }
    await expect(operations.create({ ...base, kind: UploadKind.PHOTO }, requestContext))
      .rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
    expect((await operations.create({
      ...base,
      clientUploadId: new Uint8Array(16).fill(82),
      kind: UploadKind.DOCUMENT,
    }, requestContext)).partCount).toBe(1)
  })

  test("persists processing without executing finalization in the request", async () => {
    const user = await testUtils.createUser("native-upload-stolen-fence@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    let prepared = false
    const operations = new NativeUploadOperations(new InlineUploadRepository(), new MemoryPartStore(), {
      ...finalizer, async preparePublication(input) { prepared = true; return finalizer.preparePublication(input) },
    })
    const requestContext = context(user.id, account.session.id)
    const body = new Uint8Array([1, 2, 3])
    const created = await operations.create({
      clientUploadId: new Uint8Array(16).fill(17), fileName: "proof.bin", mimeType: "application/octet-stream",
      byteCount: 3n, sha256: createHash("sha256").update(body).digest(), kind: UploadKind.DOCUMENT, metadata: { oneofKind: undefined },
    }, requestContext)
    await operations.savePart({ uploadId: created.uploadId, partIndex: 0, data: body }, requestContext)
    expect((await operations.finish({ uploadId: created.uploadId }, requestContext)).state.oneofKind).toBe("processing")
    expect((await operations.state({ uploadId: created.uploadId }, requestContext)).status).toBe(UploadStatus.PROCESSING)
    expect(prepared).toBe(false)
  })

  test("finish latency is independent of a worker lease renewal", async () => {
    class Repository extends InlineUploadRepository {
      override async renew(): Promise<boolean> {
        return new Promise(() => {})
      }
    }
    const user = await testUtils.createUser("native-upload-hung-renewal@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const store = new MemoryPartStore()
    const operations = new NativeUploadOperations(new Repository(), store, finalizer)
    const requestContext = context(user.id, account.session.id)
    const body = new Uint8Array([7, 8, 9])
    const created = await operations.create({
      clientUploadId: new Uint8Array(16).fill(18), fileName: "lease.bin", mimeType: "application/octet-stream",
      byteCount: 3n, sha256: createHash("sha256").update(body).digest(), kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, requestContext)
    await operations.savePart({ uploadId: created.uploadId, partIndex: 0, data: body }, requestContext)

    const result = await Promise.race([
      operations.finish({ uploadId: created.uploadId }, requestContext),
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error("finish request was pinned")), 250)),
    ])
    expect(result.state.oneofKind).toBe("processing")
  })

  test("runs create, durable save, reconciliation, and durable finish intent", async () => {
    const user = await testUtils.createUser("native-upload-operations@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const permanentKey = new Uint8Array(256).fill(0x51)
    const permanentKeyId = authKeyId(permanentKey)
    const keys = authorizationKeys()
    await keys.create({ key: permanentKey, keyId: permanentKeyId, serverSalt: 1n, temporary: false })
    await keys.authorize(permanentKeyId, user.id, account.session.id)

    const store = new MemoryPartStore()
    const wakes: number[] = []
    const operations = new NativeUploadOperations(
      new InlineUploadRepository(), store, finalizer, (uploadDbId) => wakes.push(uploadDbId),
    )
    const requestContext = context(user.id, account.session.id, permanentKeyId)
    const body = new TextEncoder().encode("native upload body")
    const create = await operations.create({
      clientUploadId: new Uint8Array(16).fill(3),
      fileName: "proof.bin",
      mimeType: "application/octet-stream",
      byteCount: BigInt(body.length),
      sha256: createHash("sha256").update(body).digest(),
      kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, requestContext)
    expect(create.partCount).toBe(1)
    expect(create.acceptedParts).toEqual([])

    expect(await operations.finish({ uploadId: create.uploadId }, requestContext))
      .toEqual({ state: { oneofKind: "missing", missing: { partIndices: [0] } } })
    expect(await operations.savePart({
      uploadId: create.uploadId,
      partIndex: 0,
      data: body,
    }, requestContext)).toEqual({ alreadyPresent: false })
    expect(await operations.savePart({
      uploadId: create.uploadId,
      partIndex: 0,
      data: body,
    }, requestContext)).toEqual({ alreadyPresent: true })
    expect(await operations.state({ uploadId: create.uploadId }, requestContext))
      .toMatchObject({ status: UploadStatus.UPLOADING, acceptedParts: [0] })

    expect(await operations.finish({ uploadId: create.uploadId }, requestContext))
      .toEqual({ state: { oneofKind: "processing", processing: { retryAfterSeconds: 1 } } })
    expect(store.objects.size).toBe(1)
    // A one-part upload completes no full storage group; only finish wakes the worker.
    expect(wakes).toHaveLength(1)
    expect(await operations.finish({ uploadId: create.uploadId }, requestContext))
      .toEqual({ state: { oneofKind: "processing", processing: { retryAfterSeconds: 1 } } })
  })

  test("does not turn a lost in-process wake into a lost part ACK or finish intent", async () => {
    const user = await testUtils.createUser("native-upload-lost-wake@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const operations = new NativeUploadOperations(
      new InlineUploadRepository(),
      new MemoryPartStore(),
      finalizer,
      () => { throw new Error("worker unavailable") },
    )
    const requestContext = context(user.id, account.session.id)
    const body = new Uint8Array([3, 2, 1])
    const created = await operations.create({
      clientUploadId: new Uint8Array(16).fill(83),
      fileName: "lost-wake.bin",
      mimeType: "application/octet-stream",
      byteCount: 3n,
      sha256: createHash("sha256").update(body).digest(),
      kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, requestContext)
    expect(await operations.savePart({
      uploadId: created.uploadId, partIndex: 0, data: body,
    }, requestContext)).toEqual({ alreadyPresent: false })
    expect((await operations.finish({ uploadId: created.uploadId }, requestContext)).state.oneofKind)
      .toBe("processing")
    expect((await operations.state({ uploadId: created.uploadId }, requestContext)).status)
      .toBe(UploadStatus.PROCESSING)
  })

  test("supports the approved Realtime V2 upload fallback without a V3 authorization key", async () => {
    const user = await testUtils.createUser("native-upload-legacy-owner@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const store = new MemoryPartStore()
    const operations = new NativeUploadOperations(
      new InlineUploadRepository(),
      store,
      finalizer,
    )
    const requestContext = context(user.id, account.session.id)
    const body = new TextEncoder().encode("legacy bearer upload body")
    const create = await operations.create({
      clientUploadId: new Uint8Array(16).fill(13),
      fileName: "legacy-proof.bin",
      mimeType: "application/octet-stream",
      byteCount: BigInt(body.length),
      sha256: createHash("sha256").update(body).digest(),
      kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, requestContext)

    const [row] = await db.select({
      permanentAuthKeyId: inlineUploads.permanentAuthKeyId,
    }).from(inlineUploads).where(eq(inlineUploads.uploadId, Buffer.from(create.uploadId))).limit(1)
    expect(row?.permanentAuthKeyId).toBeNull()

    expect(await operations.savePart({
      uploadId: create.uploadId,
      partIndex: 0,
      data: body,
    }, requestContext)).toEqual({ alreadyPresent: false })
    expect(await operations.finish({ uploadId: create.uploadId }, requestContext))
      .toEqual({
        state: {
          oneofKind: "processing",
          processing: { retryAfterSeconds: 1 },
        },
      })
  })

  test("reports a revoked upload owner as an operation failure, not account authentication loss", async () => {
    const user = await testUtils.createUser("native-upload-revoked-owner@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    await db.update(sessions).set({ revoked: new Date() }).where(eq(sessions.id, account.session.id))
    const operations = new NativeUploadOperations(
      new InlineUploadRepository(),
      new MemoryPartStore(),
      finalizer,
    )

    await expect(operations.create({
      clientUploadId: new Uint8Array(16).fill(14),
      fileName: "revoked.bin",
      mimeType: "application/octet-stream",
      byteCount: 1n,
      sha256: new Uint8Array(32).fill(14),
      kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, context(user.id, account.session.id))).rejects.toMatchObject({
      code: RpcError_Code.INTERNAL_ERROR,
    })
  })

  test("removes a part object when cancellation wins before manifest acceptance", async () => {
    const user = await testUtils.createUser("native-upload-part-cancel-race@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const permanentKey = new Uint8Array(256).fill(0x55)
    const permanentKeyId = authKeyId(permanentKey)
    const keys = authorizationKeys()
    await keys.create({ key: permanentKey, keyId: permanentKeyId, serverSalt: 5n, temporary: false })
    await keys.authorize(permanentKeyId, user.id, account.session.id)
    const owner = {
      userId: user.id,
      accountSessionId: account.session.id,
      permanentAuthKeyId: permanentKeyId,
    }
    const repository = new InlineUploadRepository()
    const store = new MemoryPartStore()
    const operations = new NativeUploadOperations(repository, store, finalizer)
    const requestContext = context(user.id, account.session.id, permanentKeyId)
    const body = new TextEncoder().encode("cancel between object and manifest")
    const create = await operations.create({
      clientUploadId: new Uint8Array(16).fill(5),
      fileName: "cancel-race.bin",
      mimeType: "application/octet-stream",
      byteCount: BigInt(body.length),
      sha256: createHash("sha256").update(body).digest(),
      kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, requestContext)
    store.afterPut = async () => {
      expect((await repository.cancel(create.uploadId, owner))?.result).toEqual({
        canceled: true,
        alreadyTerminal: false,
      })
    }

    await expect(operations.savePart({
      uploadId: create.uploadId,
      partIndex: 0,
      data: body,
    }, requestContext)).rejects.toBeDefined()
    expect(store.objects.size).toBe(0)
    const upload = await repository.get(create.uploadId, owner)
    expect(upload).toBeDefined()
    expect(await repository.getPart(upload!.id, 0)).toBeUndefined()
  })

  test("aborts the multipart session locked by cancel instead of a stale pre-cancel snapshot", async () => {
    const storageUploadId = "session-installed-during-cancel"
    class Repository extends InlineUploadRepository {
      override async cancel(
        uploadId: Uint8Array,
        owner: Parameters<InlineUploadRepository["cancel"]>[1],
      ): ReturnType<InlineUploadRepository["cancel"]> {
        await db.update(inlineUploads).set({ storageUploadId })
          .where(eq(inlineUploads.uploadId, Buffer.from(uploadId)))
        return super.cancel(uploadId, owner)
      }
    }
    const user = await testUtils.createUser("native-upload-storage-cancel-race@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const discarded: string[] = []
    const operations = new NativeUploadOperations(
      new Repository(),
      new MemoryPartStore(),
      finalizer,
      () => {},
      async (upload) => { if (upload.storageUploadId) discarded.push(upload.storageUploadId) },
    )
    const requestContext = context(user.id, account.session.id)
    const created = await operations.create({
      clientUploadId: new Uint8Array(16).fill(84),
      fileName: "cancel-session-race.bin",
      mimeType: "application/octet-stream",
      byteCount: 1n,
      sha256: createHash("sha256").update(new Uint8Array([1])).digest(),
      kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, requestContext)

    expect(await operations.cancel({ uploadId: created.uploadId }, requestContext)).toEqual({
      canceled: true,
      alreadyTerminal: false,
    })
    expect(discarded).toEqual([storageUploadId])
  })

  test("rejects existing and new parts after the upload hard expiry", async () => {
    const user = await testUtils.createUser("native-upload-hard-expiry@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const permanentKey = new Uint8Array(256).fill(0x56)
    const permanentKeyId = authKeyId(permanentKey)
    const keys = authorizationKeys()
    await keys.create({ key: permanentKey, keyId: permanentKeyId, serverSalt: 6n, temporary: false })
    await keys.authorize(permanentKeyId, user.id, account.session.id)
    const repository = new InlineUploadRepository()
    const store = new MemoryPartStore()
    const operations = new NativeUploadOperations(repository, store, finalizer)
    const requestContext = context(user.id, account.session.id, permanentKeyId)
    const body = new TextEncoder().encode("hard-expiry")

    const createUpload = (clientByte: number) => operations.create({
      clientUploadId: new Uint8Array(16).fill(clientByte),
      fileName: `hard-expiry-${clientByte}.bin`,
      mimeType: "application/octet-stream",
      byteCount: BigInt(body.length),
      sha256: createHash("sha256").update(body).digest(),
      kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, requestContext)

    const existing = await createUpload(6)
    await operations.savePart({ uploadId: existing.uploadId, partIndex: 0, data: body }, requestContext)
    const fresh = await createUpload(7)
    await db.update(inlineUploads).set({ hardExpiresAt: new Date(0) })
      .where(eq(inlineUploads.accountSessionId, account.session.id))

    expect((await operations.state({ uploadId: fresh.uploadId }, requestContext)).status)
      .toBe(UploadStatus.EXPIRED)

    await expect(operations.savePart({
      uploadId: existing.uploadId,
      partIndex: 0,
      data: body,
    }, requestContext)).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
    await expect(operations.savePart({
      uploadId: fresh.uploadId,
      partIndex: 0,
      data: body,
    }, requestContext)).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
    expect(store.objects.size).toBe(1)
  })

  test("rejects new uploads above the per-session reserved-byte budget", async () => {
    const user = await testUtils.createUser("native-upload-byte-budget@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const permanentKey = new Uint8Array(256).fill(0x52)
    const permanentKeyId = authKeyId(permanentKey)
    const keys = authorizationKeys()
    await keys.create({ key: permanentKey, keyId: permanentKeyId, serverSalt: 2n, temporary: false })
    await keys.authorize(permanentKeyId, user.id, account.session.id)
    const operations = new NativeUploadOperations(
      new InlineUploadRepository(),
      new MemoryPartStore(),
      finalizer,
    )
    const requestContext = context(user.id, account.session.id, permanentKeyId)
    const maximumFileBytes = 200_000_000n

    for (let index = 0; index < 10; index += 1) {
      await operations.create({
        clientUploadId: new Uint8Array(16).fill(index + 1),
        fileName: `reserved-${index}.bin`,
        mimeType: "application/octet-stream",
        byteCount: maximumFileBytes,
        sha256: new Uint8Array(32).fill(index + 1),
        kind: UploadKind.DOCUMENT,
        metadata: { oneofKind: undefined },
      }, requestContext)
    }

    await expect(operations.create({
      clientUploadId: new Uint8Array(16).fill(11),
      fileName: "over-budget.bin",
      mimeType: "application/octet-stream",
      byteCount: maximumFileBytes,
      sha256: new Uint8Array(32).fill(11),
      kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, requestContext)).rejects.toMatchObject({ code: RpcError_Code.RATE_LIMIT })
  })

  test("serializes concurrent create admission at the per-session upload limit", async () => {
    const user = await testUtils.createUser("native-upload-concurrent-admission@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const permanentKey = new Uint8Array(256).fill(0x53)
    const permanentKeyId = authKeyId(permanentKey)
    const keys = authorizationKeys()
    await keys.create({ key: permanentKey, keyId: permanentKeyId, serverSalt: 3n, temporary: false })
    await keys.authorize(permanentKeyId, user.id, account.session.id)
    const operations = new NativeUploadOperations(
      new InlineUploadRepository(),
      new MemoryPartStore(),
      finalizer,
    )
    const requestContext = context(user.id, account.session.id, permanentKeyId)

    const outcomes = await Promise.allSettled(Array.from({ length: 21 }, (_, index) =>
      operations.create({
        clientUploadId: new Uint8Array(16).fill(index + 1),
        fileName: `concurrent-${index}.bin`,
        mimeType: "application/octet-stream",
        byteCount: 1n,
        sha256: new Uint8Array(32).fill(index + 1),
        kind: UploadKind.DOCUMENT,
        metadata: { oneofKind: undefined },
      }, requestContext)))

    expect(outcomes.filter(({ status }) => status === "fulfilled")).toHaveLength(20)
    const rejected = outcomes.filter(({ status }) => status === "rejected")
    expect(rejected).toHaveLength(1)
    expect(rejected[0]).toMatchObject({ reason: { code: RpcError_Code.RATE_LIMIT } })
  })

  test("accepts a new part with one statement and resolves duplicates and conflicts from the manifest", async () => {
    const user = await testUtils.createUser("native-upload-one-statement@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const store = new MemoryPartStore()
    const operations = new NativeUploadOperations(new InlineUploadRepository(), store, finalizer)
    const requestContext = context(user.id, account.session.id)
    const first = new Uint8Array(INLINE_TRANSFER_PART_SIZE).fill(1)
    const second = new Uint8Array(3).fill(2)
    const created = await operations.create({
      clientUploadId: new Uint8Array(16).fill(101), fileName: "one-statement.bin",
      mimeType: "application/octet-stream", byteCount: BigInt(first.length + second.length),
      sha256: createHash("sha256").update(first).update(second).digest(), kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, requestContext)

    const accepted = await countTransferWork(() => operations.savePart({
      uploadId: created.uploadId, partIndex: 0, data: first,
    }, requestContext))
    expect(accepted.value).toEqual({ alreadyPresent: false })
    expect(accepted.counters.sqlStatements).toBe(1)

    const duplicate = await countTransferWork(() => operations.savePart({
      uploadId: created.uploadId, partIndex: 0, data: first,
    }, requestContext))
    expect(duplicate.value).toEqual({ alreadyPresent: true })
    // The statement inserts nothing; one manifest read classifies the duplicate.
    expect(duplicate.counters.sqlStatements).toBe(2)
    expect((await operations.state({ uploadId: created.uploadId }, requestContext)).acceptedParts).toEqual([0])
    expect(store.objects.size).toBe(1)

    await expect(operations.savePart({
      uploadId: created.uploadId, partIndex: 0, data: new Uint8Array(INLINE_TRANSFER_PART_SIZE).fill(9),
    }, requestContext)).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
    await expect(operations.savePart({
      uploadId: created.uploadId, partIndex: 1, data: new Uint8Array(4),
    }, requestContext)).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })

    // A cold cache costs one geometry statement before the accept.
    const cold = new NativeUploadOperations(new InlineUploadRepository(), store, finalizer)
    const coldAccept = await countTransferWork(() => cold.savePart({
      uploadId: created.uploadId, partIndex: 1, data: second,
    }, requestContext))
    expect(coldAccept.value).toEqual({ alreadyPresent: false })
    expect(coldAccept.counters.sqlStatements).toBe(2)
    await expect(cold.savePart({
      uploadId: created.uploadId, partIndex: 1, data: second,
    }, context(user.id + 1_000_000, account.session.id))).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
  })

  test("a resent part after finish keeps the durable staging object", async () => {
    const user = await testUtils.createUser("native-upload-resend-after-finish@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const store = new MemoryPartStore()
    const operations = new NativeUploadOperations(new InlineUploadRepository(), store, finalizer)
    const requestContext = context(user.id, account.session.id)
    const body = new Uint8Array([7, 7, 7])
    const created = await operations.create({
      clientUploadId: new Uint8Array(16).fill(102), fileName: "resend.bin",
      mimeType: "application/octet-stream", byteCount: 3n,
      sha256: createHash("sha256").update(body).digest(), kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, requestContext)
    await operations.savePart({ uploadId: created.uploadId, partIndex: 0, data: body }, requestContext)
    const stale = new NativeUploadOperations(new InlineUploadRepository(), store, finalizer)
    await stale.savePart({ uploadId: created.uploadId, partIndex: 0, data: body }, requestContext)
    expect((await operations.finish({ uploadId: created.uploadId }, requestContext)).state.oneofKind).toBe("processing")
    // The stale process still caches uploading geometry; its resend is terminal, but the part is
    // in the file, so it is acknowledged like a cache miss would be.
    expect(await stale.savePart({ uploadId: created.uploadId, partIndex: 0, data: body }, requestContext))
      .toEqual({ alreadyPresent: true })
    // The worker may still read the staging object while processing.
    expect(store.objects.size).toBe(1)
  })

  test("a stale resend after cleanup removes its rewritten staging object", async () => {
    const user = await testUtils.createUser("native-upload-resend-after-cleanup@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const store = new MemoryPartStore()
    const operations = new NativeUploadOperations(new InlineUploadRepository(), store, finalizer)
    const requestContext = context(user.id, account.session.id)
    const make = async (fill: number) => {
      const body = new Uint8Array([fill, fill, fill])
      const created = await operations.create({
        clientUploadId: new Uint8Array(16).fill(fill), fileName: `cleaned-${fill}.bin`,
        mimeType: "application/octet-stream", byteCount: 3n,
        sha256: createHash("sha256").update(body).digest(), kind: UploadKind.DOCUMENT,
        metadata: { oneofKind: undefined },
      }, requestContext)
      const stale = new NativeUploadOperations(new InlineUploadRepository(), store, finalizer)
      await stale.savePart({ uploadId: created.uploadId, partIndex: 0, data: body }, requestContext)
      return { created, stale, part: { uploadId: created.uploadId, partIndex: 0, data: body } }
    }

    // Completed and staging already removed: acknowledged, and the rewrite is not left behind.
    const done = await make(105)
    await db.update(inlineUploads).set({ status: "complete" })
      .where(eq(inlineUploads.uploadId, Buffer.from(done.created.uploadId)))
    store.objects.clear()
    expect(await done.stale.savePart(done.part, requestContext)).toEqual({ alreadyPresent: true })
    expect(store.objects.size).toBe(0)

    // Canceled: still rejected, and the rewrite is removed too.
    const canceled = await make(106)
    expect((await operations.cancel({ uploadId: canceled.created.uploadId }, requestContext)).canceled).toBe(true)
    expect(store.objects.size).toBe(0)
    await expect(canceled.stale.savePart(canceled.part, requestContext))
      .rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
    expect(store.objects.size).toBe(0)
  })

  test("a part resent after finish in the same process is acknowledged as already present", async () => {
    const user = await testUtils.createUser("native-upload-late-part@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const store = new MemoryPartStore()
    const operations = new NativeUploadOperations(new InlineUploadRepository(), store, finalizer)
    const requestContext = context(user.id, account.session.id)
    const body = new Uint8Array([5, 5, 5])
    const created = await operations.create({
      clientUploadId: new Uint8Array(16).fill(103), fileName: "late.bin",
      mimeType: "application/octet-stream", byteCount: 3n,
      sha256: createHash("sha256").update(body).digest(), kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, requestContext)
    await operations.savePart({ uploadId: created.uploadId, partIndex: 0, data: body }, requestContext)
    expect((await operations.finish({ uploadId: created.uploadId }, requestContext)).state.oneofKind).toBe("processing")
    // The reply to the original part was lost; the client resends it after finishing.
    expect(await operations.savePart({ uploadId: created.uploadId, partIndex: 0, data: body }, requestContext))
      .toEqual({ alreadyPresent: true })
    expect(store.objects.size).toBe(1)
  })

  test("a part storage outage is a retryable 503 with a wait hint", async () => {
    class UnavailableStore extends MemoryPartStore {
      override async put(): Promise<string> {
        throw new UploadPartStorageUnavailableError()
      }
    }
    const user = await testUtils.createUser("native-upload-storage-outage@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const operations = new NativeUploadOperations(new InlineUploadRepository(), new UnavailableStore(), finalizer)
    const requestContext = context(user.id, account.session.id)
    const body = new Uint8Array([6, 6, 6])
    const created = await operations.create({
      clientUploadId: new Uint8Array(16).fill(104), fileName: "outage.bin",
      mimeType: "application/octet-stream", byteCount: 3n,
      sha256: createHash("sha256").update(body).digest(), kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, requestContext)
    await expect(operations.savePart({ uploadId: created.uploadId, partIndex: 0, data: body }, requestContext))
      .rejects.toMatchObject({ codeNumber: 503, retryAfterSeconds: 5 })
  })

  test("concurrent parts of one upload do not wait on each other", async () => {
    const user = await testUtils.createUser("native-upload-no-row-lock@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const repository = new InlineUploadRepository()
    const operations = new NativeUploadOperations(repository, new MemoryPartStore(), finalizer)
    const requestContext = context(user.id, account.session.id)
    const part = new Uint8Array(INLINE_TRANSFER_PART_SIZE).fill(4)
    const created = await operations.create({
      clientUploadId: new Uint8Array(16).fill(103), fileName: "parallel.bin",
      mimeType: "application/octet-stream", byteCount: BigInt(part.length * 3),
      sha256: createHash("sha256").update(part).update(part).update(part).digest(), kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, requestContext)
    await operations.savePart({ uploadId: created.uploadId, partIndex: 0, data: part }, requestContext)
    const [row] = await db.select({ id: inlineUploads.id }).from(inlineUploads)
      .where(eq(inlineUploads.uploadId, Buffer.from(created.uploadId))).limit(1)

    // Hold an uncommitted accept of part 1, as a concurrent save in flight would.
    let release!: () => void
    const held = new Promise<void>((resolve) => { release = resolve })
    let holding!: () => void
    const isHolding = new Promise<void>((resolve) => { holding = resolve })
    const open = db.transaction(async (tx) => {
      await tx.execute(sql`insert into inline_upload_parts
        (upload_id, part_index, byte_count, sha256, stored_byte_count, stored_sha256, object_key)
        values (${row!.id}, 1, ${part.length}, ${createHash("sha256").update(part).digest()},
          ${part.length}, ${createHash("sha256").update(part).digest()}, 'held-part')`)
      holding()
      await held
    })
    await isHolding
    const concurrent = operations.savePart({ uploadId: created.uploadId, partIndex: 2, data: part }, requestContext)
    const outcome = await Promise.race([
      concurrent.then(() => "accepted" as const),
      Bun.sleep(5_000).then(() => "blocked" as const),
    ])
    release()
    await open
    await concurrent
    expect(outcome).toBe("accepted")
    expect((await operations.state({ uploadId: created.uploadId }, requestContext)).acceptedParts).toEqual([0, 1, 2])
  })

  test("wakes the worker once per completed ten-frame group and never for the tail", async () => {
    const user = await testUtils.createUser("native-upload-group-wakes@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const wakes: Array<[number, number | undefined]> = []
    const operations = new NativeUploadOperations(
      new InlineUploadRepository(), new MemoryPartStore(), finalizer,
      (uploadDbId, groupNumber) => { wakes.push([uploadDbId, groupNumber]) },
    )
    const requestContext = context(user.id, account.session.id)
    const partCount = 25
    const part = new Uint8Array(INLINE_TRANSFER_PART_SIZE).fill(6)
    const digest = createHash("sha256")
    for (let index = 0; index < partCount; index += 1) digest.update(part)
    const created = await operations.create({
      clientUploadId: new Uint8Array(16).fill(104), fileName: "groups.bin",
      mimeType: "application/octet-stream", byteCount: BigInt(part.length * partCount),
      sha256: digest.digest(), kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, requestContext)
    const order = Array.from({ length: partCount }, (_, index) => (index * 7) % partCount)
    for (const partIndex of order) {
      await operations.savePart({ uploadId: created.uploadId, partIndex, data: part }, requestContext)
    }
    await operations.savePart({ uploadId: created.uploadId, partIndex: 3, data: part }, requestContext)
    const uploadDbId = wakes[0]?.[0]
    expect(wakes.map(([, group]) => group).sort()).toEqual([1, 2])
    expect(wakes.every(([id]) => id === uploadDbId)).toBeTrue()
  })

  test("never wakes group compaction for an upload that is one full ten-frame group", async () => {
    const user = await testUtils.createUser("native-upload-single-group-wakes@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const wakes: Array<number | undefined> = []
    const operations = new NativeUploadOperations(
      new InlineUploadRepository(), new MemoryPartStore(), finalizer,
      (_uploadDbId, groupNumber) => { wakes.push(groupNumber) },
    )
    const requestContext = context(user.id, account.session.id)
    const part = new Uint8Array(INLINE_TRANSFER_PART_SIZE).fill(7)
    const last = new Uint8Array(INLINE_TRANSFER_PART_SIZE - 1).fill(7)
    const digest = createHash("sha256")
    for (let index = 0; index < 9; index += 1) digest.update(part)
    const created = await operations.create({
      clientUploadId: new Uint8Array(16).fill(107), fileName: "ten-parts.bin",
      mimeType: "application/octet-stream", byteCount: BigInt(part.length * 9 + last.length),
      sha256: digest.update(last).digest(), kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, requestContext)
    expect(created.partCount).toBe(10)
    for (let partIndex = 0; partIndex < 10; partIndex += 1) {
      await operations.savePart({ uploadId: created.uploadId, partIndex, data: partIndex === 9 ? last : part }, requestContext)
    }
    // Finish stores it with one PUT; an early group pass would open a multipart session instead.
    expect(wakes).toEqual([])
  })

  const fastOperations = (store: MemoryPartStore, options: { intake?: UploadPartIntake } = {}) =>
    new NativeUploadOperations(new InlineUploadRepository(), store, finalizer, () => {}, async () => {}, () => {}, {
      intake: options.intake ?? new UploadPartIntake({
        isStorageOutage: (error) => (error as { codeNumber?: number }).codeNumber === 503,
      }),
      pieces: new UploadPieceAssembler(),
    })

  const createDocument = async (
    operations: NativeUploadOperations,
    requestContext: HandlerContext,
    body: Uint8Array,
    seed: number,
  ) => await operations.create({
    clientUploadId: new Uint8Array(16).fill(seed), fileName: "fast.bin",
    mimeType: "application/octet-stream", byteCount: BigInt(body.length),
    sha256: createHash("sha256").update(body).digest(), kind: UploadKind.DOCUMENT,
    metadata: { oneofKind: undefined },
  }, requestContext)

  test("fast acknowledgement replies before the staging write and finish waits for it", async () => {
    const user = await testUtils.createUser("native-upload-fast-ack@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const store = new MemoryPartStore()
    let release!: () => void
    const writing = new Promise<void>((resolve) => { release = resolve })
    store.afterPut = () => writing
    const operations = fastOperations(store)
    const requestContext = context(user.id, account.session.id)
    const body = new Uint8Array(INLINE_TRANSFER_PART_SIZE + 10).fill(9)
    const created = await createDocument(operations, requestContext, body, 120)
    expect(created.pieceGranularity).toBe(UPLOAD_PIECE_GRANULARITY)

    const first = await Promise.race([
      operations.savePart({ uploadId: created.uploadId, partIndex: 0, data: body.subarray(0, INLINE_TRANSFER_PART_SIZE) }, requestContext),
      Bun.sleep(2_000).then(() => "blocked" as const),
    ])
    expect(first).toEqual({ alreadyPresent: false })
    expect(await operations.savePart({ uploadId: created.uploadId, partIndex: 1, data: body.subarray(INLINE_TRANSFER_PART_SIZE) }, requestContext))
      .toEqual({ alreadyPresent: false })
    // Held parts count as accepted for resume; the manifest has none yet.
    expect((await operations.state({ uploadId: created.uploadId }, requestContext)).acceptedParts).toEqual([0, 1])

    const finish = operations.finish({ uploadId: created.uploadId }, requestContext)
    const early = await Promise.race([finish.then(() => "finished" as const), Bun.sleep(50).then(() => "waiting" as const)])
    expect(early).toBe("waiting")
    release()
    expect(await finish).toEqual({ state: { oneofKind: "processing", processing: { retryAfterSeconds: 1 } } })
    expect(store.objects.size).toBe(2)
  })

  test("a part sent in pieces is accepted once its last byte arrives", async () => {
    const user = await testUtils.createUser("native-upload-pieces@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const store = new MemoryPartStore()
    const operations = fastOperations(store)
    const requestContext = context(user.id, account.session.id)
    const body = Uint8Array.from({ length: INLINE_TRANSFER_PART_SIZE + 3 * UPLOAD_PIECE_GRANULARITY + 5 }, (_, index) => index % 251)
    const created = await createDocument(operations, requestContext, body, 121)
    const G = UPLOAD_PIECE_GRANULARITY
    const piece = (partIndex: number, offset: number, length: number) => operations.savePart({
      uploadId: created.uploadId,
      partIndex,
      offset,
      data: body.subarray(partIndex * INLINE_TRANSFER_PART_SIZE + offset, partIndex * INLINE_TRANSFER_PART_SIZE + offset + length),
    }, requestContext)

    // Part 0: 16 KiB, 16 KiB, 32 KiB, then the rest, out of order and with a resend.
    expect(await piece(0, G, G)).toEqual({ alreadyPresent: false })
    expect(await piece(0, 0, G)).toEqual({ alreadyPresent: false })
    expect(await piece(0, 4 * G, INLINE_TRANSFER_PART_SIZE - 4 * G)).toEqual({ alreadyPresent: false })
    expect(await piece(0, G, G)).toEqual({ alreadyPresent: false })
    expect((await operations.state({ uploadId: created.uploadId }, requestContext)).acceptedParts).toEqual([])
    expect(await piece(0, 2 * G, 2 * G)).toEqual({ alreadyPresent: false })
    // Part 1 (the short tail) in two pieces; the last piece may be any length.
    expect(await piece(1, 0, 2 * G)).toEqual({ alreadyPresent: false })
    expect(await piece(1, 2 * G, G + 5)).toEqual({ alreadyPresent: false })

    expect(await operations.finish({ uploadId: created.uploadId }, requestContext))
      .toEqual({ state: { oneofKind: "processing", processing: { retryAfterSeconds: 1 } } })
    const stored = [...store.objects.entries()].sort(([left], [right]) => left.localeCompare(right)).map(([, bytes]) => bytes)
    expect(Buffer.concat(stored)).toEqual(Buffer.from(body))
  })

  test("rejects misaligned or oversized pieces, and pieces where the server takes whole parts", async () => {
    const user = await testUtils.createUser("native-upload-bad-pieces@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const requestContext = context(user.id, account.session.id)
    const body = new Uint8Array(3 * UPLOAD_PIECE_GRANULARITY).fill(1)
    const operations = fastOperations(new MemoryPartStore())
    const created = await createDocument(operations, requestContext, body, 122)
    const G = UPLOAD_PIECE_GRANULARITY
    for (const [offset, length] of [[1, G], [0, G - 1], [2 * G, 2 * G], [3 * G, 1]] as const) {
      await expect(operations.savePart({
        uploadId: created.uploadId, partIndex: 0, offset, data: new Uint8Array(length),
      }, requestContext)).rejects.toMatchObject({ codeNumber: 400 })
    }
    const wholeParts = new NativeUploadOperations(new InlineUploadRepository(), new MemoryPartStore(), finalizer)
    const plain = await createDocument(wholeParts, requestContext, body, 123)
    expect(plain.pieceGranularity).toBeUndefined()
    await expect(wholeParts.savePart({
      uploadId: plain.uploadId, partIndex: 0, offset: 0, data: body.subarray(0, G),
    }, requestContext)).rejects.toMatchObject({ codeNumber: 400 })
  })

  test("a write that fails behind its acknowledgement is missing at finish and accepted when resent", async () => {
    const user = await testUtils.createUser("native-upload-fast-ack-lost@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    class FlakyStore extends MemoryPartStore {
      failures = 1
      override async put(input: Parameters<MemoryPartStore["put"]>[0]): Promise<string> {
        if (this.failures > 0) {
          this.failures -= 1
          throw new Error("storage write failed")
        }
        return await super.put(input)
      }
    }
    const store = new FlakyStore()
    const operations = fastOperations(store)
    const requestContext = context(user.id, account.session.id)
    const body = new TextEncoder().encode("lost behind the reply")
    const created = await createDocument(operations, requestContext, body, 124)
    expect(await operations.savePart({ uploadId: created.uploadId, partIndex: 0, data: body }, requestContext))
      .toEqual({ alreadyPresent: false })
    expect(await operations.finish({ uploadId: created.uploadId }, requestContext))
      .toEqual({ state: { oneofKind: "missing", missing: { partIndices: [0] } } })
    expect(await operations.savePart({ uploadId: created.uploadId, partIndex: 0, data: body }, requestContext))
      .toEqual({ alreadyPresent: false })
    expect(await operations.finish({ uploadId: created.uploadId }, requestContext))
      .toEqual({ state: { oneofKind: "processing", processing: { retryAfterSeconds: 1 } } })
  })

  test("a storage outage behind an acknowledgement turns the next parts into retryable 503s", async () => {
    const user = await testUtils.createUser("native-upload-fast-ack-outage@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    class UnavailableStore extends MemoryPartStore {
      override async put(): Promise<string> {
        throw new UploadPartStorageUnavailableError()
      }
    }
    const intake = new UploadPartIntake({
      isStorageOutage: (error) => (error as { codeNumber?: number }).codeNumber === 503,
    })
    const operations = fastOperations(new UnavailableStore(), { intake })
    const requestContext = context(user.id, account.session.id)
    const part = new Uint8Array(INLINE_TRANSFER_PART_SIZE).fill(2)
    const created = await createDocument(operations, requestContext, new Uint8Array([...part, ...part]), 125)
    expect(await operations.savePart({ uploadId: created.uploadId, partIndex: 0, data: part }, requestContext))
      .toEqual({ alreadyPresent: false })
    await intake.drain(1_000)
    await expect(operations.savePart({ uploadId: created.uploadId, partIndex: 1, data: part }, requestContext))
      .rejects.toMatchObject({ codeNumber: 503, retryAfterSeconds: 5 })
  })

  test("inline data still finishes in create with fast acknowledgement", async () => {
    const user = await testUtils.createUser("native-upload-fast-ack-inline@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const store = new MemoryPartStore()
    const operations = fastOperations(store)
    const requestContext = context(user.id, account.session.id)
    const body = new TextEncoder().encode("one call")
    const created = await operations.create({
      clientUploadId: new Uint8Array(16).fill(126), fileName: "inline.bin",
      mimeType: "application/octet-stream", byteCount: BigInt(body.length),
      sha256: createHash("sha256").update(body).digest(), kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined }, inlineData: body,
    }, requestContext)
    // No finishInline here, so the upload is queued for the worker with part 0 stored.
    expect(created.acceptedParts).toEqual([0])
    expect(store.objects.size).toBe(1)
  })
})
