import { createHash } from "node:crypto"
import { describe, expect, test } from "bun:test"
import type {
  InlineUploadPartRecord,
  InlineUploadRecord,
} from "@in/server/db/models/inlineUploads"
import { UploadIntegrityError, UploadMediaFinalizer } from "./finalizer"
import type { UploadPartStore } from "./partStore"

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
