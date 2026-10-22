import { createHash } from "node:crypto"
import sharp from "sharp"
import { describe, expect, test } from "bun:test"
import type {
  InlineUploadPartRecord,
  InlineUploadRecord,
} from "@in/server/db/models/inlineUploads"
import { UploadIntegrityError, UploadMediaFinalizer } from "./finalizer"
import type { UploadPartStore } from "./partStore"
import { FileByteLengthError } from "@in/server/modules/files/readFileBytes"
import { INLINE_MEDIA_UPLOAD_MAX_BYTES, INLINE_TRANSFER_PART_SIZE } from "@inline-chat/protocol/transfers"

const bytes = new TextEncoder().encode("verified part")

const part: InlineUploadPartRecord = {
  partIndex: 0,
  byteCount: bytes.length,
  sha256: createHash("sha256").update(bytes).digest(),
  storedByteCount: bytes.length,
  storedSha256: createHash("sha256").update(bytes).digest(),
  objectKey: "part-0",
}

const upload = {
  fileName: "proof.bin",
  mimeType: "application/octet-stream",
  byteCount: BigInt(bytes.length),
  sha256: createHash("sha256").update(bytes).digest(),
  kind: "document",
  userId: 7,
} as InlineUploadRecord

describe("native upload finalizer integrity", () => {
  test("prepares a 500 MB stored video without whole-file buffering or video transcoding", async () => {
    const size = INLINE_MEDIA_UPLOAD_MAX_BYTES.video
    const chunk = new Uint8Array(INLINE_TRANSFER_PART_SIZE).fill(73)
    const digest = createHash("sha256")
    for (let offset = 0; offset < size; offset += chunk.length) digest.update(chunk.subarray(0, Math.min(chunk.length, size - offset)))
    let emitted = 0
    let largestChunk = 0
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (emitted === size) { controller.close(); return }
        const bytes = chunk.subarray(0, Math.min(chunk.length, size - emitted))
        largestChunk = Math.max(largestChunk, bytes.length)
        emitted += bytes.length
        controller.enqueue(bytes)
      },
    })
    const store: UploadPartStore = {
      async put() { throw new Error("not used") },
      async read() { throw new Error("not used") },
      async remove() {},
    }
    const publication = await new UploadMediaFinalizer(store).prepareStoredPublication({
      upload: {
        ...upload, uploadId: Buffer.alloc(16), kind: "video", fileName: "proof.mp4", mimeType: "video/mp4",
        byteCount: BigInt(size), sha256: digest.digest(), videoWidth: 1280, videoHeight: 720, duration: 100,
      },
      stream,
      assertOwnership: async () => {},
    })
    expect(publication.file.record.fileSize).toBe(size)
    expect(publication.media).toMatchObject({ kind: "video", width: 1280, height: 720, duration: 100 })
    expect(emitted).toBe(size)
    expect(largestChunk).toBeLessThanOrEqual(INLINE_TRANSFER_PART_SIZE)
  }, 30_000)
  test("treats bounded storage length mismatch as terminal integrity failure", async () => {
    const store: UploadPartStore = {
      async put() { throw new Error("not used") },
      async read() { throw new FileByteLengthError() },
      async remove() {},
    }
    await expect(new UploadMediaFinalizer(store).preparePublication({
      upload, parts: [part], assertOwnership: async () => {},
    })).rejects.toBeInstanceOf(UploadIntegrityError)
  })

  test("refills before the slowest initial read completes", async () => {
    let unblock!: () => void
    const slow = new Promise<void>((resolve) => { unblock = resolve })
    const partBytes = Array.from({ length: 6 }, (_, index) => new Uint8Array([index]))
    const parts = partBytes.map((data, partIndex) => ({
      partIndex, byteCount: 1, sha256: createHash("sha256").update(data).digest(),
      storedByteCount: 1, storedSha256: createHash("sha256").update(data).digest(),
      objectKey: String(partIndex),
    }))
    const reads: number[] = []
    const store: UploadPartStore = {
      async put() { throw new Error("not used") },
      async read(key) {
        const index = Number(key)
        reads.push(index)
        if (index === 3) await slow
        if (index === 4) unblock()
        return partBytes[index]!
      },
      async remove() {},
    }
    const boundary = new Error("verified assembly")
    let ownershipChecks = 0
    try {
      await expect(new UploadMediaFinalizer(store).preparePublication({
        upload: { ...upload, byteCount: 6n, sha256: createHash("sha256").update(Buffer.concat(partBytes)).digest() },
        parts,
        assertOwnership: async () => { if (++ownershipChecks === 2) throw boundary },
      })).rejects.toBe(boundary)
      expect(reads).toEqual([0, 1, 2, 3, 4, 5])
    } finally { unblock() }
  })

  test("cancellation stops refill and drains the already admitted reads", async () => {
    const abort = new AbortController()
    let reads = 0
    let active = 0
    const store: UploadPartStore = {
      async put() { throw new Error("not used") },
      async read() {
        reads += 1
        active += 1
        await Bun.sleep(1)
        abort.abort()
        active -= 1
        return bytes
      },
      async remove() {},
    }
    await expect(new UploadMediaFinalizer(store).preparePublication({
      upload, parts: Array.from({ length: 8 }, (_, partIndex) => ({ ...part, partIndex })),
      assertOwnership: async () => {}, signal: abort.signal,
    })).rejects.toMatchObject({ name: "AbortError" })
    expect(reads).toBe(4)
    expect(active).toBe(0)
  })

  test("does not begin publication after cancellation", async () => {
    let reads = 0
    const store: UploadPartStore = {
      async put() { throw new Error("not used") },
      async read() { reads += 1; return bytes },
      async remove() {},
    }
    const controller = new AbortController()
    controller.abort()

    await expect(new UploadMediaFinalizer(store).preparePublication({
      upload,
      parts: [part],
      assertOwnership: async () => {},
      signal: controller.signal,
    })).rejects.toMatchObject({ name: "AbortError" })
    expect(reads).toBe(0)
  })

  test("cancels a stalled stored-object body after response headers", async () => {
    const store: UploadPartStore = {
      async put() { throw new Error("not used") },
      async read() { throw new Error("not used") },
      async remove() {},
    }
    const controller = new AbortController()
    let canceled = false
    const stream = new ReadableStream<Uint8Array>({
      pull() {},
      cancel() { canceled = true },
    })
    const finalization = new UploadMediaFinalizer(store).prepareStoredPublication({
      upload,
      stream,
      assertOwnership: async () => {},
      signal: controller.signal,
    })
    await Bun.sleep(1)
    controller.abort(new DOMException("test cancellation", "AbortError"))

    await expect(finalization).rejects.toMatchObject({ name: "AbortError" })
    expect(canceled).toBe(true)
  })

  test("rejects substituted part bytes before media publication", async () => {
    const store: UploadPartStore = {
      async put() { throw new Error("not used") },
      async read() { return new TextEncoder().encode("altered part!") },
      async remove() {},
    }
    await expect(new UploadMediaFinalizer(store).preparePublication({
      upload,
      parts: [part],
      assertOwnership: async () => {},
    }))
      .rejects.toBeInstanceOf(UploadIntegrityError)
  })

  test("rejects an incorrect whole-file commitment", async () => {
    const store: UploadPartStore = {
      async put() { throw new Error("not used") },
      async read() { return bytes },
      async remove() {},
    }
    const wrongCommitment = {
      ...upload,
      sha256: Buffer.alloc(32, 9),
    }
    await expect(new UploadMediaFinalizer(store).preparePublication({
      upload: wrongCommitment,
      parts: [part],
      assertOwnership: async () => {},
    })).rejects.toBeInstanceOf(UploadIntegrityError)
  })

  test("prefetches four parts while preserving ordered assembly", async () => {
    const partBytes = Array.from({ length: 9 }, (_, index) => new Uint8Array([index + 1]))
    const parts = partBytes.map((value, partIndex): InlineUploadPartRecord => ({
      partIndex,
      byteCount: value.length,
      sha256: createHash("sha256").update(value).digest(),
      storedByteCount: value.length,
      storedSha256: createHash("sha256").update(value).digest(),
      objectKey: `part-${partIndex}`,
    }))
    let activeReads = 0
    let maximumActiveReads = 0
    let readCount = 0
    const store: UploadPartStore = {
      async put() { throw new Error("not used") },
      async read(key) {
        const index = Number(key.slice("part-".length))
        activeReads += 1
        readCount += 1
        maximumActiveReads = Math.max(maximumActiveReads, activeReads)
        await Bun.sleep(9 - index)
        activeReads -= 1
        return partBytes[index]!
      },
      async remove() {},
    }
    const publicationBoundary = new Error("publication boundary")
    let ownershipChecks = 0

    await expect(new UploadMediaFinalizer(store).preparePublication({
      upload: {
        ...upload,
        byteCount: 9n,
        sha256: createHash("sha256").update(Buffer.concat(partBytes)).digest(),
      },
      parts,
      assertOwnership: async () => {
        ownershipChecks += 1
        if (ownershipChecks === 2) throw publicationBoundary
      },
    })).rejects.toBe(publicationBoundary)

    expect(readCount).toBe(parts.length)
    expect(maximumActiveReads).toBe(4)
  })

  const unusedStore: UploadPartStore = {
    async put() { throw new Error("not used") },
    async read() { throw new Error("not used") },
    async remove() {},
  }

  test("publishes a verified document from metadata alone", async () => {
    const size = 300 * 1024 * 1024
    const publication = await new UploadMediaFinalizer(unusedStore).prepareBufferedPublication({
      upload: { ...upload, uploadId: Buffer.alloc(16), fileName: "report.pdf", mimeType: "application/pdf", byteCount: BigInt(size) },
      assertOwnership: async () => {},
    })
    expect(publication.file.record.fileSize).toBe(size)
    expect(publication.media.kind).toBe("document")
  })

  test("decodes a buffered photo from its frames and requires them", async () => {
    const png = Uint8Array.from(await sharp({
      create: { width: 2, height: 1, channels: 3, background: { r: 10, g: 20, b: 30 } },
    }).png().toBuffer())
    const photo = {
      ...upload, uploadId: Buffer.alloc(16), kind: "photo", fileName: "pixel.png", mimeType: "image/png",
      byteCount: BigInt(png.length), sha256: createHash("sha256").update(png).digest(),
    } as InlineUploadRecord
    const finalizer = new UploadMediaFinalizer(unusedStore)
    await expect(finalizer.prepareBufferedPublication({ upload: photo, assertOwnership: async () => {} }))
      .rejects.toBeInstanceOf(UploadIntegrityError)
    const publication = await finalizer.prepareBufferedPublication({
      upload: photo,
      frames: [png.subarray(0, 10), png.subarray(10)],
      assertOwnership: async () => {},
    })
    expect(publication.media).toMatchObject({ kind: "photo", width: 2, height: 1, format: "png" })
    await expect(finalizer.prepareBufferedPublication({
      upload: photo, frames: [png.subarray(0, 10)], assertOwnership: async () => {},
    })).rejects.toBeInstanceOf(UploadIntegrityError)
  })
})
