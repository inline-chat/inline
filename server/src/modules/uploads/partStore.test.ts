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

  test("bounds a staging read that never returns", async () => {
    const store = new R2UploadPartStore(undefined, {
      readStream: () => new ReadableStream<Uint8Array>({ start() {} }),
      readTimeoutMs: 10,
    })

    await expect(store.read("stalled", 1)).rejects.toBeInstanceOf(UploadPartStorageUnavailableError)
  })

  test("bounds a staging write that ignores transport progress", async () => {
    let writeSignal: AbortSignal | undefined
    const store = new R2UploadPartStore(async (_key, _data, signal) => {
      writeSignal = signal
      return new Promise<never>((_, reject) => {
        signal?.addEventListener("abort", () => reject(signal.reason), { once: true })
      })
    }, { operationTimeoutMs: 10 })

    await expect(store.put({
      uploadId: new Uint8Array(16),
      partIndex: 0,
      sha256: new Uint8Array(32),
      data: new Uint8Array(3),
    })).rejects.toBeInstanceOf(UploadPartStorageUnavailableError)
    expect(writeSignal?.aborted).toBe(true)
  })

  test("bounds staging cleanup so shutdown cannot wait forever", async () => {
    let removeSignal: AbortSignal | undefined
    const store = new R2UploadPartStore(async (_key, data) => data.byteLength, {
      operationTimeoutMs: 10,
      removePart: async (_key, signal) => {
        removeSignal = signal
        await new Promise<never>((_, reject) => {
          signal?.addEventListener("abort", () => reject(signal.reason), { once: true })
        })
      },
    })

    await expect(store.remove("stalled")).rejects.toBeInstanceOf(UploadPartStorageUnavailableError)
    expect(removeSignal?.aborted).toBe(true)
  })
})
