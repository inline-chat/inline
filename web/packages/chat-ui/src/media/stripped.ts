/**
 * The stripped thumbnail (`PhotoSize` type `s`): a few hundred bytes that a
 * row carries so the first frame can paint a blurred placeholder before any
 * bytes arrive.
 *
 * Format, as the Apple clients read it (`InlineUI/InlineTinyThumbnailBackgroundView.swift`
 * `InlineTinyThumbnailDecoder`): byte 0 is the version (1), byte 1 the height,
 * byte 2 the width, and the rest is a JPEG body without its header and end
 * marker. The decoder prepends a fixed header, patches the height and width
 * into it and appends `FF D9`.
 *
 * The view makes an object URL from the result (`image/jpeg`) and draws it
 * blurred; the bytes are never parsed here beyond the version check.
 */

const headerBase64 =
  "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAAAAADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9o="

const HEIGHT_INDEX = 145
const WIDTH_INDEX = 147

const decodeBase64 = (value: string): Uint8Array => {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  const clean = value.replace(/=+$/, "")
  const out = new Uint8Array(Math.floor((clean.length * 3) / 4))
  let buffer = 0
  let bits = 0
  let index = 0
  for (const char of clean) {
    buffer = (buffer << 6) | alphabet.indexOf(char)
    bits += 6
    if (bits >= 8) {
      bits -= 8
      out[index++] = (buffer >> bits) & 0xff
    }
  }
  return out
}

let header: Uint8Array | undefined

/** Size in pixels the stripped bytes describe, or undefined when they are not version 1. */
export const strippedSize = (bytes: Uint8Array | undefined): { width: number; height: number } | undefined => {
  if (!(bytes instanceof Uint8Array) || bytes.length < 3 || bytes[0] !== 1) return undefined
  return { width: bytes[2] ?? 0, height: bytes[1] ?? 0 }
}

const built = new WeakMap<Uint8Array, Uint8Array | null>()

/**
 * A complete JPEG from stripped thumbnail bytes, or undefined when they are
 * not version 1 or too short. Pure; never throws. The same input object gives
 * the same output object, so views can compare by identity. Do not mutate it.
 */
export const strippedJpeg = (bytes: Uint8Array | undefined): Uint8Array | undefined => {
  if (!(bytes instanceof Uint8Array)) return undefined
  const cached = built.get(bytes)
  if (cached !== undefined) return cached ?? undefined
  const result = buildJpeg(bytes)
  built.set(bytes, result ?? null)
  return result
}

const buildJpeg = (bytes: Uint8Array): Uint8Array | undefined => {
  const size = strippedSize(bytes)
  if (!size) return undefined
  header ??= decodeBase64(headerBase64)
  const body = bytes.subarray(3)
  const out = new Uint8Array(header.length + body.length + 2)
  out.set(header, 0)
  out.set(body, header.length)
  out[out.length - 2] = 0xff
  out[out.length - 1] = 0xd9
  if (out.length <= WIDTH_INDEX + 1) return undefined
  out[HEIGHT_INDEX] = (size.height >> 8) & 0xff
  out[HEIGHT_INDEX + 1] = size.height & 0xff
  out[WIDTH_INDEX] = (size.width >> 8) & 0xff
  out[WIDTH_INDEX + 1] = size.width & 0xff
  return out
}
