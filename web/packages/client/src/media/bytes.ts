/** Small byte helpers with no dependency, so they run the same in a worker and in Node. */

export const toHex = (bytes: Uint8Array): string => {
  let out = ""
  for (const byte of bytes) out += byte.toString(16).padStart(2, "0")
  return out
}

export const fromHex = (hex: string): Uint8Array => {
  if (hex.length % 2 !== 0 || !/^[0-9a-f]*$/i.test(hex)) throw new TypeError("Invalid hex string")
  const out = new Uint8Array(hex.length / 2)
  for (let index = 0; index < out.length; index += 1) {
    out[index] = Number.parseInt(hex.slice(index * 2, index * 2 + 2), 16)
  }
  return out
}

export const toBase64 = (bytes: Uint8Array): string => {
  let binary = ""
  const chunk = 0x8000
  for (let offset = 0; offset < bytes.length; offset += chunk) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunk))
  }
  return btoa(binary)
}

export const fromBase64 = (value: string): Uint8Array => {
  const binary = atob(value)
  const out = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index += 1) out[index] = binary.charCodeAt(index)
  return out
}

export const bytesEqual = (left: Uint8Array, right: Uint8Array): boolean => {
  if (left.length !== right.length) return false
  for (let index = 0; index < left.length; index += 1) if (left[index] !== right[index]) return false
  return true
}

export const randomBytes = (length: number): Uint8Array => {
  const bytes = new Uint8Array(length)
  globalThis.crypto.getRandomValues(bytes)
  return bytes
}

/**
 * JSON for durable records that hold bytes and 64-bit integers (protobuf
 * results such as `UploadComplete`). Bytes become `{"$b": base64}` and bigints
 * `{"$n": decimal}`; nothing is coerced through a `number`.
 */
export const encodeRecord = (value: unknown): string =>
  JSON.stringify(value, function replacer(this: Record<string, unknown>, key: string, current: unknown) {
    const raw = this[key]
    if (raw instanceof Uint8Array) return { $b: toBase64(raw) }
    if (typeof raw === "bigint") return { $n: raw.toString() }
    return current
  })

export const decodeRecord = <T>(text: string): T =>
  JSON.parse(text, (_key, value: unknown) => {
    if (value && typeof value === "object" && !Array.isArray(value)) {
      const record = value as Record<string, unknown>
      const keys = Object.keys(record)
      if (keys.length === 1 && typeof record["$b"] === "string") return fromBase64(record["$b"])
      if (keys.length === 1 && typeof record["$n"] === "string") return BigInt(record["$n"])
    }
    return value
  }) as T

// SHA-256 (FIPS 180-4), incremental. Web Crypto has no streaming digest, and a
// 500 MB source must not be held in memory to hash it.
const K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
])

export class Sha256 {
  readonly #state = new Uint32Array([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ])
  readonly #block = new Uint8Array(64)
  readonly #words = new Uint32Array(64)
  #blockLength = 0
  #byteCount = 0
  #finished = false

  update(data: Uint8Array): this {
    if (this.#finished) throw new Error("Hash already finalized")
    let offset = 0
    this.#byteCount += data.length
    if (this.#blockLength > 0) {
      const take = Math.min(64 - this.#blockLength, data.length)
      this.#block.set(data.subarray(0, take), this.#blockLength)
      this.#blockLength += take
      offset = take
      if (this.#blockLength === 64) {
        this.#compress(this.#block, 0)
        this.#blockLength = 0
      }
    }
    while (offset + 64 <= data.length) {
      this.#compress(data, offset)
      offset += 64
    }
    if (offset < data.length) {
      this.#block.set(data.subarray(offset), 0)
      this.#blockLength = data.length - offset
    }
    return this
  }

  digest(): Uint8Array {
    if (this.#finished) throw new Error("Hash already finalized")
    this.#finished = true
    const bitLength = this.#byteCount * 8
    const block = this.#block
    block[this.#blockLength] = 0x80
    block.fill(0, this.#blockLength + 1)
    if (this.#blockLength + 1 > 56) {
      this.#compress(block, 0)
      block.fill(0)
    }
    const view = new DataView(block.buffer, block.byteOffset, 64)
    view.setUint32(56, Math.floor(bitLength / 0x1_0000_0000))
    view.setUint32(60, bitLength >>> 0)
    this.#compress(block, 0)
    const out = new Uint8Array(32)
    const outView = new DataView(out.buffer)
    for (let index = 0; index < 8; index += 1) outView.setUint32(index * 4, this.#state[index]!)
    return out
  }

  #compress(data: Uint8Array, offset: number): void {
    const w = this.#words
    for (let index = 0; index < 16; index += 1) {
      const at = offset + index * 4
      w[index] = ((data[at]! << 24) | (data[at + 1]! << 16) | (data[at + 2]! << 8) | data[at + 3]!) >>> 0
    }
    for (let index = 16; index < 64; index += 1) {
      const a = w[index - 15]!
      const b = w[index - 2]!
      const s0 = ((a >>> 7) | (a << 25)) ^ ((a >>> 18) | (a << 14)) ^ (a >>> 3)
      const s1 = ((b >>> 17) | (b << 15)) ^ ((b >>> 19) | (b << 13)) ^ (b >>> 10)
      w[index] = (w[index - 16]! + s0 + w[index - 7]! + s1) >>> 0
    }
    const s = this.#state
    let a = s[0]!, b = s[1]!, c = s[2]!, d = s[3]!, e = s[4]!, f = s[5]!, g = s[6]!, h = s[7]!
    for (let index = 0; index < 64; index += 1) {
      const s1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7))
      const ch = (e & f) ^ (~e & g)
      const t1 = (h + s1 + ch + K[index]! + w[index]!) >>> 0
      const s0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10))
      const maj = (a & b) ^ (a & c) ^ (b & c)
      const t2 = (s0 + maj) >>> 0
      h = g
      g = f
      f = e
      e = (d + t1) >>> 0
      d = c
      c = b
      b = a
      a = (t1 + t2) >>> 0
    }
    s[0] = (s[0]! + a) >>> 0
    s[1] = (s[1]! + b) >>> 0
    s[2] = (s[2]! + c) >>> 0
    s[3] = (s[3]! + d) >>> 0
    s[4] = (s[4]! + e) >>> 0
    s[5] = (s[5]! + f) >>> 0
    s[6] = (s[6]! + g) >>> 0
    s[7] = (s[7]! + h) >>> 0
  }
}

export const sha256 = (data: Uint8Array): Uint8Array => new Sha256().update(data).digest()
