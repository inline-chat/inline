const JPEG_HEADER_BASE64 =
  "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAAAAADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9o="

const HEIGHT_BYTE_INDEX = 145
const WIDTH_BYTE_INDEX = 147
const JPEG_FOOTER = new Uint8Array([0xff, 0xd9])
const dataUrlCache = new WeakMap<Uint8Array, string | undefined>()

const decodeBase64 = (value: string) => {
  const binary = atob(value)
  return Uint8Array.from(binary, (character) => character.charCodeAt(0))
}

const encodeBase64 = (value: Uint8Array) => {
  const chunkSize = 0x8000
  let binary = ""
  for (let offset = 0; offset < value.length; offset += chunkSize) {
    const chunk = value.subarray(offset, offset + chunkSize)
    binary += String.fromCharCode(...chunk)
  }
  return btoa(binary)
}

const JPEG_HEADER = decodeBase64(JPEG_HEADER_BASE64)

/** Mirrors InlineTinyThumbnailDecoder in InlineUI. */
export const decodeInlineTinyThumbnailJPEG = (
  strippedBytes?: Uint8Array,
) => {
  if (
    !strippedBytes ||
    strippedBytes.length < 3 ||
    strippedBytes[0] !== 1
  ) {
    return undefined
  }

  const scan = strippedBytes.subarray(3)
  const result = new Uint8Array(
    JPEG_HEADER.length + scan.length + JPEG_FOOTER.length,
  )
  result.set(JPEG_HEADER)
  result.set(scan, JPEG_HEADER.length)
  result.set(JPEG_FOOTER, JPEG_HEADER.length + scan.length)
  if (result.length <= WIDTH_BYTE_INDEX + 1) return undefined

  const height = strippedBytes[1] ?? 0
  const width = strippedBytes[2] ?? 0
  result[HEIGHT_BYTE_INDEX] = 0
  result[HEIGHT_BYTE_INDEX + 1] = height
  result[WIDTH_BYTE_INDEX] = 0
  result[WIDTH_BYTE_INDEX + 1] = width
  return result
}

export const inlineTinyThumbnailDataUrl = (
  strippedBytes?: Uint8Array,
) => {
  if (!strippedBytes) return undefined
  if (dataUrlCache.has(strippedBytes)) {
    return dataUrlCache.get(strippedBytes)
  }
  const jpeg = decodeInlineTinyThumbnailJPEG(strippedBytes)
  const dataUrl = jpeg
    ? `data:image/jpeg;base64,${encodeBase64(jpeg)}`
    : undefined
  dataUrlCache.set(strippedBytes, dataUrl)
  return dataUrl
}
