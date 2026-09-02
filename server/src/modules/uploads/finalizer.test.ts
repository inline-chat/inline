import { createHash } from "node:crypto"
import { describe, expect, test } from "bun:test"
import type {
  InlineUploadPartRecord,
  InlineUploadRecord,
} from "@in/server/db/models/inlineUploads"
import { UploadIntegrityError, UploadMediaFinalizer } from "./finalizer"
import type { UploadPartStore } from "./partStore"
import { FileByteLengthError } from "@in/server/modules/files/readFileBytes"

const bytes = new TextEncoder().encode("verified part")

const part: InlineUploadPartRecord = {
  partIndex: 0,
  byteCount: bytes.length,
  sha256: createHash("sha256").update(bytes).digest(),
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
      partIndex, byteCount: 1, sha256: createHash("sha256").update(data).digest(), objectKey: String(partIndex),
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
})
