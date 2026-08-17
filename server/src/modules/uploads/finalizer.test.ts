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
  test("rejects substituted part bytes before media publication", async () => {
    const store: UploadPartStore = {
      async put() { throw new Error("not used") },
      async read() { return new TextEncoder().encode("altered part!") },
      async remove() {},
    }
    await expect(new UploadMediaFinalizer(store).finalize({ upload, parts: [part] }))
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
    await expect(new UploadMediaFinalizer(store).finalize({
      upload: wrongCommitment,
      parts: [part],
    })).rejects.toBeInstanceOf(UploadIntegrityError)
  })
})
