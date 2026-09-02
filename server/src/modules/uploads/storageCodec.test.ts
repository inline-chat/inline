import { describe, expect, test } from "bun:test"
import {
  IDENTITY_STORAGE_FORMAT,
  IdentityStorageFormatCodec,
  storageCodecFor,
} from "./storageCodec"

describe("native upload storage codec", () => {
  test("identity_v1 preserves immutable frame bytes and streaming decode", async () => {
    const codec = new IdentityStorageFormatCodec()
    const input = new Uint8Array([0, 1, 2, 253, 254, 255])
    const uploadId = new Uint8Array(16).fill(3)
    const logicalSha256 = new Uint8Array(32).fill(4)
    const encoded = codec.encodeFrame(input, {
      uploadId,
      partIndex: 0,
      logicalByteCount: input.byteLength,
      logicalSha256,
    })
    expect(encoded.format).toBe(IDENTITY_STORAGE_FORMAT)
    expect(encoded.bytes).toEqual(input)

    const decoded = codec.decodeObject(new Blob([Uint8Array.from(encoded.bytes)]).stream(), {
      uploadId,
      logicalByteCount: BigInt(input.byteLength),
      logicalSha256,
      frames: [{
        uploadId,
        partIndex: 0,
        logicalByteCount: input.byteLength,
        logicalSha256,
        storedByteCount: encoded.bytes.byteLength,
        storedSha256: new Uint8Array(32).fill(5),
      }],
    })
    expect(new Uint8Array(await new Response(decoded).arrayBuffer())).toEqual(Uint8Array.from(input))
  })

  test("rejects unknown or legacy-null formats at the codec boundary", () => {
    expect(storageCodecFor(IDENTITY_STORAGE_FORMAT)).toBeDefined()
    expect(storageCodecFor(null)).toBeUndefined()
    expect(storageCodecFor("future_v2")).toBeUndefined()
  })
})
