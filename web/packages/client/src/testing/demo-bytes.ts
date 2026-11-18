/**
 * Deterministic file bytes for the demo server, made on demand in the
 * worker: no canvas, no network, no bundled assets.
 *
 * - `demoPng(seed, width, height)`: a picture (a two-color gradient at a
 *   seeded angle with a soft disc) as an 8-bit palette PNG with stored
 *   (uncompressed) deflate blocks. Its byte length depends on the size only
 *   (`demoPngSize`), so a message can declare it without making the bytes,
 *   and the media core's auto-download limits (which need a size) apply.
 * - `demoStripped(seed, width, height)`: the same picture as a stripped
 *   thumbnail (`PhotoSize` type `s`): version 1, height, width, then a JPEG
 *   body for the fixed header the clients prepend (quality 20 tables,
 *   standard Huffman tables, 4:2:0). Ported from the content lab's encoder.
 * - `demoWav`: a voice note (8 kHz, 16-bit mono PCM); `demoText`: an ASCII
 *   document of an exact length; `demoNoise`: any range of a seeded stream.
 * - `imageDimensions`: width and height of an uploaded PNG or JPEG.
 */

// ---- Checksums ----------------------------------------------------------------

const CRC_TABLE = (() => {
  const table = new Uint32Array(256)
  for (let n = 0; n < 256; n += 1) {
    let c = n
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    table[n] = c >>> 0
  }
  return table
})()

const crc32 = (bytes: Uint8Array, start: number, end: number) => {
  let crc = 0xffffffff
  for (let index = start; index < end; index += 1) {
    crc = (CRC_TABLE[(crc ^ bytes[index]!) & 0xff]! ^ (crc >>> 8)) >>> 0
  }
  return (crc ^ 0xffffffff) >>> 0
}

/** A 32-bit seed from integers. */
export const mixSeed = (...values: number[]) => {
  let hash = 0x811c9dc5
  for (const value of values) {
    hash = Math.imul(hash ^ (value >>> 0), 0x01000193) >>> 0
    hash = Math.imul(hash ^ Math.floor(value / 0x1_0000_0000), 0x01000193) >>> 0
    hash ^= hash >>> 15
  }
  return hash >>> 0
}

/** Small deterministic generator (mulberry32). */
const generator = (seed: number) => {
  let state = seed >>> 0
  return () => {
    state = (state + 0x6d2b79f5) >>> 0
    let t = state
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4_294_967_296
  }
}

// ---- Pictures -------------------------------------------------------------------

type Rgb = [number, number, number]

/** HSL to RGB, h in turns. */
const hsl = (h: number, s: number, l: number): Rgb => {
  const k = (n: number) => (n + h * 12) % 12
  const a = s * Math.min(l, 1 - l)
  const f = (n: number) => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)))
  return [Math.round(f(0) * 255), Math.round(f(8) * 255), Math.round(f(4) * 255)]
}

const GRADIENT_STEPS = 192
const DISC_STEPS = 64

type Picture = {
  palette: Rgb[]
  /** Palette index of a point in unit coordinates (0 to 1 on each axis). */
  index(u: number, v: number): number
}

const picture = (seed: number, aspect: number): Picture => {
  const random = generator(seed)
  const hue = random()
  const from = hsl(hue, 0.55 + random() * 0.3, 0.35 + random() * 0.2)
  const to = hsl((hue + 0.15 + random() * 0.35) % 1, 0.5 + random() * 0.4, 0.6 + random() * 0.2)
  const discColor = hsl((hue + 0.5) % 1, 0.7, 0.75)
  const angle = random() * Math.PI * 2
  const dx = Math.cos(angle)
  const dy = Math.sin(angle)
  const cx = 0.2 + random() * 0.6
  const cy = 0.2 + random() * 0.6
  const radius = 0.12 + random() * 0.18
  const palette: Rgb[] = []
  const blend = (a: Rgb, b: Rgb, t: number): Rgb => [
    Math.round(a[0] + (b[0] - a[0]) * t),
    Math.round(a[1] + (b[1] - a[1]) * t),
    Math.round(a[2] + (b[2] - a[2]) * t),
  ]
  for (let step = 0; step < GRADIENT_STEPS; step += 1) palette.push(blend(from, to, step / (GRADIENT_STEPS - 1)))
  for (let step = 0; step < DISC_STEPS; step += 1) palette.push(blend(discColor, to, step / (DISC_STEPS - 1)))
  // Distances in a square frame, so the disc stays round at any aspect.
  const sx = aspect >= 1 ? 1 : aspect
  const sy = aspect >= 1 ? 1 / aspect : 1
  const span = Math.abs(dx) + Math.abs(dy)
  return {
    palette,
    index(u, v) {
      const ddx = (u - cx) / sy
      const ddy = (v - cy) / sx
      const distance = Math.sqrt(ddx * ddx + ddy * ddy)
      if (distance < radius) return GRADIENT_STEPS + Math.min(DISC_STEPS - 1, Math.floor((distance / radius) * DISC_STEPS))
      const t = ((u - 0.5) * dx + (v - 0.5) * dy) / span + 0.5
      return Math.max(0, Math.min(GRADIENT_STEPS - 1, Math.floor(t * GRADIENT_STEPS)))
    },
  }
}

const STORED_BLOCK = 65_535

const pngLayout = (width: number, height: number) => {
  const raw = height * (1 + width)
  const blocks = Math.max(1, Math.ceil(raw / STORED_BLOCK))
  const zlib = 2 + raw + blocks * 5 + 4
  const palette = (GRADIENT_STEPS + DISC_STEPS) * 3
  // Signature, IHDR, PLTE, IDAT, IEND.
  const size = 8 + (12 + 13) + (12 + palette) + (12 + zlib) + 12
  return { raw, blocks, zlib, palette, size }
}

/** The byte length of `demoPng(_, width, height)`. */
export const demoPngSize = (width: number, height: number) => pngLayout(width, height).size

/** A deterministic picture as an 8-bit palette PNG with stored deflate blocks. */
export const demoPng = (seed: number, width: number, height: number): Uint8Array => {
  if (!(width >= 1 && height >= 1 && width <= 4_096 && height <= 4_096)) throw new RangeError("demo picture size")
  const layout = pngLayout(width, height)
  const out = new Uint8Array(layout.size)
  const view = new DataView(out.buffer)
  let at = 0
  const bytes = (values: ArrayLike<number>) => {
    out.set(values, at)
    at += values.length
  }
  const u32 = (value: number) => {
    view.setUint32(at, value >>> 0)
    at += 4
  }
  const chunk = (type: string, length: number, write: () => void) => {
    u32(length)
    const start = at
    for (let index = 0; index < 4; index += 1) out[at++] = type.charCodeAt(index)
    write()
    u32(crc32(out, start, at))
  }
  bytes([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  chunk("IHDR", 13, () => {
    u32(width)
    u32(height)
    // 8-bit, palette, deflate, filter method 0, no interlace.
    bytes([8, 3, 0, 0, 0])
  })
  const art = picture(seed, width / height)
  chunk("PLTE", layout.palette, () => {
    for (const color of art.palette) bytes(color)
  })
  chunk("IDAT", layout.zlib, () => {
    const zlibStart = at
    bytes([0x78, 0x01])
    // Rows (filter byte 0, then indices), cut into stored blocks.
    const row = new Uint8Array(1 + width)
    let a = 1
    let b = 0
    let inBlock = 0
    let written = 0
    const startBlock = () => {
      const length = Math.min(STORED_BLOCK, layout.raw - written)
      const final = written + length >= layout.raw ? 1 : 0
      out[at++] = final
      out[at++] = length & 0xff
      out[at++] = (length >> 8) & 0xff
      out[at++] = ~length & 0xff
      out[at++] = (~length >> 8) & 0xff
      inBlock = length
    }
    startBlock()
    for (let y = 0; y < height; y += 1) {
      row[0] = 0
      const v = (y + 0.5) / height
      for (let x = 0; x < width; x += 1) row[x + 1] = art.index((x + 0.5) / width, v)
      for (let index = 0; index < row.length; index += 1) {
        if (inBlock === 0) startBlock()
        const value = row[index]!
        out[at++] = value
        a = (a + value) % 65_521
        b = (b + a) % 65_521
        inBlock -= 1
        written += 1
      }
    }
    u32(((b << 16) | a) >>> 0)
    if (at - zlibStart !== layout.zlib) throw new Error("demo PNG layout mismatch")
  })
  chunk("IEND", 0, () => undefined)
  return out
}

/** RGBA pixels of the same picture, for small sizes (previews, avatars). */
const pictureRgba = (seed: number, width: number, height: number, aspect: number) => {
  const art = picture(seed, aspect)
  const rgba = new Uint8ClampedArray(width * height * 4)
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const color = art.palette[art.index((x + 0.5) / width, (y + 0.5) / height)]!
      const at = (y * width + x) * 4
      rgba[at] = color[0]
      rgba[at + 1] = color[1]
      rgba[at + 2] = color[2]
      rgba[at + 3] = 255
    }
  }
  return rgba
}

// ---- Stripped thumbnails ----------------------------------------------------------

/** The fixed JPEG header clients prepend to stripped bytes (`InlineTinyThumbnailDecoder`). */
const STRIPPED_HEADER =
  "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAAAAADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9o="

const BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

const fromBase64 = (value: string): Uint8Array => {
  const clean = value.replace(/=+$/, "")
  const out = new Uint8Array(Math.floor((clean.length * 3) / 4))
  let buffer = 0
  let bits = 0
  let index = 0
  for (const char of clean) {
    buffer = (buffer << 6) | BASE64.indexOf(char)
    bits += 6
    if (bits >= 8) {
      bits -= 8
      out[index++] = (buffer >> bits) & 0xff
    }
  }
  return out
}

export const toBase64 = (bytes: Uint8Array): string => {
  let out = ""
  for (let index = 0; index < bytes.length; index += 3) {
    const a = bytes[index]!
    const b = bytes[index + 1]
    const c = bytes[index + 2]
    out += BASE64[a >> 2]
    out += BASE64[((a & 3) << 4) | ((b ?? 0) >> 4)]
    out += b === undefined ? "=" : BASE64[((b & 15) << 2) | ((c ?? 0) >> 6)]
    out += c === undefined ? "=" : BASE64[c & 63]
  }
  return out
}

type Huffman = Map<number, { code: number; length: number }>

type JpegTables = { quant: [number[], number[]]; dc: [Huffman, Huffman]; ac: [Huffman, Huffman] }

let jpegTables: JpegTables | undefined

const readJpegTables = (): JpegTables => {
  const header = fromBase64(STRIPPED_HEADER)
  const quant: number[][] = []
  const huffman = new Map<number, Huffman>()
  let index = 2
  while (index < header.length - 1) {
    const marker = header[index + 1] ?? 0
    if (header[index] !== 0xff || marker === 0xda) break
    const length = ((header[index + 2] ?? 0) << 8) | (header[index + 3] ?? 0)
    const segment = header.subarray(index + 4, index + 2 + length)
    if (marker === 0xdb) {
      for (let at = 0; at < segment.length; at += 65) {
        quant[(segment[at] ?? 0) & 0x0f] = Array.from(segment.subarray(at + 1, at + 65))
      }
    } else if (marker === 0xc4) {
      let at = 0
      while (at < segment.length) {
        const id = segment[at] ?? 0
        const counts = Array.from(segment.subarray(at + 1, at + 17))
        const total = counts.reduce((sum, count) => sum + count, 0)
        const values = segment.subarray(at + 17, at + 17 + total)
        const codes: Huffman = new Map()
        let code = 0
        let k = 0
        for (let length = 1; length <= 16; length += 1) {
          for (let n = 0; n < (counts[length - 1] ?? 0); n += 1) {
            codes.set(values[k] ?? 0, { code, length })
            code += 1
            k += 1
          }
          code <<= 1
        }
        huffman.set(id, codes)
        at += 17 + total
      }
    }
    index += 2 + length
  }
  const table = (id: number) => {
    const found = huffman.get(id)
    if (!found) throw new Error(`stripped header: no Huffman table ${id}`)
    return found
  }
  return {
    quant: [quant[0] ?? [], quant[1] ?? []],
    dc: [table(0x00), table(0x01)],
    ac: [table(0x10), table(0x11)],
  }
}

const ZIGZAG = [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42,
  49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
]

/** c(u) cos((2x + 1) u π / 16) / 2, indexed [u * 8 + x]: the separable 8-point DCT basis. */
const DCT_BASIS = (() => {
  const basis = new Float64Array(64)
  for (let u = 0; u < 8; u += 1) {
    for (let x = 0; x < 8; x += 1) {
      basis[u * 8 + x] = (u === 0 ? Math.SQRT1_2 : 1) * 0.5 * Math.cos(((2 * x + 1) * u * Math.PI) / 16)
    }
  }
  return basis
})()

const fdct = (block: Float64Array, out: Float64Array, scratch: Float64Array) => {
  for (let y = 0; y < 8; y += 1) {
    for (let u = 0; u < 8; u += 1) {
      let sum = 0
      for (let x = 0; x < 8; x += 1) sum += block[y * 8 + x]! * DCT_BASIS[u * 8 + x]!
      scratch[y * 8 + u] = sum
    }
  }
  for (let u = 0; u < 8; u += 1) {
    for (let v = 0; v < 8; v += 1) {
      let sum = 0
      for (let y = 0; y < 8; y += 1) sum += scratch[y * 8 + u]! * DCT_BASIS[v * 8 + y]!
      out[v * 8 + u] = sum
    }
  }
}

class BitWriter {
  readonly bytes: number[] = []
  private buffer = 0
  private count = 0

  write(value: number, length: number) {
    for (let bit = length - 1; bit >= 0; bit -= 1) {
      this.buffer = (this.buffer << 1) | ((value >> bit) & 1)
      this.count += 1
      if (this.count === 8) {
        this.bytes.push(this.buffer)
        if (this.buffer === 0xff) this.bytes.push(0)
        this.buffer = 0
        this.count = 0
      }
    }
  }

  finish() {
    while (this.count !== 0) this.write(1, 1)
  }
}

const category = (value: number) => {
  let magnitude = Math.abs(value)
  let bits = 0
  while (magnitude > 0) {
    bits += 1
    magnitude >>= 1
  }
  return bits
}

const emit = (writer: BitWriter, table: Huffman, symbol: number) => {
  const entry = table.get(symbol)
  if (!entry) throw new Error(`stripped encoder: no code for ${symbol}`)
  writer.write(entry.code, entry.length)
}

const encodeBlock = (
  writer: BitWriter,
  block: Float64Array,
  quant: number[],
  dc: Huffman,
  ac: Huffman,
  previousDc: number,
  buffers: { coefficients: Float64Array; scratch: Float64Array },
) => {
  fdct(block, buffers.coefficients, buffers.scratch)
  const quantized = ZIGZAG.map((natural, k) => Math.round(buffers.coefficients[natural]! / (quant[k] ?? 1)))
  const dcValue = quantized[0] ?? 0
  const diff = dcValue - previousDc
  const dcSize = category(diff)
  emit(writer, dc, dcSize)
  if (dcSize > 0) writer.write(diff < 0 ? diff + (1 << dcSize) - 1 : diff, dcSize)
  let run = 0
  for (let k = 1; k < 64; k += 1) {
    const value = quantized[k] ?? 0
    if (value === 0) {
      run += 1
      continue
    }
    while (run > 15) {
      emit(writer, ac, 0xf0)
      run -= 16
    }
    const size = category(value)
    emit(writer, ac, (run << 4) | size)
    writer.write(value < 0 ? value + (1 << size) - 1 : value, size)
    run = 0
  }
  if (run > 0) emit(writer, ac, 0x00)
  return dcValue
}

/** Stripped thumbnail bytes for RGBA pixels (each side 1 to 255). */
export const encodeStripped = (rgba: Uint8ClampedArray, width: number, height: number): Uint8Array => {
  jpegTables ??= readJpegTables()
  const tables = jpegTables
  const yuv = new Float64Array(width * height * 3)
  for (let index = 0; index < width * height; index += 1) {
    const r = rgba[index * 4]!
    const g = rgba[index * 4 + 1]!
    const b = rgba[index * 4 + 2]!
    yuv[index * 3] = 0.299 * r + 0.587 * g + 0.114 * b
    yuv[index * 3 + 1] = -0.168736 * r - 0.331264 * g + 0.5 * b + 128
    yuv[index * 3 + 2] = 0.5 * r - 0.418688 * g - 0.081312 * b + 128
  }
  const sample = (x: number, y: number, channel: number) =>
    yuv[(Math.min(height - 1, Math.max(0, y)) * width + Math.min(width - 1, Math.max(0, x))) * 3 + channel]!
  const writer = new BitWriter()
  const predictors = [0, 0, 0]
  const block = new Float64Array(64)
  const buffers = { coefficients: new Float64Array(64), scratch: new Float64Array(64) }
  for (let my = 0; my < height; my += 16) {
    for (let mx = 0; mx < width; mx += 16) {
      for (const [ox, oy] of [
        [0, 0],
        [8, 0],
        [0, 8],
        [8, 8],
      ] as const) {
        for (let y = 0; y < 8; y += 1) for (let x = 0; x < 8; x += 1) block[y * 8 + x] = sample(mx + ox + x, my + oy + y, 0) - 128
        predictors[0] = encodeBlock(writer, block, tables.quant[0], tables.dc[0], tables.ac[0], predictors[0]!, buffers)
      }
      for (const channel of [1, 2]) {
        for (let y = 0; y < 8; y += 1) {
          for (let x = 0; x < 8; x += 1) {
            const sx = mx + x * 2
            const sy = my + y * 2
            const sum =
              sample(sx, sy, channel) + sample(sx + 1, sy, channel) + sample(sx, sy + 1, channel) + sample(sx + 1, sy + 1, channel)
            block[y * 8 + x] = sum / 4 - 128
          }
        }
        predictors[channel] = encodeBlock(writer, block, tables.quant[1], tables.dc[1], tables.ac[1], predictors[channel]!, buffers)
      }
    }
  }
  writer.finish()
  const sos = [0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3f, 0x00]
  const out = new Uint8Array(3 + sos.length + writer.bytes.length)
  out.set([1, height, width], 0)
  out.set(sos, 3)
  out.set(writer.bytes, 3 + sos.length)
  return out
}

/** The picture `demoPng(seed, …)` draws, at most 40 px on its long side, as stripped bytes. */
export const demoStripped = (seed: number, width: number, height: number): Uint8Array => {
  const scale = Math.min(1, 40 / Math.max(width, height))
  const w = Math.max(1, Math.round(width * scale))
  const h = Math.max(1, Math.round(height * scale))
  return encodeStripped(pictureRgba(seed, w, h, width / height), w, h)
}

/** A small square PNG as a `data:` URL (an avatar). */
export const demoAvatarDataUrl = (seed: number, size = 24): string =>
  `data:image/png;base64,${toBase64(demoPng(seed, size, size))}`

// ---- Sound, text, noise -----------------------------------------------------------

const WAV_RATE = 8_000

export const demoWavSize = (seconds: number) => 44 + Math.max(1, Math.round(seconds)) * WAV_RATE * 2

/** A voice note: a few seeded tones with a soft envelope, 8 kHz 16-bit mono WAV. */
export const demoWav = (seed: number, seconds: number): Uint8Array => {
  const samples = Math.max(1, Math.round(seconds)) * WAV_RATE
  const out = new Uint8Array(44 + samples * 2)
  const view = new DataView(out.buffer)
  const ascii = (at: number, text: string) => {
    for (let index = 0; index < text.length; index += 1) out[at + index] = text.charCodeAt(index)
  }
  ascii(0, "RIFF")
  view.setUint32(4, 36 + samples * 2, true)
  ascii(8, "WAVE")
  ascii(12, "fmt ")
  view.setUint32(16, 16, true)
  view.setUint16(20, 1, true)
  view.setUint16(22, 1, true)
  view.setUint32(24, WAV_RATE, true)
  view.setUint32(28, WAV_RATE * 2, true)
  view.setUint16(32, 2, true)
  view.setUint16(34, 16, true)
  ascii(36, "data")
  view.setUint32(40, samples * 2, true)
  const random = generator(seed)
  const syllable = Math.floor(WAV_RATE * (0.18 + random() * 0.1))
  let frequency = 140 + random() * 120
  let phase = 0
  for (let index = 0; index < samples; index += 1) {
    const position = index % syllable
    if (position === 0) frequency = 120 + random() * 180
    const envelope = Math.sin((Math.PI * position) / syllable)
    phase += (2 * Math.PI * frequency) / WAV_RATE
    const value = Math.round(envelope * 9_000 * (Math.sin(phase) + 0.3 * Math.sin(phase * 2.01)))
    view.setInt16(44 + index * 2, Math.max(-32_768, Math.min(32_767, value)), true)
  }
  return out
}

/** Waveform samples (0 to 255) for a voice note's bars. */
export const demoWaveform = (seed: number, count = 64): Uint8Array => {
  const random = generator(seed ^ 0x5a5a5a5a)
  const out = new Uint8Array(count)
  for (let index = 0; index < count; index += 1) out[index] = Math.floor(40 + random() * 215)
  return out
}

const WORDS = [
  "release", "notes", "review", "latency", "budget", "deploy", "customer", "design", "migration", "draft",
  "agreed", "metrics", "rollout", "owner", "status", "blocked", "shipped", "follow-up", "decision", "risk",
]

/** An ASCII document of exactly `size` bytes: lines of seeded words (CSV for `.csv`). */
export const demoText = (seed: number, size: number, csv = false): Uint8Array => {
  const out = new Uint8Array(Math.max(0, size))
  const random = generator(seed)
  let at = 0
  let line = 0
  const push = (text: string) => {
    for (let index = 0; index < text.length && at < out.length; index += 1) out[at++] = text.charCodeAt(index)
  }
  if (csv) push("id,owner,status,estimate\n")
  while (at < out.length) {
    line += 1
    if (csv) {
      push(`${line},${WORDS[Math.floor(random() * WORDS.length)]},${WORDS[Math.floor(random() * WORDS.length)]},${Math.floor(random() * 40)}\n`)
    } else {
      const count = 6 + Math.floor(random() * 10)
      const words = Array.from({ length: count }, () => WORDS[Math.floor(random() * WORDS.length)]!)
      push(`${line === 1 ? "# " : ""}${words.join(" ")}\n`)
    }
  }
  return out
}

/** Bytes `offset` to `offset + length` of a seeded stream (any range, no state). */
export const demoNoise = (seed: number, offset: number, length: number): Uint8Array => {
  const out = new Uint8Array(length)
  for (let index = 0; index < length; index += 1) {
    const position = offset + index
    let hash = Math.imul((seed ^ Math.floor(position / 4)) >>> 0, 0x9e3779b1) >>> 0
    hash ^= hash >>> 16
    hash = Math.imul(hash, 0x85ebca6b) >>> 0
    hash ^= hash >>> 13
    out[index] = (hash >>> ((position % 4) * 8)) & 0xff
  }
  return out
}

// ---- Uploaded images ----------------------------------------------------------------

/** Width and height of a PNG or baseline/progressive JPEG, or undefined. */
export const imageDimensions = (bytes: Uint8Array): { width: number; height: number } | undefined => {
  if (bytes.length >= 24 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
    return { width: view.getUint32(16), height: view.getUint32(20) }
  }
  if (bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    let at = 2
    while (at + 9 < bytes.length) {
      if (bytes[at] !== 0xff) return undefined
      const marker = bytes[at + 1]!
      const length = (bytes[at + 2]! << 8) | bytes[at + 3]!
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
        return { height: (bytes[at + 5]! << 8) | bytes[at + 6]!, width: (bytes[at + 7]! << 8) | bytes[at + 8]! }
      }
      at += 2 + length
    }
  }
  return undefined
}
