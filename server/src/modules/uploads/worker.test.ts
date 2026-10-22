import { createHash } from "node:crypto"
import { afterEach, describe, expect, setDefaultTimeout, test } from "bun:test"
import { eq } from "drizzle-orm"
import { UploadKind, type UploadComplete } from "@inline-chat/protocol/core"
import { INLINE_TRANSFER_PART_SIZE } from "@inline-chat/protocol/transfers"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import {
  InlineUploadRepository,
  inlineUploadPublicationPath,
  type InlineUploadPublication,
  type InlineUploadRecord,
} from "@in/server/db/models/inlineUploads"
import { filePartHashes, files, inlineUploads } from "@in/server/db/schema"
import { encrypt } from "@in/server/modules/encryption/encryption"
import type { HandlerContext } from "@in/server/realtime/types"
import { ApiError, InlineError } from "@in/server/types/errors"
import type { MediaUploadFinalizer } from "./finalizer"
import {
  MultipartStorageUnavailableError,
  MultipartUploadNotFoundError,
  multipartEtag,
  type MultipartObjectHead,
  type MultipartObjectStore,
  type MultipartUploadedPart,
} from "./multipartStore"
import { NativeUploadOperations } from "./operations"
import type { UploadPartStore } from "./partStore"
import { NativeUploadWorker, storagePartGeometry } from "./worker"
import { UploadGroupBuffer } from "./groupBuffer"

setDefaultTimeout(120_000)

// Always stop test-owned workers, including when an assertion or wait fails.
// Otherwise their background DB work races the next test's TRUNCATE.
const activeWorkers = new Set<NativeUploadWorker>()
const createWorker = (...args: ConstructorParameters<typeof NativeUploadWorker>) => {
  const worker = new NativeUploadWorker(...args)
  activeWorkers.add(worker)
  return worker
}
afterEach(async () => {
  const stopped = await Promise.allSettled([...activeWorkers].map((worker) => worker.stop()))
  activeWorkers.clear()
  const failures = stopped.filter((result) => result.status === "rejected")
  if (failures.length) throw new AggregateError(failures.map((result) => result.reason), "Test upload workers failed to stop")
})


const context = (userId: number, sessionId: number): HandlerContext => ({
  userId,
  sessionId,
  connectionId: "native-upload-worker-test",
  sendRaw: () => {},
  sendRpcReply: () => {},
})

class MemoryPartStore implements UploadPartStore {
  readonly objects = new Map<string, Uint8Array>()

  async put(input: {
    uploadId: Uint8Array
    partIndex: number
    sha256: Uint8Array
    data: Uint8Array
  }): Promise<string> {
    const key = `${Buffer.from(input.uploadId).toString("hex")}/${input.partIndex}`
    this.objects.set(key, input.data.slice())
    return key
  }

  reads = 0
  removes = 0
  async read(key: string): Promise<Uint8Array> {
    this.reads += 1
    const bytes = this.objects.get(key)
    if (!bytes) throw new Error(`Missing staging object ${key}`)
    return bytes.slice()
  }

  async remove(key: string): Promise<void> {
    this.removes += 1
    this.objects.delete(key)
  }
}

class BatchingPartStore extends MemoryPartStore {
  batchRemoves = 0
  async removeMany(keys: readonly string[]): Promise<void> {
    this.batchRemoves += 1
    for (const key of keys) this.objects.delete(key)
  }
}

class MemoryMultipartStore implements MultipartObjectStore {
  readonly sessions = new Map<string, { key: string; parts: Map<number, Uint8Array> }>()
  readonly objects = new Map<string, { bytes: Uint8Array; etag: string }>()
  readonly uploadedByteCounts: number[] = []
  readonly uploadPartCounts = new Map<number, number>()
  createCount = 0
  completeCount = 0
  uploadDelayMs = 0
  loseCompleteResponseOnce = false
  expireFirstPartSessionOnce = false
  invalidateCompleteOnce = false

  async create(key: string): Promise<string> {
    const uploadId = `session-${++this.createCount}`
    this.sessions.set(uploadId, { key, parts: new Map() })
    return uploadId
  }

  async uploadPart(input: {
    key: string
    uploadId: string
    partNumber: number
    bytes: Uint8Array
  }): Promise<MultipartUploadedPart> {
    this.uploadPartCounts.set(
      input.partNumber,
      (this.uploadPartCounts.get(input.partNumber) ?? 0) + 1,
    )
    if (this.uploadDelayMs > 0) await Bun.sleep(this.uploadDelayMs)
    if (this.expireFirstPartSessionOnce) {
      this.expireFirstPartSessionOnce = false
      this.sessions.delete(input.uploadId)
      throw new MultipartUploadNotFoundError()
    }
    const session = this.sessions.get(input.uploadId)
    if (!session || session.key !== input.key) throw new MultipartUploadNotFoundError()
    session.parts.set(input.partNumber, input.bytes.slice())
    this.uploadedByteCounts.push(input.bytes.byteLength)
    return {
      partNumber: input.partNumber,
      etag: createHash("md5").update(input.bytes).digest("hex"),
    }
  }

  async complete(input: {
    key: string
    uploadId: string
    parts: MultipartUploadedPart[]
  }): Promise<{ etag: string }> {
    const session = this.sessions.get(input.uploadId)
    if (!session || session.key !== input.key) throw new MultipartUploadNotFoundError()
    if (this.invalidateCompleteOnce) {
      this.invalidateCompleteOnce = false
      throw new MultipartUploadNotFoundError()
    }
    const bytes = Buffer.concat(input.parts.map(({ partNumber }) => {
      const part = session.parts.get(partNumber)
      if (!part) throw new Error(`Missing multipart part ${partNumber}`)
      return Buffer.from(part)
    }))
    const etag = multipartEtag(input.parts)
    this.objects.set(input.key, { bytes, etag })
    this.sessions.delete(input.uploadId)
    this.completeCount += 1
    if (this.loseCompleteResponseOnce) {
      this.loseCompleteResponseOnce = false
      throw new MultipartStorageUnavailableError()
    }
    return { etag }
  }

  async abort(_key: string, uploadId: string): Promise<void> {
    this.sessions.delete(uploadId)
  }

  async head(key: string): Promise<MultipartObjectHead | undefined> {
    const object = this.objects.get(key)
    return object ? { byteCount: object.bytes.byteLength, etag: object.etag } : undefined
  }

  streams = 0
  async stream(key: string): Promise<ReadableStream<Uint8Array>> {
    this.streams += 1
    const object = this.objects.get(key)
    if (!object) throw new Error(`Missing completed object ${key}`)
    return new Blob([Uint8Array.from(object.bytes)]).stream()
  }

  async remove(key: string): Promise<void> {
    this.objects.delete(key)
  }
}

class LostInstallResponseRepository extends InlineUploadRepository {
  #loseResponse = true

  override async installStorageSession(
    input: Parameters<InlineUploadRepository["installStorageSession"]>[0],
  ): Promise<Awaited<ReturnType<InlineUploadRepository["installStorageSession"]>>> {
    const result = await super.installStorageSession(input)
    if (this.#loseResponse && result.installed) {
      this.#loseResponse = false
      throw new Error("lost storage-session commit response")
    }
    return result
  }
}

class HangingRenewRepository extends InlineUploadRepository {
  renewCalls = 0
  renewSignal: AbortSignal | undefined

  override async renew(
    _input: Parameters<InlineUploadRepository["renew"]>[0],
    signal?: AbortSignal,
  ): Promise<boolean> {
    this.renewCalls += 1
    this.renewSignal = signal
    return new Promise<boolean>((_, reject) => {
      const onAbort = () => reject(signal?.reason)
      signal?.addEventListener("abort", onAbort, { once: true })
      if (signal?.aborted) onAbort()
    })
  }
}

class HangingCleanupRepository extends InlineUploadRepository {
  listExpiredCalls = 0

  override async listExpired(): Promise<Array<{ id: number }>> {
    this.listExpiredCalls += 1
    return await new Promise<Array<{ id: number }>>(() => {})
  }
}

const publicationFor = (upload: InlineUploadRecord): InlineUploadPublication => {
  if (!upload.resultFileUniqueId) throw new Error("Missing publication identity")
  const path = inlineUploadPublicationPath(upload.resultFileUniqueId)
  const encryptedPath = encrypt(path)
  const encryptedName = encrypt(upload.fileName)
  const encryptedDocumentName = encrypt(upload.fileName)
  return {
    file: {
      record: {
        fileUniqueId: upload.resultFileUniqueId,
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
}

const makeFinalizer = (expected: Uint8Array, onStored?: () => void): MediaUploadFinalizer => ({
  async preparePublication() { throw new Error("Legacy path was not expected") },
  async prepareStoredPublication({ upload, stream, assertOwnership }) {
    const bytes = new Uint8Array(await new Response(stream).arrayBuffer())
    expect(Buffer.from(bytes).equals(Buffer.from(expected))).toBe(true)
    expect(createHash("sha256").update(bytes).digest("hex"))
      .toBe(Buffer.from(upload.sha256).toString("hex"))
    await assertOwnership()
    onStored?.()
    return publicationFor(upload)
  },
  async prepareBufferedPublication({ upload, frames, assertOwnership }) {
    if (frames) expect(Buffer.concat(frames.map((frame) => Buffer.from(frame))).equals(Buffer.from(expected))).toBe(true)
    await assertOwnership()
    onStored?.()
    return publicationFor(upload)
  },
  async discardPublication() {},
  async project(_kind, fileUniqueId): Promise<UploadComplete> {
    return { fileUniqueId, media: { oneofKind: undefined } }
  },
})

const waitFor = async (condition: () => boolean | Promise<boolean>, timeoutMs = 15_000): Promise<void> => {
  const deadline = Date.now() + timeoutMs
  while (!await condition()) {
    if (Date.now() >= deadline) throw new Error("Timed out waiting for upload worker")
    await Bun.sleep(20)
  }
}

const saveBody = async (
  operations: NativeUploadOperations,
  requestContext: HandlerContext,
  body: Uint8Array,
  clientByte: number,
) => {
  const created = await operations.create({
    clientUploadId: new Uint8Array(16).fill(clientByte),
    fileName: `worker-${clientByte}.bin`,
    mimeType: "application/octet-stream",
    byteCount: BigInt(body.byteLength),
    sha256: createHash("sha256").update(body).digest(),
    kind: UploadKind.DOCUMENT,
    metadata: { oneofKind: undefined },
  }, requestContext)
  for (let partIndex = 0; partIndex < created.partCount; partIndex += 1) {
    const offset = partIndex * created.partSize
    await operations.savePart({
      uploadId: created.uploadId,
      partIndex,
      data: body.subarray(offset, Math.min(offset + created.partSize, body.byteLength)),
    }, requestContext)
  }
  return created
}

describe("native upload multipart worker", () => {
  setupTestLifecycle()

  test.each([[true, false], [false, false], [true, true]] as const)("processing cancellation fences late publication and cleans a provider that settles late (local abort %s, stop %s)", async (localAbort, stopDuringCancel) => {
    const user = await testUtils.createUser(`native-upload-worker-cancel-${localAbort}-${stopDuringCancel}@example.test`)
    const account = await testUtils.createSessionForUser(user.id)
    const caller = context(user.id, account.session.id)
    const owner = { userId: user.id, accountSessionId: account.session.id }
    const repository = new InlineUploadRepository()
    const staging = new MemoryPartStore()
    const multipart = new MemoryMultipartStore()
    const body = new Uint8Array([91, 92])
    let enteredResolve!: () => void
    const entered = new Promise<void>((resolve) => { enteredResolve = resolve })
    let release!: () => void
    const blocked = new Promise<void>((resolve) => { release = resolve })
    let activeSignal: AbortSignal | undefined
    let finalizerSettled = false
    const lateWrite = async ({ upload, signal, stream }: {
      upload: InlineUploadRecord
      signal?: AbortSignal
      stream?: ReadableStream<Uint8Array>
    }) => {
      activeSignal = signal
      if (stream) await new Response(stream).arrayBuffer()
      enteredResolve()
      // Model a provider write that ignores cancellation until settlement.
      await blocked
      const key = `files/${inlineUploadPublicationPath(upload.resultFileUniqueId!)}`
      multipart.objects.set(key, { bytes: body, etag: "late-write" })
      finalizerSettled = true
      return publicationFor(upload)
    }
    const finalizer: MediaUploadFinalizer = {
      ...makeFinalizer(body),
      prepareStoredPublication: lateWrite,
      prepareBufferedPublication: lateWrite,
      async discardPublication(upload) {
        await multipart.remove(`files/${inlineUploadPublicationPath(upload.resultFileUniqueId!)}`)
      },
    }
    const worker = createWorker(repository, staging, multipart, finalizer, { concurrency: 1, pollIntervalMs: 20 })
    const operations = new NativeUploadOperations(repository, staging, finalizer,
      (id) => worker.wake(id), (upload) => worker.discardStorage(upload),
      localAbort ? (id) => worker.cancel(id) : () => {})
    const created = await saveBody(operations, caller, body, localAbort ? 90 : 91)
    await operations.finish({ uploadId: created.uploadId }, caller)
    worker.start()
    try {
      await entered
      expect((await operations.cancel({ uploadId: created.uploadId }, caller)).canceled).toBe(true)
      expect(activeSignal?.aborted).toBe(localAbort)
      expect(await repository.activeReservedBytes(owner)).toBe(0n)
      const stopping = stopDuringCancel ? worker.stop() : undefined
      release()
      await waitFor(() => finalizerSettled && multipart.objects.size === 0)
      await worker.stop()
      await stopping
      const stored = await repository.get(created.uploadId, owner)
      expect(stored?.status).toBe("canceled")
      expect(stored?.resultMediaId).toBeNull()
      expect(await db.select().from(files).where(eq(files.fileUniqueId, stored!.resultFileUniqueId!))).toHaveLength(0)
      expect(staging.objects.size).toBe(0)
      expect(multipart.sessions.size).toBe(0)
      expect(multipart.objects.size).toBe(0)
    } finally { release() }
  })

  test("keeps 5 MiB provider geometry with only a short final tail", () => {
    expect(storagePartGeometry(1)).toEqual([{ partNumber: 1, firstFrameIndex: 0, frameCount: 1 }])
    expect(storagePartGeometry(10)).toEqual([{ partNumber: 1, firstFrameIndex: 0, frameCount: 10 }])
    expect(storagePartGeometry(11)).toEqual([
      { partNumber: 1, firstFrameIndex: 0, frameCount: 10 },
      { partNumber: 2, firstFrameIndex: 10, frameCount: 1 },
    ])
    const large = storagePartGeometry(391)
    expect(large).toHaveLength(40)
    expect(large.slice(0, -1).every(({ frameCount }) => frameCount === 10)).toBe(true)
    expect(large.at(-1)?.frameCount).toBe(1)
    expect(() => storagePartGeometry(0)).toThrow(RangeError)
  })

  test("coalesces repeated wakes while opportunistically compacting one upload", async () => {
    const user = await testUtils.createUser("native-upload-worker-coalesce@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const requestContext = context(user.id, account.session.id)
    const repository = new InlineUploadRepository()
    const staging = new MemoryPartStore()
    const multipart = new MemoryMultipartStore()
    multipart.uploadDelayMs = 500
    const body = new Uint8Array(INLINE_TRANSFER_PART_SIZE * 20).fill(19)
    const finalizer = makeFinalizer(body)
    const worker = createWorker(repository, staging, multipart, finalizer, {
      concurrency: 4,
      pollIntervalMs: 5_000,
    })
    const operations = new NativeUploadOperations(
      repository,
      staging,
      finalizer,
      (uploadDbId, groupNumber) => worker.wake(uploadDbId, groupNumber),
    )
    worker.start()
    const created = await saveBody(operations, requestContext, body, 79)
    const upload = await repository.get(created.uploadId, {
      userId: user.id,
      accountSessionId: account.session.id,
    })
    if (!upload) throw new Error("Expected an upload row")
    await waitFor(async () =>
      (await repository.getStorageWork(upload.id))?.storageParts.length === 2)
    await worker.stop()

    expect(multipart.uploadPartCounts).toEqual(new Map([[1, 1], [2, 1]]))
  })

  test("serializes opportunistic provider writes across worker processes and finish", async () => {
    const user = await testUtils.createUser("native-upload-worker-cross-process-compaction@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const requestContext = context(user.id, account.session.id)
    const owner = { userId: user.id, accountSessionId: account.session.id }
    const repository = new InlineUploadRepository()
    const staging = new MemoryPartStore()
    const multipart = new MemoryMultipartStore()
    multipart.uploadDelayMs = 250
    const body = new Uint8Array(INLINE_TRANSFER_PART_SIZE * 20).fill(23)
    const finalizer = makeFinalizer(body)
    const operations = new NativeUploadOperations(repository, staging, finalizer)
    const created = await saveBody(operations, requestContext, body, 82)
    const upload = await repository.get(created.uploadId, owner)
    if (!upload) throw new Error("Expected an upload row")

    const first = createWorker(repository, staging, multipart, finalizer, {
      concurrency: 2,
      pollIntervalMs: 20,
    })
    const second = createWorker(repository, staging, multipart, finalizer, {
      concurrency: 2,
      pollIntervalMs: 20,
    })
    first.start()
    second.start()
    first.wake(upload.id)
    second.wake(upload.id)
    await waitFor(() => multipart.uploadPartCounts.size > 0)
    await operations.finish({ uploadId: created.uploadId }, requestContext)
    await waitFor(async () => (await repository.get(created.uploadId, owner))?.status === "complete")
    await Promise.all([first.stop(), second.stop()])

    expect(multipart.uploadPartCounts).toEqual(new Map([[1, 1], [2, 1]]))
    expect(multipart.completeCount).toBe(1)
  })

  test("does not start a new worker generation while the prior stop is draining", async () => {
    const worker = createWorker(
      new InlineUploadRepository(),
      new MemoryPartStore(),
      new MemoryMultipartStore(),
      makeFinalizer(new Uint8Array()),
      { pollIntervalMs: 5_000 },
    )
    worker.start()
    const stopping = worker.stop()
    expect(() => worker.start()).toThrow("Native upload worker is still draining")
    await Promise.all([stopping, worker.stop()])

    worker.start()
    await worker.stop()
  })

  test("bounds shutdown when expiry discovery is stalled and blocks a new generation", async () => {
    const repository = new HangingCleanupRepository()
    const worker = createWorker(
      repository,
      new MemoryPartStore(),
      new MemoryMultipartStore(),
      makeFinalizer(new Uint8Array()),
      { pollIntervalMs: 5_000, shutdownDrainTimeoutMs: 10 },
    )
    worker.start()
    await waitFor(() => repository.listExpiredCalls === 1)

    const startedAt = performance.now()
    await worker.stop()

    expect(performance.now() - startedAt).toBeLessThan(500)
    expect(() => worker.start()).toThrow("Native upload worker is still draining")
  })

  test("recovers a lost Complete response in a fresh worker without reuploading", async () => {
    const user = await testUtils.createUser("native-upload-worker-restart@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const requestContext = context(user.id, account.session.id)
    const repository = new InlineUploadRepository()
    const staging = new MemoryPartStore()
    const multipart = new MemoryMultipartStore()
    multipart.loseCompleteResponseOnce = true
    const body = new Uint8Array(INLINE_TRANSFER_PART_SIZE * 53)
    for (let index = 0; index < body.length; index += INLINE_TRANSFER_PART_SIZE) {
      body.fill((index / INLINE_TRANSFER_PART_SIZE) % 251, index, index + INLINE_TRANSFER_PART_SIZE)
    }
    const finalizer = makeFinalizer(body)
    const operations = new NativeUploadOperations(repository, staging, finalizer)
    const created = await saveBody(operations, requestContext, body, 71)
    const finishStartedAt = performance.now()
    expect((await operations.finish({ uploadId: created.uploadId }, requestContext)).state.oneofKind)
      .toBe("processing")
    expect(performance.now() - finishStartedAt).toBeLessThan(250)

    const firstWorker = createWorker(repository, staging, multipart, finalizer, {
      concurrency: 2, pollIntervalMs: 5_000, random: () => 1,
    })
    firstWorker.start()
    await waitFor(async () => {
      const row = await repository.get(created.uploadId, {
        userId: user.id, accountSessionId: account.session.id,
      })
      return multipart.objects.size === 1 && row?.status === "processing" && row.attempts === 1
    })
    await firstWorker.stop()

    const secondWorker = createWorker(repository, staging, multipart, finalizer, {
      concurrency: 2, pollIntervalMs: 20, random: () => 0,
    })
    secondWorker.start()
    await waitFor(async () => (await repository.get(created.uploadId, {
      userId: user.id, accountSessionId: account.session.id,
    }))?.status === "complete")
    await secondWorker.stop()

    expect(multipart.createCount).toBe(1)
    expect(multipart.completeCount).toBe(1)
    expect(multipart.uploadedByteCounts).toEqual([
      ...Array.from({ length: 5 }, () => 5 * 1_024 * 1_024),
      3 * INLINE_TRANSFER_PART_SIZE,
    ])
    await waitFor(() => staging.objects.size === 0)
  })

  test("rebuilds an expired provider session and admits only one competing worker", async () => {
    const user = await testUtils.createUser("native-upload-worker-lease@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const requestContext = context(user.id, account.session.id)
    const repository = new InlineUploadRepository()
    const staging = new MemoryPartStore()
    const multipart = new MemoryMultipartStore()
    multipart.expireFirstPartSessionOnce = true
    const body = new Uint8Array(INLINE_TRANSFER_PART_SIZE + 17).fill(42)
    let publications = 0
    const finalizer = makeFinalizer(body, () => { publications += 1 })
    const operations = new NativeUploadOperations(repository, staging, finalizer)
    const created = await saveBody(operations, requestContext, body, 72)
    await operations.finish({ uploadId: created.uploadId }, requestContext)

    const first = createWorker(repository, staging, multipart, finalizer, {
      concurrency: 1, pollIntervalMs: 20,
    })
    const second = createWorker(repository, staging, multipart, finalizer, {
      concurrency: 1, pollIntervalMs: 20,
    })
    first.start()
    second.start()
    await waitFor(async () => (await repository.get(created.uploadId, {
      userId: user.id, accountSessionId: account.session.id,
    }))?.status === "complete")
    await Promise.all([first.stop(), second.stop()])

    expect(multipart.createCount).toBe(2)
    expect(multipart.completeCount).toBe(1)
    expect(publications).toBe(1)
  })

  test("rebuilds a provider session rejected at Complete without leaking the stale session", async () => {
    const user = await testUtils.createUser("native-upload-worker-invalid-part@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const requestContext = context(user.id, account.session.id)
    const owner = { userId: user.id, accountSessionId: account.session.id }
    const repository = new InlineUploadRepository()
    const staging = new MemoryPartStore()
    const multipart = new MemoryMultipartStore()
    multipart.invalidateCompleteOnce = true
    const body = new Uint8Array(INLINE_TRANSFER_PART_SIZE + 7).fill(44)
    const finalizer = makeFinalizer(body)
    const operations = new NativeUploadOperations(repository, staging, finalizer)
    const created = await saveBody(operations, requestContext, body, 76)
    await operations.finish({ uploadId: created.uploadId }, requestContext)

    const worker = createWorker(repository, staging, multipart, finalizer, {
      concurrency: 1, pollIntervalMs: 20,
    })
    worker.start()
    await waitFor(async () => (await repository.get(created.uploadId, owner))?.status === "complete")
    await worker.stop()

    expect(multipart.createCount).toBe(2)
    expect(multipart.completeCount).toBe(1)
    expect(multipart.sessions.size).toBe(0)
  })

  test("reconciles a lost storage-session commit response without creating an orphan", async () => {
    const user = await testUtils.createUser("native-upload-worker-install-reconcile@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const requestContext = context(user.id, account.session.id)
    const owner = { userId: user.id, accountSessionId: account.session.id }
    const repository = new LostInstallResponseRepository()
    const staging = new MemoryPartStore()
    const multipart = new MemoryMultipartStore()
    const body = new Uint8Array([8, 6, 7, 5, 3, 0, 9])
    const finalizer = makeFinalizer(body)
    const operations = new NativeUploadOperations(repository, staging, finalizer)
    const created = await saveBody(operations, requestContext, body, 77)
    await operations.finish({ uploadId: created.uploadId }, requestContext)

    const worker = createWorker(repository, staging, multipart, finalizer, {
      concurrency: 1, pollIntervalMs: 20,
    })
    worker.start()
    await waitFor(async () => (await repository.get(created.uploadId, owner))?.status === "complete")
    await worker.stop()

    expect(multipart.createCount).toBe(1)
    expect(multipart.completeCount).toBe(1)
    expect(multipart.sessions.size).toBe(0)
  })

  test("graceful stop releases an active processing lease for the next process", async () => {
    const user = await testUtils.createUser("native-upload-worker-shutdown@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const requestContext = context(user.id, account.session.id)
    const owner = { userId: user.id, accountSessionId: account.session.id }
    const repository = new InlineUploadRepository()
    const staging = new MemoryPartStore()
    const multipart = new MemoryMultipartStore()
    const body = new Uint8Array([91])
    let enteredResolve!: () => void
    const entered = new Promise<void>((resolve) => { enteredResolve = resolve })
    const block = async ({ signal }: { signal?: AbortSignal }) => {
      enteredResolve()
      return new Promise<never>((_, reject) => {
        signal?.addEventListener("abort", () => reject(signal.reason), { once: true })
      })
    }
    const blockedFinalizer: MediaUploadFinalizer = {
      ...makeFinalizer(body),
      prepareStoredPublication: block,
      prepareBufferedPublication: block,
    }
    const operations = new NativeUploadOperations(repository, staging, blockedFinalizer)
    const created = await saveBody(operations, requestContext, body, 73)
    await operations.finish({ uploadId: created.uploadId }, requestContext)

    const first = createWorker(repository, staging, multipart, blockedFinalizer, {
      concurrency: 1, pollIntervalMs: 20,
    })
    first.start()
    await entered
    await first.stop()
    const released = await repository.get(created.uploadId, owner)
    expect(released?.status).toBe("processing")
    expect(released?.lockToken).toBeNull()
    expect(released?.lockedAt).toBeNull()

    const second = createWorker(repository, staging, multipart, makeFinalizer(body), {
      concurrency: 1, pollIntervalMs: 20,
    })
    second.start()
    await waitFor(async () => (await repository.get(created.uploadId, owner))?.status === "complete")
    await second.stop()
    expect(multipart.completeCount).toBe(1)
  })

  test("bounds a stalled lease renewal instead of pinning worker shutdown", async () => {
    const user = await testUtils.createUser("native-upload-worker-renew-timeout@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const requestContext = context(user.id, account.session.id)
    const owner = { userId: user.id, accountSessionId: account.session.id }
    const repository = new HangingRenewRepository()
    const staging = new MemoryPartStore()
    const multipart = new MemoryMultipartStore()
    const body = new Uint8Array([6, 2, 6])
    const finalizer = makeFinalizer(body)
    const operations = new NativeUploadOperations(repository, staging, finalizer)
    const created = await saveBody(operations, requestContext, body, 80)
    await operations.finish({ uploadId: created.uploadId }, requestContext)

    const worker = createWorker(repository, staging, multipart, finalizer, {
      concurrency: 1,
      leaseRenewTimeoutMs: 10,
      pollIntervalMs: 20,
    })
    worker.start()
    await waitFor(() => repository.renewCalls > 0)
    const stopStartedAt = performance.now()
    await worker.stop()

    expect(performance.now() - stopStartedAt).toBeLessThan(500)
    expect(repository.renewSignal?.aborted).toBe(true)
    expect((await repository.get(created.uploadId, owner))?.status).toBe("processing")
  })

  test("finalizes pre-migration null-format rows through the retained assembler", async () => {
    const user = await testUtils.createUser("native-upload-worker-legacy@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const requestContext = context(user.id, account.session.id)
    const owner = { userId: user.id, accountSessionId: account.session.id }
    const repository = new InlineUploadRepository()
    const staging = new MemoryPartStore()
    const multipart = new MemoryMultipartStore()
    const body = new Uint8Array([4, 3, 2, 1])
    const baseFinalizer = makeFinalizer(body)
    const legacyFinalizer: MediaUploadFinalizer = {
      ...baseFinalizer,
      async preparePublication({ upload, parts, assertOwnership }) {
        expect(parts).toHaveLength(1)
        expect(staging.objects.get(parts[0]!.objectKey)).toEqual(Uint8Array.from(body))
        await assertOwnership()
        return publicationFor(upload)
      },
    }
    const operations = new NativeUploadOperations(repository, staging, legacyFinalizer)
    const created = await saveBody(operations, requestContext, body, 74)
    await db.update(inlineUploads).set({ storageFormat: null })
      .where(eq(inlineUploads.uploadId, Buffer.from(created.uploadId)))
    await operations.finish({ uploadId: created.uploadId }, requestContext)

    const worker = createWorker(repository, staging, multipart, legacyFinalizer, {
      concurrency: 1, pollIntervalMs: 20,
    })
    worker.start()
    await waitFor(async () => (await repository.get(created.uploadId, owner))?.status === "complete")
    await worker.stop()
    expect(multipart.createCount).toBe(0)
  })

  test("fails permanent media validation once and removes durable staging", async () => {
    const user = await testUtils.createUser("native-upload-worker-invalid-media@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const requestContext = context(user.id, account.session.id)
    const owner = { userId: user.id, accountSessionId: account.session.id }
    const repository = new InlineUploadRepository()
    const staging = new MemoryPartStore()
    const multipart = new MemoryMultipartStore()
    const body = new Uint8Array([7, 7, 7])
    const reject = async (): Promise<never> => { throw new InlineError(ApiError.PHOTO_INVALID_TYPE) }
    const invalidFinalizer: MediaUploadFinalizer = {
      ...makeFinalizer(body),
      prepareStoredPublication: reject,
      prepareBufferedPublication: reject,
    }
    const operations = new NativeUploadOperations(repository, staging, invalidFinalizer)
    const created = await saveBody(operations, requestContext, body, 75)
    await operations.finish({ uploadId: created.uploadId }, requestContext)

    const worker = createWorker(repository, staging, multipart, invalidFinalizer, {
      concurrency: 1, pollIntervalMs: 20,
    })
    worker.start()
    await waitFor(async () => (await repository.get(created.uploadId, owner))?.status === "failed")
    await worker.stop()

    const failed = await repository.get(created.uploadId, owner)
    expect(failed?.failureCode).toBe("invalid_media")
    expect(failed?.attempts).toBe(0)
    expect(staging.objects.size).toBe(0)
    expect(multipart.objects.size).toBe(0)
  })

  test("aborts the current provider session after terminal staging corruption", async () => {
    const user = await testUtils.createUser("native-upload-worker-terminal-session-cleanup@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const requestContext = context(user.id, account.session.id)
    const owner = { userId: user.id, accountSessionId: account.session.id }
    const repository = new InlineUploadRepository()
    const staging = new MemoryPartStore()
    const multipart = new MemoryMultipartStore()
    const body = new Uint8Array([4, 2, 4, 2])
    const finalizer = makeFinalizer(body)
    const operations = new NativeUploadOperations(repository, staging, finalizer)
    const created = await saveBody(operations, requestContext, body, 81)
    for (const [key, value] of staging.objects) {
      staging.objects.set(key, new Uint8Array(value.byteLength).fill(99))
    }
    await operations.finish({ uploadId: created.uploadId }, requestContext)

    const worker = createWorker(repository, staging, multipart, finalizer, {
      concurrency: 1,
      pollIntervalMs: 20,
    })
    worker.start()
    await waitFor(async () => (await repository.get(created.uploadId, owner))?.status === "failed")
    await worker.stop()

    expect((await repository.get(created.uploadId, owner))?.failureCode).toBe("integrity")
    expect(multipart.createCount).toBe(1)
    expect(multipart.sessions.size).toBe(0)
    expect(staging.objects.size).toBe(0)
  })

  test("reclaims expired uploads without waiting for another client RPC", async () => {
    const user = await testUtils.createUser("native-upload-worker-expiry-reaper@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const requestContext = context(user.id, account.session.id)
    const owner = { userId: user.id, accountSessionId: account.session.id }
    const repository = new InlineUploadRepository()
    const staging = new MemoryPartStore()
    const multipart = new MemoryMultipartStore()
    const body = new Uint8Array([1, 4, 1, 4])
    const finalizer = makeFinalizer(body)
    const operations = new NativeUploadOperations(repository, staging, finalizer)
    const created = await saveBody(operations, requestContext, body, 78)
    await db.update(inlineUploads).set({
      expiresAt: new Date(0),
      hardExpiresAt: new Date(0),
    }).where(eq(inlineUploads.uploadId, Buffer.from(created.uploadId)))

    const worker = createWorker(repository, staging, multipart, finalizer, {
      concurrency: 1,
      expiryCleanupIntervalMs: 20,
      pollIntervalMs: 20,
    })
    worker.start()
    await waitFor(async () => await repository.get(created.uploadId, owner) === undefined)
    await worker.stop()

    expect(staging.objects.size).toBe(0)
  })

  const pipeline = (options: {
    staging?: MemoryPartStore
    buffer?: UploadGroupBuffer
    finalizerFor: (body: Uint8Array) => MediaUploadFinalizer
    body: Uint8Array
    inline?: boolean
  }) => {
    const repository = new InlineUploadRepository()
    const staging = options.staging ?? new BatchingPartStore()
    const multipart = new MemoryMultipartStore()
    const buffer = options.buffer ?? new UploadGroupBuffer()
    const finalizer = options.finalizerFor(options.body)
    const worker = createWorker(repository, staging, multipart, finalizer, {
      concurrency: 4, pollIntervalMs: 20, groupBuffer: buffer,
    })
    const operations = new NativeUploadOperations(repository, staging, finalizer,
      (uploadDbId, groupNumber) => worker.wake(uploadDbId, groupNumber), undefined, undefined, {
        groupBuffer: buffer,
        finishInline: options.inline === false ? undefined : (upload, signal) => worker.processNow(upload, signal),
      })
    return { repository, staging, multipart, buffer, worker, operations, finalizer }
  }

  const storageOps = (staging: MemoryPartStore, multipart: MemoryMultipartStore, partCount: number) => {
    const batch = staging instanceof BatchingPartStore ? staging.batchRemoves : 0
    const groupPuts = [...multipart.uploadPartCounts.values()].reduce((total, count) => total + count, 0)
    return {
      stagingPuts: partCount,
      stagingGets: staging.reads,
      stagingDeletes: staging.removes + batch,
      multipartPuts: groupPuts,
      finalGets: multipart.streams,
      perGroup: (staging.reads + staging.removes + batch + groupPuts + multipart.streams) /
        Math.ceil(partCount / 10),
    }
  }

  test("finishes a small document inline without staging or final-object reads", async () => {
    const user = await testUtils.createUser("native-upload-inline-finish@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const requestContext = context(user.id, account.session.id)
    const body = new Uint8Array(INLINE_TRANSFER_PART_SIZE * 2 + 1234).fill(5)
    const paths: string[] = []
    const { staging, multipart, worker, operations } = pipeline({
      body,
      finalizerFor: (expected) => {
        const base = makeFinalizer(expected)
        return {
          ...base,
          prepareStoredPublication: async (input) => { paths.push("stored"); return base.prepareStoredPublication(input) },
          prepareBufferedPublication: async (input) => { paths.push("buffered"); return base.prepareBufferedPublication(input) },
        }
      },
    })
    worker.start()
    const created = await saveBody(operations, requestContext, body, 120)
    const finished = await operations.finish({ uploadId: created.uploadId }, requestContext)
    expect(finished.state.oneofKind).toBe("complete")
    expect(paths).toEqual(["buffered"])
    expect(staging.reads).toBe(0)
    expect(multipart.streams).toBe(0)
    await waitFor(() => staging.objects.size === 0)
    const ops = storageOps(staging, multipart, created.partCount)
    console.log("UPLOAD_STORAGE_OPS inline 3-part", JSON.stringify(ops))
    expect(ops.perGroup).toBeLessThanOrEqual(2)
  })

  test("completes a 25-part upload whose buffer was evicted from staging reads and the running digest", async () => {
    const user = await testUtils.createUser("native-upload-evicted-buffer@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const requestContext = context(user.id, account.session.id)
    const owner = { userId: user.id, accountSessionId: account.session.id }
    const body = new Uint8Array(INLINE_TRANSFER_PART_SIZE * 25)
    for (let index = 0; index < body.length; index += 4096) body[index] = index % 251
    const { staging, multipart, worker, operations, repository } = pipeline({
      body,
      // Too small for any frame: every compaction reads staging.
      buffer: new UploadGroupBuffer(1),
      finalizerFor: makeFinalizer,
    })
    worker.start()
    const created = await saveBody(operations, requestContext, body, 121)
    expect((await operations.finish({ uploadId: created.uploadId }, requestContext)).state.oneofKind).toBe("processing")
    await waitFor(async () => (await repository.get(created.uploadId, owner))?.status === "complete")
    expect(staging.reads).toBe(25)
    // Groups were hashed in order while compacting, so the object is never read back.
    expect(multipart.streams).toBe(0)
    // Range hashes are recorded from the verified manifest for downloads.
    const published = await repository.get(created.uploadId, owner)
    const [stored] = await db.select({ id: files.id }).from(files)
      .where(eq(files.fileUniqueId, published!.resultFileUniqueId!)).limit(1)
    const [hashes] = await db.select().from(filePartHashes).where(eq(filePartHashes.fileId, stored!.id))
    const expectedHashes = Buffer.concat(Array.from({ length: 25 }, (_, index) => createHash("sha256")
      .update(body.subarray(index * INLINE_TRANSFER_PART_SIZE, (index + 1) * INLINE_TRANSFER_PART_SIZE)).digest()))
    expect(Buffer.from(hashes!.hashes).equals(expectedHashes)).toBeTrue()
    console.log("UPLOAD_STORAGE_OPS evicted 25-part", JSON.stringify(storageOps(staging, multipart, created.partCount)))
  })

  test("falls back to reading the stored object when another process compacted a group", async () => {
    const user = await testUtils.createUser("native-upload-two-process-digest@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const requestContext = context(user.id, account.session.id)
    const owner = { userId: user.id, accountSessionId: account.session.id }
    const body = new Uint8Array(INLINE_TRANSFER_PART_SIZE * 25).fill(3)
    const staging = new BatchingPartStore()
    const first = pipeline({ body, staging, finalizerFor: makeFinalizer, inline: false })
    first.worker.start()
    const created = await saveBody(first.operations, requestContext, body, 122)
    await waitFor(async () => (await first.repository.getStorageWork((await first.repository.get(created.uploadId, owner))!.id))!
      .storageParts.length === 2)
    await first.worker.stop()

    // A second process (fresh buffer and digest state) finishes the upload.
    const paths: string[] = []
    const base = makeFinalizer(body)
    const finalizer: MediaUploadFinalizer = {
      ...base,
      prepareStoredPublication: async (input) => { paths.push("stored"); return base.prepareStoredPublication(input) },
      prepareBufferedPublication: async (input) => { paths.push("buffered"); return base.prepareBufferedPublication(input) },
    }
    const second = createWorker(first.repository, staging, first.multipart, finalizer, { concurrency: 2, pollIntervalMs: 20 })
    const operations = new NativeUploadOperations(first.repository, staging, finalizer,
      (uploadDbId) => second.wake(uploadDbId))
    second.start()
    await operations.finish({ uploadId: created.uploadId }, requestContext)
    await waitFor(async () => (await first.repository.get(created.uploadId, owner))?.status === "complete")
    expect(paths).toEqual(["stored"])
    expect(first.multipart.streams).toBe(1)
  })

  test("fails with integrity when the running digest does not match the declared file digest", async () => {
    const user = await testUtils.createUser("native-upload-digest-mismatch@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const requestContext = context(user.id, account.session.id)
    const owner = { userId: user.id, accountSessionId: account.session.id }
    const body = new Uint8Array(INLINE_TRANSFER_PART_SIZE + 10).fill(8)
    const { worker, operations, repository, staging } = pipeline({ body, finalizerFor: makeFinalizer })
    worker.start()
    const created = await saveBody(operations, requestContext, body, 123)
    // Each frame matches its manifest digest; only the whole-file digest is wrong.
    await db.update(inlineUploads).set({ sha256: Buffer.alloc(32, 1) })
      .where(eq(inlineUploads.uploadId, Buffer.from(created.uploadId)))
    const finished = await operations.finish({ uploadId: created.uploadId }, requestContext)
    expect(finished.state.oneofKind).toBe("processing")
    await waitFor(async () => (await repository.get(created.uploadId, owner))?.status === "failed")
    expect((await repository.get(created.uploadId, owner))?.failureCode).toBe("integrity")
    expect(staging.objects.size).toBe(0)
    expect((await operations.state({ uploadId: created.uploadId }, requestContext)).failure?.retryable).toBe(false)
  })

  test("rejects finish on a canceled upload", async () => {
    const user = await testUtils.createUser("native-upload-finish-canceled@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const requestContext = context(user.id, account.session.id)
    const body = new Uint8Array([1, 2, 3])
    const { operations, buffer } = pipeline({ body, finalizerFor: makeFinalizer })
    const created = await saveBody(operations, requestContext, body, 124)
    expect(buffer.bytes).toBe(3)
    expect((await operations.cancel({ uploadId: created.uploadId }, requestContext)).canceled).toBe(true)
    expect(buffer.bytes).toBe(0)
    await expect(operations.finish({ uploadId: created.uploadId }, requestContext)).rejects.toThrow()
  })
})
