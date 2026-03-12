import { beforeEach, describe, expect, test } from "bun:test"
import { Photo_Format } from "@inline-chat/protocol/core"
import { encodePhoto } from "@in/server/realtime/encoders/encodePhoto"
import { encryptBinary } from "@in/server/modules/encryption/encryption"
import type { DbFullPhoto } from "@in/server/db/models/files"

beforeEach(() => {
  process.env["ENCRYPTION_KEY"] = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
})

describe("encodePhoto", () => {
  test("includes a stripped thumbnail size when the photo stores embedded bytes", () => {
    const encrypted = encryptBinary(Buffer.from([1, 12, 16, 10, 20, 30]))
    const photo: DbFullPhoto = {
      id: 42,
      format: "jpeg",
      width: 1600,
      height: 1200,
      stripped: encrypted.encrypted,
      strippedIv: encrypted.iv,
      strippedTag: encrypted.authTag,
      date: new Date("2025-01-01T00:00:00Z"),
      photoSizes: [],
    }

    const result = encodePhoto({ photo })
    const stripped = result.sizes.find((size) => size.type === "s")

    expect(result.format).toBe(Photo_Format.JPEG)
    expect(stripped?.w).toBe(16)
    expect(stripped?.h).toBe(12)
    expect(stripped?.bytes).toEqual(Buffer.from([1, 12, 16, 10, 20, 30]))
  })
})
