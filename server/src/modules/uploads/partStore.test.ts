import { describe, expect, test } from "bun:test"
import { R2UploadPartStore, UploadPartStorageUnavailableError } from "./partStore"

describe("upload part storage writes", () => {
  test("classifies a short staging write before returning a manifest key", async () => {
    const store = new R2UploadPartStore(async () => 2)
    await expect(store.put({
      uploadId: new Uint8Array(16),
      partIndex: 0,
      sha256: new Uint8Array(32),
      data: new Uint8Array(3),
    })).rejects.toBeInstanceOf(UploadPartStorageUnavailableError)
  })
})
