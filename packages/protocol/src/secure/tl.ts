import { MAX_PACKET_BYTES, concatBytes, int32LE, int64LE, readInt32LE, readInt64LE, uint32LE } from "./bytes.js"

export const TL_VECTOR_CONSTRUCTOR = 0x1cb5c415

export const encodeTlBytes = (value: Uint8Array): Uint8Array => {
  if (value.length > 0xffffff || value.length > MAX_PACKET_BYTES) throw new RangeError("TL bytes exceed the supported limit")
  const header = value.length < 254
    ? Uint8Array.of(value.length)
    : Uint8Array.of(254, value.length & 0xff, (value.length >>> 8) & 0xff, (value.length >>> 16) & 0xff)
  const padding = new Uint8Array((4 - ((header.length + value.length) % 4)) % 4)
  return concatBytes(header, value, padding)
}

export const encodeTlVector = (elements: readonly Uint8Array[]): Uint8Array => {
  if (elements.length > 8192) throw new RangeError("TL vector exceeds the supported limit")
  return concatBytes(uint32LE(TL_VECTOR_CONSTRUCTOR), int32LE(elements.length), ...elements)
}

export class TlReader {
  readonly #bytes: Uint8Array
  #offset = 0

  constructor(bytes: Uint8Array) {
    if (bytes.length > MAX_PACKET_BYTES) throw new RangeError("TL input exceeds the supported limit")
    this.#bytes = bytes
  }

  get remaining(): number { return this.#bytes.length - this.#offset }
  get offset(): number { return this.#offset }

  readInt(): number {
    this.#require(4)
    const value = readInt32LE(this.#bytes, this.#offset)
    this.#offset += 4
    return value
  }

  readLong(): bigint {
    this.#require(8)
    const value = readInt64LE(this.#bytes, this.#offset)
    this.#offset += 8
    return value
  }

  readFixed(length: number): Uint8Array {
    this.#require(length)
    const value = this.#bytes.slice(this.#offset, this.#offset + length)
    this.#offset += length
    return value
  }

  readBytes(): Uint8Array {
    this.#require(1)
    const first = this.#bytes[this.#offset]!
    const headerLength = first < 254 ? 1 : 4
    this.#require(headerLength)
    const length = first < 254
      ? first
      : this.#bytes[this.#offset + 1]! |
        (this.#bytes[this.#offset + 2]! << 8) |
        (this.#bytes[this.#offset + 3]! << 16)
    if (first === 255 || length > MAX_PACKET_BYTES) throw new RangeError("Invalid TL bytes length")
    const encodedLength = headerLength + length
    const paddingLength = (4 - (encodedLength % 4)) % 4
    this.#require(encodedLength + paddingLength)
    const start = this.#offset + headerLength
    const value = this.#bytes.slice(start, start + length)
    for (let index = start + length; index < start + length + paddingLength; index += 1) {
      if (this.#bytes[index] !== 0) throw new RangeError("TL bytes padding must be zero")
    }
    this.#offset += encodedLength + paddingLength
    return value
  }

  readVector<T>(readElement: (reader: TlReader) => T, maximum = 8192): T[] {
    const constructor = this.readInt() >>> 0
    if (constructor !== TL_VECTOR_CONSTRUCTOR) throw new RangeError("Invalid TL vector constructor")
    const count = this.readInt()
    if (count < 0 || count > maximum) throw new RangeError("Invalid TL vector count")
    return Array.from({ length: count }, () => readElement(this))
  }

  expectEnd(): void {
    if (this.remaining !== 0) throw new RangeError("Unexpected trailing TL data")
  }

  #require(length: number): void {
    if (!Number.isSafeInteger(length) || length < 0 || length > this.remaining) throw new RangeError("Truncated TL input")
  }
}

export { int32LE as encodeTlInt, int64LE as encodeTlLong }
