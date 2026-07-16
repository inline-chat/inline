import { describe, expect, test } from "bun:test"
import { toArrayBufferBackedBytes } from "./arrayBuffer"

describe("toArrayBufferBackedBytes", () => {
  test("keeps ArrayBuffer-backed bytes zero-copy", () => {
    const bytes = Uint8Array.from([1, 2, 3])
    const result = toArrayBufferBackedBytes(bytes)

    expect([...result]).toEqual([...bytes])
    expect(result.buffer).toBe(bytes.buffer)
  })

  test("copies SharedArrayBuffer-backed bytes", () => {
    const sharedBuffer = new SharedArrayBuffer(3)
    const bytes = new Uint8Array(sharedBuffer)
    bytes.set([1, 2, 3])

    const result = toArrayBufferBackedBytes(bytes)

    expect([...result]).toEqual([...bytes])
    expect(result.buffer).toBeInstanceOf(ArrayBuffer)
    expect(result.buffer).not.toBe(sharedBuffer)
  })
})
