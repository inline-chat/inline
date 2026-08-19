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
})
