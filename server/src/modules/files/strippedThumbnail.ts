import sharp from "sharp"

const STRIPPED_THUMBNAIL_VERSION = 1
const STRIPPED_THUMBNAIL_MAX_DIMENSION = 40
const STRIPPED_THUMBNAIL_JPEG_HEADER = Buffer.from(
  "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAAAAADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9o=",
  "base64",
)
const STRIPPED_THUMBNAIL_JPEG_FOOTER = Buffer.from([0xff, 0xd9])
const STRIPPED_THUMBNAIL_JPEG_HEIGHT_OFFSET = 145
const STRIPPED_THUMBNAIL_JPEG_WIDTH_OFFSET = 147
const STRIPPED_THUMBNAIL_PAYLOAD_HEADER_BYTES = 3

export type StrippedThumbnail = {
  bytes: Buffer
  width: number
  height: number
}

export async function generateStrippedThumbnail(file: File): Promise<StrippedThumbnail> {
  const { data, info } = await sharp(await file.arrayBuffer())
    .rotate()
    .resize({
      width: STRIPPED_THUMBNAIL_MAX_DIMENSION,
      height: STRIPPED_THUMBNAIL_MAX_DIMENSION,
      fit: "inside",
      withoutEnlargement: true,
    })
    .flatten({ background: { r: 255, g: 255, b: 255 } })
    .jpeg({
      quality: 20,
      progressive: false,
      mozjpeg: false,
      optimizeCoding: false,
    })
    .toBuffer({ resolveWithObject: true })

  const width = info.width ?? 0
  const height = info.height ?? 0

  if (width <= 0 || height <= 0 || width > 255 || height > 255) {
    throw new Error(`Invalid stripped thumbnail size ${width}x${height}`)
  }

  const body = stripJpegHeader({
    jpeg: data,
    width,
    height,
  })

  return {
    bytes: Buffer.concat([Buffer.from([STRIPPED_THUMBNAIL_VERSION, height, width]), body]),
    width,
    height,
  }
}

export function getStrippedThumbnailDimensions(bytes: Uint8Array): { width: number; height: number } {
  if (bytes.length < STRIPPED_THUMBNAIL_PAYLOAD_HEADER_BYTES) {
    throw new Error("Stripped thumbnail payload is too short")
  }

  if (bytes[0] !== STRIPPED_THUMBNAIL_VERSION) {
    throw new Error(`Unsupported stripped thumbnail version ${bytes[0]}`)
  }

  return {
    width: bytes[2] ?? 0,
    height: bytes[1] ?? 0,
  }
}

export function decodeStrippedThumbnail(bytes: Uint8Array): Buffer {
  const { width, height } = getStrippedThumbnailDimensions(bytes)
  const jpeg = Buffer.concat([
    Buffer.from(STRIPPED_THUMBNAIL_JPEG_HEADER),
    Buffer.from(bytes.subarray(STRIPPED_THUMBNAIL_PAYLOAD_HEADER_BYTES)),
    STRIPPED_THUMBNAIL_JPEG_FOOTER,
  ])

  jpeg.writeUInt16BE(height, STRIPPED_THUMBNAIL_JPEG_HEIGHT_OFFSET)
  jpeg.writeUInt16BE(width, STRIPPED_THUMBNAIL_JPEG_WIDTH_OFFSET)

  return jpeg
}

function stripJpegHeader({
  jpeg,
  width,
  height,
}: {
  jpeg: Buffer
  width: number
  height: number
}): Buffer {
  if (jpeg.length <= STRIPPED_THUMBNAIL_JPEG_HEADER.length + STRIPPED_THUMBNAIL_JPEG_FOOTER.length) {
    throw new Error("JPEG thumbnail is too small to strip")
  }

  if (!jpeg.subarray(jpeg.length - STRIPPED_THUMBNAIL_JPEG_FOOTER.length).equals(STRIPPED_THUMBNAIL_JPEG_FOOTER)) {
    throw new Error("JPEG thumbnail footer does not match stripped thumbnail footer")
  }

  const actualHeader = Buffer.from(jpeg.subarray(0, STRIPPED_THUMBNAIL_JPEG_HEADER.length))
  actualHeader.writeUInt16BE(0, STRIPPED_THUMBNAIL_JPEG_HEIGHT_OFFSET)
  actualHeader.writeUInt16BE(0, STRIPPED_THUMBNAIL_JPEG_WIDTH_OFFSET)

  if (!actualHeader.equals(STRIPPED_THUMBNAIL_JPEG_HEADER)) {
    throw new Error(`JPEG thumbnail header does not match stripped thumbnail header for ${width}x${height}`)
  }

  return Buffer.from(jpeg.subarray(STRIPPED_THUMBNAIL_JPEG_HEADER.length, jpeg.length - 2))
}

