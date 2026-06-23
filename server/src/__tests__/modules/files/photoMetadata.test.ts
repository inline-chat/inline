import { describe, expect, test } from "bun:test"
import sharp from "sharp"
import { getPhotoMetadataAndValidate } from "@in/server/modules/files/metadata"

describe("getPhotoMetadataAndValidate", () => {
  test("accepts normal jpeg photos", async () => {
    const data = await sharp({
      create: {
        width: 1_200,
        height: 800,
        channels: 3,
        background: { r: 20, g: 40, b: 60 },
      },
    })
      .jpeg()
      .toBuffer()

    const file = new File([data], "photo.jpeg", { type: "image/jpeg" })
    const metadata = await getPhotoMetadataAndValidate(file)

    expect(metadata.width).toBe(1_200)
    expect(metadata.height).toBe(800)
    expect(metadata.mimeType).toBe("image/jpeg")
  })

  test("accepts avif photos for server-side normalization", async () => {
    const data = await sharp({
      create: {
        width: 640,
        height: 360,
        channels: 3,
        background: { r: 40, g: 80, b: 120 },
      },
    })
      .avif()
      .toBuffer()

    const file = new File([data], "photo.avif", { type: "image/avif" })
    const metadata = await getPhotoMetadataAndValidate(file)

    expect(metadata.width).toBe(640)
    expect(metadata.height).toBe(360)
    expect(metadata.mimeType).toBe("image/avif")
    expect(metadata.extension).toBe("avif")
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

    const file = new File([data], "panorama.jpeg", { type: "image/jpeg" })

    await expect(getPhotoMetadataAndValidate(file)).rejects.toMatchObject({
      description: "This image is too wide or too tall to send as a photo. Send it as a file instead.",
      type: "PHOTO_INVALID_DIMENSIONS",
    })
  })
})
