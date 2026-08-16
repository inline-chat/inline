export const MAX_PACKET_BYTES = 16 * 1024 * 1024

export const concatBytes = (...parts: readonly Uint8Array[]): Uint8Array => {
  const length = parts.reduce((sum, part) => sum + part.length, 0)
  const result = new Uint8Array(length)
  let offset = 0
  for (const part of parts) {
    result.set(part, offset)
    offset += part.length
  }
  return result
}

export const xorBytes = (left: Uint8Array, right: Uint8Array): Uint8Array => {
  if (left.length !== right.length) throw new RangeError("XOR inputs must have equal length")
  const result = new Uint8Array(left.length)
  for (let index = 0; index < result.length; index += 1) {
    result[index] = left[index]! ^ right[index]!
  }
  return result
}

export const equalBytes = (left: Uint8Array, right: Uint8Array): boolean => {
  let difference = left.length ^ right.length
  const length = Math.max(left.length, right.length)
  for (let index = 0; index < length; index += 1) {
    difference |= (left[index] ?? 0) ^ (right[index] ?? 0)
  }
  return difference === 0
}

export const reverseBytes = (bytes: Uint8Array): Uint8Array => Uint8Array.from(bytes).reverse()

export const int32LE = (value: number): Uint8Array => {
  const bytes = new Uint8Array(4)
  new DataView(bytes.buffer).setInt32(0, value, true)
  return bytes
}

export const uint32LE = (value: number): Uint8Array => {
  const bytes = new Uint8Array(4)
  new DataView(bytes.buffer).setUint32(0, value, true)
  return bytes
}

export const int64LE = (value: bigint): Uint8Array => {
  const bytes = new Uint8Array(8)
  new DataView(bytes.buffer).setBigInt64(0, value, true)
  return bytes
}

export const readInt32LE = (bytes: Uint8Array, offset: number): number =>
  new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getInt32(offset, true)

export const readInt64LE = (bytes: Uint8Array, offset: number): bigint =>
  new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getBigInt64(offset, true)

export const bytesToHex = (bytes: Uint8Array): string =>
  Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")

export const hexToBytes = (hex: string): Uint8Array => {
  if (hex.length % 2 !== 0 || !/^[0-9a-f]*$/i.test(hex)) throw new RangeError("Invalid hexadecimal bytes")
  return Uint8Array.from({ length: hex.length / 2 }, (_, index) =>
    Number.parseInt(hex.slice(index * 2, index * 2 + 2), 16),
  )
}
