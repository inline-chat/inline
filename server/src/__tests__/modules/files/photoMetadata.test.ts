import { describe, expect, test } from "bun:test"
import sharp from "sharp"
import {
  getPhotoMetadataAndValidate,
  PHOTO_MAX_INPUT_PIXELS,
  stripPhotoMetadata,
} from "@in/server/modules/files/metadata"
import { normalizePhotoUpload } from "@in/server/modules/files/uploadPhoto"
import { generateStrippedThumbnail } from "@in/server/modules/files/strippedThumbnail"
import { toArrayBufferBackedBytes } from "@in/server/utils/arrayBuffer"

describe("getPhotoMetadataAndValidate", () => {
  test.each(["jpeg", "png", "gif", "webp"] as const)("accepts normal %s photos", async (format) => {
    const data = await sharp({
      create: {
        width: 1_200,
        height: 800,
        channels: 3,
        background: { r: 20, g: 40, b: 60 },
      },
    })
      .toFormat(format)
      .toBuffer()

    const file = new File([toArrayBufferBackedBytes(data)], `photo.${format}`, { type: `image/${format}` })
    const metadata = await getPhotoMetadataAndValidate(file)

    expect(metadata.width).toBe(1_200)
    expect(metadata.height).toBe(800)
    expect(metadata.mimeType).toBe(`image/${format}`)
  })

  test("keeps EXIF orientation dimensions and rejects undecodable image content", async () => {
    const data = await sharp({ create: { width: 120, height: 80, channels: 3, background: "red" } })
      .withMetadata({ orientation: 6 }).jpeg().toBuffer()
    expect(await getPhotoMetadataAndValidate(new File([toArrayBufferBackedBytes(data)], "rotated.jpg", { type: "image/jpeg" })))
      .toMatchObject({ width: 80, height: 120 })
    await expect(getPhotoMetadataAndValidate(new File(["invalid image"], "broken.jpg", { type: "image/jpeg" })))
      .rejects.toMatchObject({ type: "PHOTO_INVALID_TYPE" })
  })

  test("rejects ultra-wide photos with an actionable message", async () => {
    const data = await sharp({
      create: {
        width: 2_100,
        height: 100,
        channels: 3,
        background: { r: 255, g: 180, b: 0 },
      },
    })
      .jpeg()
      .toBuffer()

    const file = new File([toArrayBufferBackedBytes(data)], "panorama.jpeg", { type: "image/jpeg" })

    await expect(getPhotoMetadataAndValidate(file)).rejects.toMatchObject({
      description: "This image is too wide or too tall to send as a photo. Send it as a file instead.",
      type: "PHOTO_INVALID_DIMENSIONS",
    })
  })
})

const gpsJpeg = async (options: { orientation?: number } = {}) => {
  let pipeline = sharp({ create: { width: 120, height: 80, channels: 3, background: "red" } })
  if (options.orientation) pipeline = pipeline.withMetadata({ orientation: options.orientation })
  const data = await pipeline
    .withExifMerge({
      IFD0: { Make: "InlineCam" },
      IFD3: { GPSLatitudeRef: "N", GPSLatitude: "37/1 46/1 30/1", GPSLongitudeRef: "W", GPSLongitude: "122/1 25/1 10/1" },
    })
    .jpeg()
    .toBuffer()
  return new File([toArrayBufferBackedBytes(data)], "located.jpg", { type: "image/jpeg" })
}

describe("stripPhotoMetadata", () => {
  test("removes GPS EXIF and keeps the photo upright with its validated dimensions", async () => {
    const original = await gpsJpeg({ orientation: 6 })
    const originalHeader = await sharp(await original.arrayBuffer()).metadata()
    expect(originalHeader.exif?.includes(Buffer.from("InlineCam"))).toBe(true)
    const validated = await getPhotoMetadataAndValidate(original)
    expect(validated).toMatchObject({ width: 80, height: 120 })

    const stripped = await stripPhotoMetadata(original, validated.mimeType)

    expect(stripped.rewritten).toBe(true)
    expect(stripped.file.type).toBe("image/jpeg")
    const header = await sharp(await stripped.file.arrayBuffer()).metadata()
    expect(header.exif).toBeUndefined()
    expect(header.xmp).toBeUndefined()
    expect(header.iptc).toBeUndefined()
    // Orientation was applied to the pixels, not dropped.
    expect(header.orientation).toBeUndefined()
    expect({ width: header.width, height: header.height }).toEqual({ width: 80, height: 120 })
    expect(await getPhotoMetadataAndValidate(stripped.file)).toMatchObject({ width: 80, height: 120 })
  })

  test("leaves photos without metadata byte-for-byte unchanged", async () => {
    const data = await sharp({ create: { width: 4, height: 4, channels: 3, background: "blue" } }).png().toBuffer()
    const file = new File([toArrayBufferBackedBytes(data)], "plain.png", { type: "image/png" })
    const stripped = await stripPhotoMetadata(file, "image/png")
    expect(stripped.rewritten).toBe(false)
    expect(stripped.file).toBe(file)
  })

  test("uploads normalize GPS-tagged JPEGs before storage", async () => {
    const original = await gpsJpeg()
    const normalized = await normalizePhotoUpload(original, await getPhotoMetadataAndValidate(original))
    const header = await sharp(await normalized.file.arrayBuffer()).metadata()
    expect(header.exif).toBeUndefined()
    expect(normalized.metadata).toMatchObject({ width: 120, height: 80, mimeType: "image/jpeg" })
  })
})

describe("photo decode limits", () => {
  test("rejects an image over the pixel limit from its header with the oversized-photo error", async () => {
    // 8000 x 8000 is 64 MP: above the limit but small on disk as a flat PNG.
    const data = await sharp({ create: { width: 8_000, height: 8_000, channels: 3, background: "white" } })
      .png()
      .toBuffer()
    const file = new File([toArrayBufferBackedBytes(data)], "huge.png", { type: "image/png" })
    expect(8_000 * 8_000).toBeGreaterThan(PHOTO_MAX_INPUT_PIXELS)

    const expected = {
      type: "PHOTO_INVALID_DIMENSIONS",
      description: "This image is too large to send as a photo. Send it as a file instead.",
    }
    await expect(getPhotoMetadataAndValidate(file)).rejects.toMatchObject(expected)
    await expect(stripPhotoMetadata(file, "image/png")).rejects.toMatchObject(expected)
    await expect(generateStrippedThumbnail(file)).rejects.toThrow("exceeds pixel limit")
  })
})
