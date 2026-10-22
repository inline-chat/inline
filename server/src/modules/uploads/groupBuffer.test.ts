import { describe, expect, test } from "bun:test"
import { UploadGroupBuffer } from "./groupBuffer"

const frame = (value: number, size = 4) => new Uint8Array(size).fill(value)

describe("upload group buffer", () => {
  test("takes a group only when every frame is present and returns copies", () => {
    const buffer = new UploadGroupBuffer(1_000)
    buffer.put(1, 0, frame(1))
    expect(buffer.takeGroup(1, 0, 2)).toBeUndefined()
    buffer.put(1, 1, frame(2))
    const peeked = buffer.peekGroup(1, 0, 2)!
    peeked[0]![0] = 99
    expect(buffer.peekGroup(1, 0, 2)![0]![0]).toBe(1)
    expect(buffer.takeGroup(1, 0, 2)).toEqual([frame(1), frame(2)])
    expect(buffer.bytes).toBe(0)
    expect(buffer.has(1, 0)).toBeFalse()
  })

  test("evicts whole uploads, least recently touched first", () => {
    const buffer = new UploadGroupBuffer(20)
    buffer.put(1, 0, frame(1, 8))
    buffer.put(2, 0, frame(2, 8))
    buffer.put(1, 1, frame(1, 2))
    buffer.put(3, 0, frame(3, 8))
    expect(buffer.has(2, 0)).toBeFalse()
    expect(buffer.hasAll(1, 0, 2)).toBeTrue()
    expect(buffer.has(3, 0)).toBeTrue()
    expect(buffer.bytes).toBe(18)
    buffer.put(4, 0, frame(4, 25))
    expect(buffer.has(4, 0)).toBeFalse()
    buffer.drop(1)
    expect(buffer.bytes).toBe(8)
  })

  test("replacing a frame keeps the byte accounting exact", () => {
    const buffer = new UploadGroupBuffer(100)
    buffer.put(1, 0, frame(1, 10))
    buffer.put(1, 0, frame(2, 6))
    expect(buffer.bytes).toBe(6)
    buffer.clear()
    expect(buffer.bytes).toBe(0)
  })
})
