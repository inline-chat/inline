import { AesCtrStream } from "./crypto.js"
import { MAX_PACKET_BYTES, concatBytes, reverseBytes } from "./bytes.js"

const FORBIDDEN_PREFIXES = new Set([0x44414548, 0x54534f50, 0x20544547, 0x4954504f, 0xeeeeeeee, 0xdddddddd, 0x02010316])

export const encodeAbridgedPacket = (payload: Uint8Array): Uint8Array => {
  if (payload.length === 0 || payload.length > MAX_PACKET_BYTES || payload.length % 4 !== 0) throw new RangeError("Invalid abridged payload length")
  const words = payload.length / 4
  if (words < 127) return concatBytes(Uint8Array.of(words), payload)
  if (words > 0xffffff) throw new RangeError("Abridged payload is too large")
  return concatBytes(Uint8Array.of(0x7f, words & 0xff, (words >>> 8) & 0xff, (words >>> 16) & 0xff), payload)
}

export const decodeAbridgedPacket = (packet: Uint8Array): Uint8Array => {
  if (packet.length < 2) throw new RangeError("Truncated abridged packet")
  const long = packet[0] === 0x7f
  const headerLength = long ? 4 : 1
  if (packet.length < headerLength) throw new RangeError("Truncated abridged packet")
  const words = long
    ? packet[1]! | (packet[2]! << 8) | (packet[3]! << 16)
    : packet[0]!
  const length = words * 4
  if (words === 0 || length > MAX_PACKET_BYTES || packet.length !== headerLength + length) throw new RangeError("Invalid abridged packet length")
  return packet.slice(headerLength)
}

export const isValidObfuscatedHeader = (header: Uint8Array): boolean => {
  if (header.length !== 64 || header[0] === 0xef) return false
  const view = new DataView(header.buffer, header.byteOffset, header.byteLength)
  return !FORBIDDEN_PREFIXES.has(view.getUint32(0, true)) && view.getUint32(4, true) !== 0
}

export interface ObfuscatedClientHeader {
  wireHeader: Uint8Array
  outbound: AesCtrStream
  inbound: AesCtrStream
}

export interface ObfuscatedServerHeader {
  outbound: AesCtrStream
  inbound: AesCtrStream
  dc: number
}

export const createObfuscatedClientHeader = (randomHeader: Uint8Array, dc = 1): ObfuscatedClientHeader => {
  if (!isValidObfuscatedHeader(randomHeader)) throw new RangeError("Forbidden obfuscated header")
  if (dc < -32768 || dc > 32767) throw new RangeError("Invalid logical DC")
  const plaintext = randomHeader.slice()
  plaintext.set([0xef, 0xef, 0xef, 0xef], 56)
  new DataView(plaintext.buffer).setInt16(60, dc, true)
  const reversed = reverseBytes(plaintext)
  const outbound = new AesCtrStream(plaintext.slice(8, 40), plaintext.slice(40, 56))
  const inbound = new AesCtrStream(reversed.slice(8, 40), reversed.slice(40, 56))
  const encryptedHeader = outbound.process(plaintext)
  return { wireHeader: concatBytes(plaintext.slice(0, 56), encryptedHeader.slice(56)), outbound, inbound }
}

export const acceptObfuscatedClientHeader = (wireHeader: Uint8Array, expectedDc = 1): ObfuscatedServerHeader => {
  if (wireHeader.length !== 64) throw new RangeError("Invalid obfuscated header length")
  const inbound = new AesCtrStream(wireHeader.slice(8, 40), wireHeader.slice(40, 56))
  const decrypted = inbound.process(wireHeader)
  const plaintext = concatBytes(wireHeader.slice(0, 56), decrypted.slice(56))
  if (!isValidObfuscatedHeader(plaintext) || plaintext.slice(56, 60).some((byte) => byte !== 0xef)) {
    throw new RangeError("Invalid obfuscated transport marker")
  }
  const dc = new DataView(plaintext.buffer, plaintext.byteOffset, plaintext.byteLength).getInt16(60, true)
  if (dc !== expectedDc) throw new RangeError("Unexpected logical DC")
  const reversed = reverseBytes(plaintext)
  return {
    inbound,
    outbound: new AesCtrStream(reversed.slice(8, 40), reversed.slice(40, 56)),
    dc,
  }
}
