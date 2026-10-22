import { createHash } from "node:crypto"
import { describe, expect, test } from "bun:test"
import { INLINE_TRANSFER_PART_SIZE } from "@inline-chat/protocol/transfers"
import { PartHasher, alignedPartHash, isValidPartHashes, partHashesFromManifest } from "./partHashes"

const digest = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest()

describe("file part hashes", () => {
  const size = INLINE_TRANSFER_PART_SIZE * 2 + 17
  const body = new Uint8Array(size).map((_, index) => (index * 7) % 256)
  const expected = Buffer.concat([
    digest(body.subarray(0, INLINE_TRANSFER_PART_SIZE)),
    digest(body.subarray(INLINE_TRANSFER_PART_SIZE, INLINE_TRANSFER_PART_SIZE * 2)),
    digest(body.subarray(INLINE_TRANSFER_PART_SIZE * 2)),
  ])

  test("hashes a streamed body in 512 KiB ranges regardless of chunking", () => {
    for (const chunk of [1_000, 65_536, INLINE_TRANSFER_PART_SIZE, size]) {
      const hasher = new PartHasher()
      for (let offset = 0; offset < size; offset += chunk) hasher.update(body.subarray(offset, offset + chunk))
      expect(hasher.finish(size)).toEqual(expected)
    }
    const short = new PartHasher()
    short.update(body.subarray(0, 10))
    expect(short.finish(size)).toBeUndefined()
  })

  test("builds the list only from a complete, exactly sized manifest", () => {
    const parts = [0, 1, 2].map((partIndex) => {
      const bytes = body.subarray(partIndex * INLINE_TRANSFER_PART_SIZE, (partIndex + 1) * INLINE_TRANSFER_PART_SIZE)
      return { partIndex, byteCount: bytes.length, sha256: digest(bytes) }
    })
    expect(partHashesFromManifest(parts, size)).toEqual(expected)
    expect(partHashesFromManifest(parts.slice(0, 2), size)).toBeUndefined()
    expect(partHashesFromManifest([parts[1]!, parts[0]!, parts[2]!], size)).toBeUndefined()
    expect(partHashesFromManifest(parts.map((part) => ({ ...part, byteCount: 1 })), size)).toBeUndefined()
  })

  test("returns a digest only for aligned full ranges or the exact tail", () => {
    expect(isValidPartHashes(expected, size)).toBeTrue()
    expect(isValidPartHashes(expected.subarray(0, 64), size)).toBeFalse()
    expect(alignedPartHash(expected, size, 0, INLINE_TRANSFER_PART_SIZE)).toEqual(expected.subarray(0, 32))
    expect(alignedPartHash(expected, size, INLINE_TRANSFER_PART_SIZE * 2, 17)).toEqual(expected.subarray(64, 96))
    expect(alignedPartHash(expected, size, 1, INLINE_TRANSFER_PART_SIZE)).toBeUndefined()
    expect(alignedPartHash(expected, size, 0, 4_096)).toBeUndefined()
  })
})
