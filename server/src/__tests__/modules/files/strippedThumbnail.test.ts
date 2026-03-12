import { describe, expect, test } from "bun:test"
import sharp from "sharp"
import {
  decodeStrippedThumbnail,
  generateStrippedThumbnail,
  getStrippedThumbnailDimensions,
} from "@in/server/modules/files/strippedThumbnail"

describe("strippedThumbnail", () => {
  test("generates Telegram-style payload bytes that decode back to a JPEG", async () => {
    const data = await sharp({
      create: {
        width: 160,
        height: 100,
        channels: 3,
        background: { r: 24, g: 80, b: 160 },
      },
    })
      .jpeg()
      .toBuffer()

    const file = new File([data], "photo.jpeg", { type: "image/jpeg" })
    const stripped = await generateStrippedThumbnail(file)
    const decoded = decodeStrippedThumbnail(stripped.bytes)
    const metadata = await sharp(decoded).metadata()

    expect(stripped.bytes[0]).toBe(1)
    expect(stripped.width).toBe(40)
    expect(stripped.height).toBe(25)
    expect(metadata.format).toBe("jpeg")
    expect(metadata.width).toBe(40)
    expect(metadata.height).toBe(25)
  })

  test("flattens transparent images before encoding", async () => {
    const data = await sharp({
      create: {
        width: 30,
        height: 30,
        channels: 4,
        background: { r: 255, g: 0, b: 0, alpha: 0 },
      },
    })
      .png()
      .toBuffer()

    const file = new File([data], "photo.png", { type: "image/png" })
    const stripped = await generateStrippedThumbnail(file)
    const metadata = getStrippedThumbnailDimensions(stripped.bytes)

    expect(metadata.width).toBe(30)
    expect(metadata.height).toBe(30)
  })
})

