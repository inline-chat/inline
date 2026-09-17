import { describe, expect, test } from "bun:test"
import sharp from "sharp"
import { getPhotoMetadataAndValidate } from "@in/server/modules/files/metadata"
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
