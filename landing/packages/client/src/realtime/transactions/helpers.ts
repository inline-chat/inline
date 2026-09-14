import {
  messageId,
  type InlineID,
  type InlineIDKind,
  type MessageID,
} from "@inline/ids"

export const toBigInt = <K extends InlineIDKind>(
  value: InlineID<K> | number | bigint | undefined,
) => {
  if (value == null) return undefined
  return typeof value === "bigint" ? value : BigInt(value)
}

export const toNumber = (value: bigint | number | undefined) => {
  if (value == null) return undefined
  const number = typeof value === "bigint" ? Number(value) : value
  if (!Number.isSafeInteger(number)) {
    throw new RangeError(`Unsafe Inline numeric field: ${String(value)}`)
  }
  return number
}

const randomUint32 = () => {
  if (typeof crypto !== "undefined" && "getRandomValues" in crypto) {
    const buffer = new Uint32Array(1)
    crypto.getRandomValues(buffer)
    return buffer[0] ?? 0
  }
  return Math.floor(Math.random() * 2 ** 32)
}

export const positiveInt64FromUint32 = (high: number, low: number) => {
  const signedHigh = BigInt(high & 0x7fff_ffff)
  return (signedHigh << 32n) | BigInt(low >>> 0)
}

export const randomPositiveInt64 = () => {
  const high = randomUint32()
  const low = randomUint32()
  return positiveInt64FromUint32(high, low)
}

let tempIdCounter = 0
export const generateTempId = (): MessageID => {
  tempIdCounter = (tempIdCounter + 1) % 1000
  return messageId(-(Date.now() + tempIdCounter))
}
