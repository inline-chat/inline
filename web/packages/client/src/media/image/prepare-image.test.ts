import { describe, expect, it } from "vitest"
import { createImagePreparer, planImage, type DecodedImage, type ImageCodec } from "./prepare-image"

/**
 * A fake codec: a "file" is a JSON header with its dimensions, padded to a
 * size. Encoding returns a blob whose size follows pixels and quality, and
 * whose type can be forced, as WebKit does when it cannot encode a type.
 */
const image = (width: number, height: number, type: string, size: number) =>
  new Blob([JSON.stringify({ width, height }).padEnd(size, " ")], { type })

const fakeCodec = (options: { returnType?: (requested: string) => string; bytesPerPixel?: number; undecodable?: boolean } = {}) => {
  const closed: number[] = []
  const encodes: { width: number; height: number; type: string; quality?: number }[] = []
  let opened = 0
  const codec: ImageCodec = {
    async decode(blob) {
      if (options.undecodable) return undefined
      const header = JSON.parse((await blob.text()).trim()) as { width: number; height: number }
      const id = (opened += 1)
      const decoded: DecodedImage = { ...header, close: () => closed.push(id) }
      return decoded
    },
    async encode(_image, target) {
      encodes.push(target)
      const size = Math.max(1, Math.round(target.width * target.height * (options.bytesPerPixel ?? 0.1) * (target.quality ?? 1)))
      return new Blob([new Uint8Array(size)], { type: options.returnType?.(target.type) ?? target.type })
    },
  }
  return { codec, closed, encodes, opened: () => opened }
}

describe("image preparation", () => {
  it("resizes a JPEG to 1600 px at quality 0.87", async () => {
    const fake = fakeCodec()
    const result = await createImagePreparer(fake.codec).prepareImage(image(4000, 3000, "image/jpeg", 3_000_000), "photo")
    expect(result).toMatchObject({ kind: "image", mimeType: "image/jpeg", width: 1600, height: 1200, reencoded: true })
    expect(fake.encodes.find((target) => target.width === 1600)).toEqual({ width: 1600, height: 1200, type: "image/jpeg", quality: 0.87 })
    expect(fake.closed).toEqual([1])
  })

  it("keeps PNG as PNG within 1280 px", async () => {
    const fake = fakeCodec()
    const result = await createImagePreparer(fake.codec).prepareImage(image(1000, 2560, "image/png", 5_000_000), "photo")
    expect(result).toMatchObject({ kind: "image", mimeType: "image/png", width: 500, height: 1280 })
  })

  it("sends the original when compression does not pay (ratio over 0.8)", async () => {
    const fake = fakeCodec({ bytesPerPixel: 1 })
    const source = image(1000, 1000, "image/jpeg", 900_000)
    const result = await createImagePreparer(fake.codec).prepareImage(source, "photo")
    expect(result).toMatchObject({ kind: "image", reencoded: false, width: 1000, height: 1000 })
    if (result.kind === "image") expect(result.blob).toBe(source)
  })

  it("checks the encoded type: a canvas that returns PNG for JPEG does not pass as JPEG", async () => {
    const webkitLike = fakeCodec({ returnType: (requested) => (requested === "image/jpeg" ? "image/png" : requested) })
    const jpeg = await createImagePreparer(webkitLike.codec).prepareImage(image(3000, 2000, "image/jpeg", 2_000_000), "photo")
    expect(jpeg).toMatchObject({ kind: "image", mimeType: "image/jpeg", reencoded: false })
    if (jpeg.kind === "image") expect(jpeg.tinyPreview).toBeUndefined()
    const heic = await createImagePreparer(webkitLike.codec).prepareImage(image(3000, 2000, "image/heic", 2_000_000), "photo")
    expect(heic).toEqual({ kind: "document", reason: "unsupported" })
  })

  it("re-encodes types the server does not take as photos to JPEG", async () => {
    const fake = fakeCodec()
    const result = await createImagePreparer(fake.codec).prepareImage(image(800, 600, "image/webp", 100_000), "photo")
    expect(result).toMatchObject({ kind: "image", mimeType: "image/jpeg", width: 800, height: 600, reencoded: true })
  })

  it("sends animated and undecodable images as documents", async () => {
    expect(await createImagePreparer(fakeCodec().codec).prepareImage(image(10, 10, "image/gif", 100), "photo"))
      .toEqual({ kind: "document", reason: "animated" })
    expect(await createImagePreparer(fakeCodec({ undecodable: true }).codec).prepareImage(image(10, 10, "image/jpeg", 100), "photo"))
      .toEqual({ kind: "document", reason: "undecodable" })
  })

  it("makes a tiny JPEG preview within 40 px and keeps the original for a file send", async () => {
    const fake = fakeCodec()
    const source = image(4000, 1000, "image/png", 1_000_000)
    const result = await createImagePreparer(fake.codec).prepareImage(source, "original")
    expect(fake.encodes).toEqual([{ width: 40, height: 10, type: "image/jpeg", quality: 0.5 }])
    expect(result).toMatchObject({ kind: "image", width: 4000, height: 1000, reencoded: false })
    if (result.kind === "image") {
      expect(result.blob).toBe(source)
      expect(result.tinyPreview?.length).toBeGreaterThan(0)
    }
  })

  it("plans from the Mac client's limits", () => {
    expect(planImage("image/jpeg", 1000, 800)).toMatchObject({ width: 1000, height: 800, type: "image/jpeg", minimumRatio: 0.8 })
    expect(planImage("image/png", 2560, 2560)).toMatchObject({ width: 1280, height: 1280, type: "image/png", minimumRatio: 0.9 })
    expect(planImage("image/avif", 3200, 100)).toMatchObject({ width: 1600, height: 50, originalUsable: false })
  })
})
