import { createHmac, randomBytes } from "node:crypto"

const int32Le = (value: number): Buffer => {
  const bytes = Buffer.alloc(4)
  bytes.writeInt32LE(value)
  return bytes
}

export const inlineProtocolAuthCodeMac = (
  pepper: Uint8Array,
  challengeId: Uint8Array,
  identifier: string,
  code: string,
): Buffer => {
  const identifierBytes = Buffer.from(identifier, "utf8")
  const codeBytes = Buffer.from(code, "utf8")
  return createHmac("sha256", pepper)
    .update(challengeId)
    .update(int32Le(identifierBytes.length))
    .update(identifierBytes)
    .update(int32Le(codeBytes.length))
    .update(codeBytes)
    .digest()
}

export const inlineProtocolKeyedHash = (
  pepper: Uint8Array,
  label: string,
  value: string,
): Buffer => createHmac("sha256", pepper).update(label).update("\0").update(value).digest()

export const randomInlineProtocolAuthCode = (): string => {
  const bound = 1_000_000
  const limit = Math.floor(0x1_0000_0000 / bound) * bound
  while (true) {
    const value = randomBytes(4).readUInt32LE()
    if (value < limit) return String(value % bound).padStart(6, "0")
  }
}
