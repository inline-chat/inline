import { describe, expect, it } from "bun:test"
import { notificationPhotoUrl } from "./notificationPhoto"

const size = (overrides: Partial<{
  fileSize: number | null; mimeType: string | null; width: number | null; height: number | null
}> = {}, kind = "f") => ({
  size: kind,
  file: { fileUniqueId: "photo_test_123", path: "photo.jpg", fileSize: 100_000,
    mimeType: "image/jpeg", width: 800, height: 600, ...overrides },
})

describe("notification photo URL", () => {
  it("selects the largest eligible stored representation and signs for one hour", () => {
    const result = notificationPhotoUrl({ photoSizes: [
      size({ width: 200, height: 100 }), size(), size({ fileSize: 6 * 1_024 * 1_024, width: 4000 }),
    ] }, (file, ttl) => {
      expect(file).toMatchObject({ width: 800, height: 600 })
      expect(ttl).toBe(3600)
      return "https://media.inline.chat/photo.jpg?signed=test"
    })
    expect(result).toBe("https://media.inline.chat/photo.jpg?signed=test")
  })

  it("does not request artwork for missing, stripped, oversized, unsupported, or unsafe-size photos", () => {
    for (const photo of [null, { photoSizes: null }, { photoSizes: [] },
      ...[size({}, "s"), size({ fileSize: null }), size({ fileSize: 5 * 1_024 * 1_024 + 1 }),
        size({ mimeType: "image/gif" }), size({ mimeType: "image/svg+xml" }),
        size({ width: 0 }), size({ width: 50_000, height: 50_000 })].map((item) => ({ photoSizes: [item] })),
    ]) {
      let called = false
      expect(notificationPhotoUrl(photo, () => { called = true; return "https://example.com/photo" })).toBeUndefined()
      expect(called).toBe(false)
    }
  })

  it("accepts the download limit exactly and rejects insecure or oversized URLs", () => {
    const photo = { photoSizes: [size({ fileSize: 5 * 1_024 * 1_024, mimeType: "image/png" })] }
    expect(notificationPhotoUrl(photo, () => "https://example.com/photo.png")).toBeDefined()
    for (const url of [null, "http://example.com/photo", "https://user:password@example.com/photo", "invalid", "https://example.com/" + "a".repeat(1024)]) {
      expect(notificationPhotoUrl(photo, () => url)).toBeUndefined()
    }
    expect(notificationPhotoUrl(photo, () => { throw new Error("signer unavailable") })).toBeUndefined()
  })
})
