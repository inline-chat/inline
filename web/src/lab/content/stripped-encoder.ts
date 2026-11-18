/**
 * Lab only: makes real stripped thumbnails (`PhotoSize` type `s`) from pixels,
 * so the lab's blurred previews go through `strippedJpeg` exactly as server
 * thumbnails do. The stripped format is a JPEG body for a fixed header
 * (quality 20 tables, standard Huffman tables, 4:2:0); this is a small
 * baseline encoder that reads those tables from the header itself.
 *
 * Output: `[1, height, width, ...SOS segment and scan data]`, without the
 * header (it starts after the header's final `FF DA`) and without `FF D9`.
 */

import { strippedJpeg } from "@inline/chat-ui"

type Huffman = { codes: Map<number, { code: number; length: number }> }

type Tables = {
  quant: [number[], number[]]
  dc: [Huffman, Huffman]
  ac: [Huffman, Huffman]
}

const zigzag = [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42,
  49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
]

let tables: Tables | undefined

/** The header `strippedJpeg` prepends, read back by building a one-byte body. */
const readTables = (): Tables => {
  const jpeg = strippedJpeg(new Uint8Array([1, 1, 1, 0]))
  if (!jpeg) throw new Error("strippedJpeg refused the probe")
  const quant: number[][] = []
  const huffman = new Map<number, Huffman>()
  let index = 2
  while (index < jpeg.length - 1) {
    if (jpeg[index] !== 0xff) throw new Error(`bad marker at ${index}`)
    const marker = jpeg[index + 1] ?? 0
    if (marker === 0xda) break
    const length = ((jpeg[index + 2] ?? 0) << 8) | (jpeg[index + 3] ?? 0)
    const segment = jpeg.subarray(index + 4, index + 2 + length)
    if (marker === 0xdb) {
      let at = 0
      while (at < segment.length) {
        const id = (segment[at] ?? 0) & 0x0f
        quant[id] = Array.from(segment.subarray(at + 1, at + 65))
        at += 65
      }
    } else if (marker === 0xc4) {
      let at = 0
      while (at < segment.length) {
        const id = segment[at] ?? 0
        const counts = Array.from(segment.subarray(at + 1, at + 17))
        const total = counts.reduce((sum, count) => sum + count, 0)
        const values = segment.subarray(at + 17, at + 17 + total)
        const codes = new Map<number, { code: number; length: number }>()
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
        huffman.set(id, { codes })
        at += 17 + total
      }
    }
    index += 2 + length
  }
  const table = (id: number): Huffman => {
    const found = huffman.get(id)
    if (!found) throw new Error(`missing Huffman table ${id}`)
    return found
  }
  return {
    quant: [quant[0] ?? [], quant[1] ?? []],
    dc: [table(0x00), table(0x01)],
    ac: [table(0x10), table(0x11)],
  }
}

class BitWriter {
  readonly bytes: number[] = []
  #buffer = 0
  #count = 0

  write(value: number, length: number): void {
    for (let bit = length - 1; bit >= 0; bit -= 1) {
      this.#buffer = (this.#buffer << 1) | ((value >> bit) & 1)
      this.#count += 1
      if (this.#count === 8) this.#flushByte()
    }
  }

  finish(): void {
    while (this.#count !== 0) this.write(1, 1)
  }

  #flushByte(): void {
    this.bytes.push(this.#buffer)
    if (this.#buffer === 0xff) this.bytes.push(0)
    this.#buffer = 0
    this.#count = 0
  }
}

const cosines = Array.from({ length: 8 }, (_, x) => Array.from({ length: 8 }, (_, u) => Math.cos(((2 * x + 1) * u * Math.PI) / 16)))

const fdct = (block: number[]): number[] => {
  const out: number[] = Array.from({ length: 64 }, () => 0)
  for (let v = 0; v < 8; v += 1) {
    for (let u = 0; u < 8; u += 1) {
      let sum = 0
      for (let y = 0; y < 8; y += 1) {
        for (let x = 0; x < 8; x += 1) sum += (block[y * 8 + x] ?? 0) * (cosines[x]?.[u] ?? 0) * (cosines[y]?.[v] ?? 0)
      }
      const cu = u === 0 ? Math.SQRT1_2 : 1
      const cv = v === 0 ? Math.SQRT1_2 : 1
      out[v * 8 + u] = 0.25 * cu * cv * sum
    }
  }
  return out
}

const category = (value: number): number => {
  let magnitude = Math.abs(value)
  let bits = 0
  while (magnitude > 0) {
    bits += 1
    magnitude >>= 1
  }
  return bits
}

const emit = (writer: BitWriter, table: Huffman, symbol: number): void => {
  const entry = table.codes.get(symbol)
  if (!entry) throw new Error(`no code for ${symbol}`)
  writer.write(entry.code, entry.length)
}

const encodeBlock = (writer: BitWriter, block: number[], quant: number[], dc: Huffman, ac: Huffman, previousDc: number): number => {
  const coefficients = fdct(block)
  const quantized = zigzag.map((natural, k) => Math.round((coefficients[natural] ?? 0) / (quant[k] ?? 1)))
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

/** Stripped thumbnail bytes for RGBA pixels (width and height at most 255). */
export const encodeStripped = (rgba: Uint8ClampedArray, width: number, height: number): Uint8Array => {
  tables ??= readTables()
  const t = tables
  const sample = (x: number, y: number) => {
    const cx = Math.min(width - 1, Math.max(0, x))
    const cy = Math.min(height - 1, Math.max(0, y))
    const at = (cy * width + cx) * 4
    const r = rgba[at] ?? 0
    const g = rgba[at + 1] ?? 0
    const b = rgba[at + 2] ?? 0
    return {
      y: 0.299 * r + 0.587 * g + 0.114 * b,
      cb: -0.168736 * r - 0.331264 * g + 0.5 * b + 128,
      cr: 0.5 * r - 0.418688 * g - 0.081312 * b + 128,
    }
  }
  const writer = new BitWriter()
  const predictors = [0, 0, 0]
  for (let my = 0; my < height; my += 16) {
    for (let mx = 0; mx < width; mx += 16) {
      for (const [ox, oy] of [
        [0, 0],
        [8, 0],
        [0, 8],
        [8, 8],
      ] as const) {
        const block: number[] = []
        for (let y = 0; y < 8; y += 1) for (let x = 0; x < 8; x += 1) block.push(sample(mx + ox + x, my + oy + y).y - 128)
        predictors[0] = encodeBlock(writer, block, t.quant[0], t.dc[0], t.ac[0], predictors[0] ?? 0)
      }
      for (const channel of ["cb", "cr"] as const) {
        const block: number[] = []
        for (let y = 0; y < 8; y += 1) {
          for (let x = 0; x < 8; x += 1) {
            let sum = 0
            for (const [dx, dy] of [
              [0, 0],
              [1, 0],
              [0, 1],
              [1, 1],
            ] as const) {
              sum += sample(mx + x * 2 + dx, my + y * 2 + dy)[channel]
            }
            block.push(sum / 4 - 128)
          }
        }
        const component = channel === "cb" ? 1 : 2
        predictors[component] = encodeBlock(writer, block, t.quant[1], t.dc[1], t.ac[1], predictors[component] ?? 0)
      }
    }
  }
  writer.finish()
  const sos = [0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3f, 0x00]
  return new Uint8Array([1, height, width, ...sos, ...writer.bytes])
}
