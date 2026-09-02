import { describe, expect, test } from "bun:test"
import { uploadToBucket } from "./uploadToBucket"

describe("file object storage writes", () => {
  test("rejects a short permanent-object write", async () => {
    const file = new File([new Uint8Array([1, 2, 3])], "proof.bin")
    await expect(uploadToBucket(file, {
      path: "native-uploads/v1/proof",
      type: "application/octet-stream",
    }, async () => 2)).rejects.toThrow("wrote 2 of 3 bytes")
  })

  test("aborts a stalled permanent-object write at its provider deadline", async () => {
    const file = new File([new Uint8Array([1, 2, 3])], "proof.bin")
    let writeSignal: AbortSignal | undefined
    await expect(uploadToBucket(file, {
      path: "native-uploads/v1/proof",
      type: "application/octet-stream",
      timeoutMs: 10,
    }, async (_path, _file, _type, signal) => {
      writeSignal = signal
      return await new Promise<number>((_resolve, reject) => {
        const onAbort = () => reject(signal.reason)
        signal.addEventListener("abort", onAbort, { once: true })
        if (signal.aborted) onAbort()
      })
    })).rejects.toMatchObject({ name: "TimeoutError" })
    expect(writeSignal?.aborted).toBe(true)
  })

  test("forwards owner cancellation to a permanent-object write", async () => {
    const file = new File([new Uint8Array([1, 2, 3])], "proof.bin")
    const controller = new AbortController()
    const write = uploadToBucket(file, {
      path: "native-uploads/v1/proof",
      type: "application/octet-stream",
      signal: controller.signal,
    }, async (_path, _file, _type, signal) => await new Promise<number>((_resolve, reject) => {
      const onAbort = () => reject(signal.reason)
      signal.addEventListener("abort", onAbort, { once: true })
      if (signal.aborted) onAbort()
    }))
    controller.abort(new DOMException("ownership lost", "AbortError"))

    await expect(write).rejects.toMatchObject({ name: "AbortError" })
  })
})
