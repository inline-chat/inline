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
  inlineUploadFileUniqueId,
  inlineUploadPublicationPath,
} from "@in/server/db/models/inlineUploads"
import { inlineUploads, sessions } from "@in/server/db/schema"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { makeAuthorizationKeyCipher } from "@in/server/modules/inlineProtocol/keyCipher"
import type { HandlerContext } from "@in/server/realtime/types"
import { UploadIntegrityError, type MediaUploadFinalizer } from "./finalizer"
import { MEDIA_UPLOAD_MAX_BYTES } from "@in/server/modules/files/metadata"
import { NativeUploadOperations } from "./operations"
import type { UploadPartStore } from "./partStore"

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
  async discardPublication() {},
  async project(_kind, fileUniqueId) {
    return complete(fileUniqueId)
  },
}

describe("native upload operations", () => {
  setupTestLifecycle()

  test("reconciles an accepted part after a lost manifest commit response", async () => {
    class Repository extends InlineUploadRepository {
      override async acceptPart(
        input: Parameters<InlineUploadRepository["acceptPart"]>[0],
      ): ReturnType<InlineUploadRepository["acceptPart"]> {
        await super.acceptPart(input)
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
      override async acceptPart(input: Parameters<InlineUploadRepository["acceptPart"]>[0]) {
        if (this.failAcceptance) throw new Error("database unavailable")
        return super.acceptPart(input)
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

  test("does not report terminal failure after another finalizer takes the fence", async () => {
    const user = await testUtils.createUser("native-upload-stolen-fence@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    class Repository extends InlineUploadRepository {
      override async fail(input: Parameters<InlineUploadRepository["fail"]>[0]) {
        await db.update(inlineUploads).set({ lockToken: Buffer.alloc(16, 77) }).where(eq(inlineUploads.id, input.uploadDbId))
        return super.fail(input)
      }
    }
    const operations = new NativeUploadOperations(new Repository(), new MemoryPartStore(), {
      ...finalizer, async preparePublication() { throw new UploadIntegrityError() },
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
  })

  test("bounds a hung lease renewal and releases the finalizer request", async () => {
    class Repository extends InlineUploadRepository {
      override async renew(): Promise<boolean> {
        return new Promise(() => {})
      }
    }
    const user = await testUtils.createUser("native-upload-hung-renewal@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const store = new MemoryPartStore()
    const operations = new NativeUploadOperations(new Repository(), store, finalizer, 10)
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
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error("lease renewal pinned finish")), 250)),
    ])
    expect(result.state.oneofKind).toBe("processing")
  })

  test("runs create, durable save, reconciliation, finish, and cached finish", async () => {
    const user = await testUtils.createUser("native-upload-operations@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const permanentKey = new Uint8Array(256).fill(0x51)
    const permanentKeyId = authKeyId(permanentKey)
    const keys = authorizationKeys()
    await keys.create({ key: permanentKey, keyId: permanentKeyId, serverSalt: 1n, temporary: false })
    await keys.authorize(permanentKeyId, user.id, account.session.id)

    const store = new MemoryPartStore()
    const operations = new NativeUploadOperations(
      new InlineUploadRepository(),
      store,
      finalizer,
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

    const expectedComplete = complete(inlineUploadFileUniqueId({
      uploadId: create.uploadId,
      kind: "document",
    }))
    expect(await operations.finish({ uploadId: create.uploadId }, requestContext))
      .toEqual({ state: { oneofKind: "complete", complete: expectedComplete } })
    expect(store.objects.size).toBe(0)
    expect(await operations.finish({ uploadId: create.uploadId }, requestContext))
      .toEqual({ state: { oneofKind: "complete", complete: expectedComplete } })
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
          oneofKind: "complete",
          complete: complete(inlineUploadFileUniqueId({
            uploadId: create.uploadId,
            kind: "document",
          })),
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
      expect(await repository.cancel(create.uploadId, owner)).toEqual({
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
})
