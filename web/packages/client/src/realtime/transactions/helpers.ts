export const toBigInt = (value: number | bigint | undefined) => {
  if (value == null) return undefined
  return typeof value === "bigint" ? value : BigInt(value)
}

export const toNumber = (value: bigint | number | undefined) => {
  if (value == null) return undefined
  return typeof value === "bigint" ? Number(value) : value
}

const randomUint32 = () => {
  if (typeof crypto !== "undefined" && "getRandomValues" in crypto) {
    const buffer = new Uint32Array(1)
    crypto.getRandomValues(buffer)
    return buffer[0]
  }
  return Math.floor(Math.random() * 2 ** 32)
}

export const randomBigInt64 = () => {
  const high = BigInt(randomUint32())
  const low = BigInt(randomUint32())
  return (high << 32n) | low
}

let tempIdCounter = 0
export const generateTempId = () => {
  tempIdCounter = (tempIdCounter + 1) % 1000
  return -(Date.now() + tempIdCounter)
}
