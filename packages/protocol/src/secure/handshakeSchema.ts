import {
  concatBytes,
  int32LE,
  int64LE,
  readInt32LE,
  readInt64LE,
  uint32LE,
} from "./bytes.js"
import { TlReader, encodeTlBytes, encodeTlVector } from "./tl.js"

export const HandshakeConstructor = {
  resPq: 0x05162463,
  pQInnerDataDc: 0xa9f55f95,
  pQInnerDataTempDc: 0x56fddf88,
  serverDhParamsOk: 0xd0e8075c,
  serverDhParamsFail: 0x79cb045d,
  serverDhInnerData: 0xb5890dba,
  clientDhInnerData: 0x6643b654,
  dhGenOk: 0x3bcbf734,
  dhGenRetry: 0x46dc1fb9,
  dhGenFail: 0xa69dae02,
  reqPqMulti: 0xbe7e8ef1,
  reqDhParams: 0xd712e4be,
  setClientDhParams: 0xf5045f1f,
} as const

const constructor = (value: number): Uint8Array => uint32LE(value)
const fixed = (name: string, value: Uint8Array, length: number): Uint8Array => {
  if (value.length !== length) throw new RangeError(`${name} must be ${length} bytes`)
  return value
}

export type PqInnerData = {
  temporary: boolean
  pq: Uint8Array
  p: Uint8Array
  q: Uint8Array
  nonce: Uint8Array
  serverNonce: Uint8Array
  newNonce: Uint8Array
  dc: number
  expiresIn?: number
}

export const encodeReqPqMulti = (nonce: Uint8Array): Uint8Array =>
  concatBytes(constructor(HandshakeConstructor.reqPqMulti), fixed("nonce", nonce, 16))

export const decodeReqPqMulti = (body: Uint8Array): { nonce: Uint8Array } => {
  const reader = constructorReader(body, HandshakeConstructor.reqPqMulti)
  const nonce = reader.readFixed(16)
  reader.expectEnd()
  return { nonce }
}

export const encodeResPq = (
  nonce: Uint8Array,
  serverNonce: Uint8Array,
  pq: Uint8Array,
  fingerprints: readonly bigint[],
): Uint8Array => concatBytes(
  constructor(HandshakeConstructor.resPq),
  fixed("nonce", nonce, 16),
  fixed("server_nonce", serverNonce, 16),
  encodeTlBytes(pq),
  encodeTlVector(fingerprints.map(int64LE)),
)

export const decodeResPq = (body: Uint8Array) => {
  const reader = constructorReader(body, HandshakeConstructor.resPq)
  const nonce = reader.readFixed(16)
  const serverNonce = reader.readFixed(16)
  const pq = reader.readBytes()
  const fingerprints = reader.readVector((item) => item.readLong())
  reader.expectEnd()
  return { nonce, serverNonce, pq, fingerprints }
}

export const encodePqInnerData = (value: PqInnerData): Uint8Array => concatBytes(
  constructor(value.temporary ? HandshakeConstructor.pQInnerDataTempDc : HandshakeConstructor.pQInnerDataDc),
  encodeTlBytes(value.pq), encodeTlBytes(value.p), encodeTlBytes(value.q),
  fixed("nonce", value.nonce, 16), fixed("server_nonce", value.serverNonce, 16),
  fixed("new_nonce", value.newNonce, 32), int32LE(value.dc),
  ...(value.temporary ? [int32LE(value.expiresIn ?? 0)] : []),
)

export const decodePqInnerDataPrefix = (padded: Uint8Array): { value: PqInnerData; consumed: number } => {
  if (padded.length !== 192) throw new RangeError("P_Q inner padded data must be 192 bytes")
  const id = readInt32LE(padded, 0) >>> 0
  const temporary = id === HandshakeConstructor.pQInnerDataTempDc
  if (!temporary && id !== HandshakeConstructor.pQInnerDataDc) throw new RangeError("Unexpected P_Q inner constructor")
  const reader = new TlReader(padded.slice(4))
  const pq = reader.readBytes()
  const p = reader.readBytes()
  const q = reader.readBytes()
  const nonce = reader.readFixed(16)
  const serverNonce = reader.readFixed(16)
  const newNonce = reader.readFixed(32)
  const dc = reader.readInt()
  const expiresIn = temporary ? reader.readInt() : undefined
  return {
    value: { temporary, pq, p, q, nonce, serverNonce, newNonce, dc, expiresIn },
    consumed: 4 + reader.offset,
  }
}

export const encodeReqDhParams = (value: {
  nonce: Uint8Array; serverNonce: Uint8Array; p: Uint8Array; q: Uint8Array
  fingerprint: bigint; encryptedData: Uint8Array
}): Uint8Array => concatBytes(
  constructor(HandshakeConstructor.reqDhParams), fixed("nonce", value.nonce, 16),
  fixed("server_nonce", value.serverNonce, 16), encodeTlBytes(value.p), encodeTlBytes(value.q),
  int64LE(value.fingerprint), encodeTlBytes(value.encryptedData),
)

export const decodeReqDhParams = (body: Uint8Array) => {
  const reader = constructorReader(body, HandshakeConstructor.reqDhParams)
  const value = {
    nonce: reader.readFixed(16), serverNonce: reader.readFixed(16),
    p: reader.readBytes(), q: reader.readBytes(), fingerprint: reader.readLong(),
    encryptedData: reader.readBytes(),
  }
  reader.expectEnd()
  return value
}

export const encodeServerDhParamsOk = (
  nonce: Uint8Array, serverNonce: Uint8Array, encryptedAnswer: Uint8Array,
): Uint8Array => concatBytes(
  constructor(HandshakeConstructor.serverDhParamsOk), fixed("nonce", nonce, 16),
  fixed("server_nonce", serverNonce, 16), encodeTlBytes(encryptedAnswer),
)

export const decodeServerDhParamsOk = (body: Uint8Array) => {
  const reader = constructorReader(body, HandshakeConstructor.serverDhParamsOk)
  const value = { nonce: reader.readFixed(16), serverNonce: reader.readFixed(16), encryptedAnswer: reader.readBytes() }
  reader.expectEnd()
  return value
}

export const encodeServerDhParamsFail = (
  nonce: Uint8Array, serverNonce: Uint8Array, newNonceHash: Uint8Array,
): Uint8Array => concatBytes(
  constructor(HandshakeConstructor.serverDhParamsFail), fixed("nonce", nonce, 16),
  fixed("server_nonce", serverNonce, 16), fixed("new_nonce_hash", newNonceHash, 16),
)

export type ServerDhParams =
  | { kind: "ok"; nonce: Uint8Array; serverNonce: Uint8Array; encryptedAnswer: Uint8Array }
  | { kind: "fail"; nonce: Uint8Array; serverNonce: Uint8Array; newNonceHash: Uint8Array }

export const decodeServerDhParams = (body: Uint8Array): ServerDhParams => {
  if (body.length < 4) throw new RangeError("Invalid server DH parameters")
  const id = readInt32LE(body, 0) >>> 0
  if (id === HandshakeConstructor.serverDhParamsOk) {
    return { kind: "ok", ...decodeServerDhParamsOk(body) }
  }
  if (id === HandshakeConstructor.serverDhParamsFail) {
    if (body.length !== 52) throw new RangeError("Invalid server DH failure")
    return {
      kind: "fail",
      nonce: body.slice(4, 20),
      serverNonce: body.slice(20, 36),
      newNonceHash: body.slice(36, 52),
    }
  }
  throw new RangeError("Unexpected server DH parameters")
}

export const encodeServerDhInnerData = (value: {
  nonce: Uint8Array; serverNonce: Uint8Array; generator: number; prime: Uint8Array
  gA: Uint8Array; serverTime: number
}): Uint8Array => concatBytes(
  constructor(HandshakeConstructor.serverDhInnerData), fixed("nonce", value.nonce, 16),
  fixed("server_nonce", value.serverNonce, 16), int32LE(value.generator),
  encodeTlBytes(value.prime), encodeTlBytes(value.gA), int32LE(value.serverTime),
)

export const decodeServerDhInnerDataPrefix = (plaintext: Uint8Array) => {
  const reader = constructorReaderPrefix(plaintext, HandshakeConstructor.serverDhInnerData)
  const value = {
    nonce: reader.readFixed(16), serverNonce: reader.readFixed(16), generator: reader.readInt(),
    prime: reader.readBytes(), gA: reader.readBytes(), serverTime: reader.readInt(),
  }
  return { value, consumed: 4 + reader.offset }
}

export const encodeClientDhInnerData = (value: {
  nonce: Uint8Array; serverNonce: Uint8Array; retryId: bigint; gB: Uint8Array
}): Uint8Array => concatBytes(
  constructor(HandshakeConstructor.clientDhInnerData), fixed("nonce", value.nonce, 16),
  fixed("server_nonce", value.serverNonce, 16), int64LE(value.retryId), encodeTlBytes(value.gB),
)

export const decodeClientDhInnerDataPrefix = (plaintext: Uint8Array) => {
  const reader = constructorReaderPrefix(plaintext, HandshakeConstructor.clientDhInnerData)
  const value = {
    nonce: reader.readFixed(16), serverNonce: reader.readFixed(16),
    retryId: reader.readLong(), gB: reader.readBytes(),
  }
  return { value, consumed: 4 + reader.offset }
}

export const encodeSetClientDhParams = (
  nonce: Uint8Array, serverNonce: Uint8Array, encryptedData: Uint8Array,
): Uint8Array => concatBytes(
  constructor(HandshakeConstructor.setClientDhParams), fixed("nonce", nonce, 16),
  fixed("server_nonce", serverNonce, 16), encodeTlBytes(encryptedData),
)

export const decodeSetClientDhParams = (body: Uint8Array) => {
  const reader = constructorReader(body, HandshakeConstructor.setClientDhParams)
  const value = { nonce: reader.readFixed(16), serverNonce: reader.readFixed(16), encryptedData: reader.readBytes() }
  reader.expectEnd()
  return value
}

export type DhGenKind = "ok" | "retry" | "fail"
export const encodeDhGen = (
  kind: DhGenKind, nonce: Uint8Array, serverNonce: Uint8Array, nonceHash: Uint8Array,
): Uint8Array => concatBytes(
  constructor(kind === "ok" ? HandshakeConstructor.dhGenOk : kind === "retry" ? HandshakeConstructor.dhGenRetry : HandshakeConstructor.dhGenFail),
  fixed("nonce", nonce, 16), fixed("server_nonce", serverNonce, 16), fixed("new_nonce_hash", nonceHash, 16),
)

export const decodeDhGen = (body: Uint8Array) => {
  if (body.length !== 52) throw new RangeError("Invalid DH generation response")
  const id = readInt32LE(body, 0) >>> 0
  const kind: DhGenKind = id === HandshakeConstructor.dhGenOk ? "ok"
    : id === HandshakeConstructor.dhGenRetry ? "retry"
    : id === HandshakeConstructor.dhGenFail ? "fail"
    : (() => { throw new RangeError("Unexpected DH generation response") })()
  return { kind, nonce: body.slice(4, 20), serverNonce: body.slice(20, 36), nonceHash: body.slice(36, 52) }
}

export const encodeUnencryptedRecord = (messageId: bigint, body: Uint8Array): Uint8Array => {
  if (body.length === 0 || body.length % 4 !== 0) throw new RangeError("Unencrypted handshake body must be aligned")
  return concatBytes(new Uint8Array(8), int64LE(messageId), int32LE(body.length), body)
}

export const decodeUnencryptedRecord = (packet: Uint8Array) => {
  if (packet.length < 24 || readInt64LE(packet, 0) !== 0n) throw new RangeError("Invalid unencrypted record")
  const bodyLength = readInt32LE(packet, 16)
  if (bodyLength <= 0 || bodyLength % 4 !== 0 || packet.length !== 20 + bodyLength) throw new RangeError("Invalid unencrypted body length")
  return { messageId: readInt64LE(packet, 8), body: packet.slice(20) }
}

const constructorReader = (body: Uint8Array, expected: number): TlReader => {
  const reader = constructorReaderPrefix(body, expected)
  return reader
}

const constructorReaderPrefix = (body: Uint8Array, expected: number): TlReader => {
  if (body.length < 4 || (readInt32LE(body, 0) >>> 0) !== expected) throw new RangeError("Unexpected TL constructor")
  return new TlReader(body.slice(4))
}
