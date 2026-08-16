import {
  MAX_PACKET_BYTES,
  concatBytes,
  int32LE,
  int64LE,
  readInt32LE,
  readInt64LE,
  uint32LE,
} from "./bytes.js"
import { TlReader, encodeTlBytes, encodeTlVector } from "./tl.js"

export const MAX_CONTAINER_MESSAGES = 1024
export const MAX_SERVICE_MESSAGE_IDS = 8192
export const MAX_GZIP_OUTPUT_BYTES = MAX_PACKET_BYTES

export const ServiceConstructor = {
  rpcResult: 0xf35c6d01,
  rpcError: 0x2144ca19,
  pong: 0x347773c5,
  newSessionCreated: 0x9ec20908,
  gzipPacked: 0x3072cfa1,
  msgsAck: 0x62d6b459,
  badMsgNotification: 0xa7eff811,
  badServerSalt: 0xedab447b,
  msgResendReq: 0x7d861a08,
  msgsStateReq: 0xda69fb52,
  msgsStateInfo: 0x04deb57d,
  msgsAllInfo: 0x8cc0d131,
  msgDetailedInfo: 0x276d3ec6,
  msgNewDetailedInfo: 0x809db6df,
  msgContainer: 0x73f1f8dc,
  msgCopy: 0xe06046b2,
  ping: 0x7abe77ec,
  pingDelayDisconnect: 0xf3427b8c,
  destroySession: 0xe7512126,
  destroySessionOk: 0xe22045fc,
  destroySessionNone: 0x62d350c9,
  destroyAuthKey: 0xd1435160,
  destroyAuthKeyOk: 0xf660e1d4,
  destroyAuthKeyNone: 0x0a9f2259,
  destroyAuthKeyFail: 0xea109b13,
  getFutureSalts: 0xb921bd04,
  futureSalt: 0x0949d9dc,
  futureSalts: 0xae500895,
  invokeAfterMsg: 0xcb9f372d,
  invokeAfterMsgs: 0x3dc4b4f0,
} as const

export interface ContainerMessage {
  messageId: bigint
  sequenceNumber: number
  body: Uint8Array
}

export type FutureSalt = {
  validSince: number
  validUntil: number
  salt: bigint
}

export type InvokeAfter = {
  messageIds: bigint[]
  query: Uint8Array
}

const constructor = (value: number): Uint8Array => uint32LE(value)
const fixedBody = (id: number, ...parts: readonly Uint8Array[]): Uint8Array =>
  concatBytes(constructor(id), ...parts)

const requireAlignedBody = (body: Uint8Array): void => {
  if (body.length < 4 || body.length > MAX_PACKET_BYTES || body.length % 4 !== 0) {
    throw new RangeError("MTProto body must be non-empty, bounded, and four-byte aligned")
  }
}

const encodeMessageIds = (id: number, messageIds: readonly bigint[]): Uint8Array => {
  if (messageIds.length > MAX_SERVICE_MESSAGE_IDS) throw new RangeError("Too many service message IDs")
  return fixedBody(id, encodeTlVector(messageIds.map(int64LE)))
}

const decodeMessageIds = (body: Uint8Array, expected: number): bigint[] => {
  const reader = readerFor(body, expected)
  const ids = reader.readVector((item) => item.readLong(), MAX_SERVICE_MESSAGE_IDS)
  reader.expectEnd()
  return ids
}

export const encodeMessageContainer = (messages: readonly ContainerMessage[]): Uint8Array => {
  if (messages.length < 1 || messages.length > MAX_CONTAINER_MESSAGES) {
    throw new RangeError("Invalid message-container count")
  }
  const encoded = messages.map((message) => {
    requireAlignedBody(message.body)
    if ((readInt32LE(message.body, 0) >>> 0) === ServiceConstructor.msgContainer) {
      throw new RangeError("Nested message containers are forbidden")
    }
    return concatBytes(
      int64LE(message.messageId), int32LE(message.sequenceNumber), int32LE(message.body.length), message.body,
    )
  })
  return fixedBody(ServiceConstructor.msgContainer, int32LE(messages.length), ...encoded)
}

export const decodeMessageContainer = (body: Uint8Array): ContainerMessage[] => {
  const reader = readerFor(body, ServiceConstructor.msgContainer)
  const count = reader.readInt()
  if (count < 1 || count > MAX_CONTAINER_MESSAGES) throw new RangeError("Invalid message-container count")
  const messages: ContainerMessage[] = []
  for (let index = 0; index < count; index += 1) {
    const messageId = reader.readLong()
    const sequenceNumber = reader.readInt()
    const bytes = reader.readInt()
    if (bytes < 4 || bytes > MAX_PACKET_BYTES || bytes % 4 !== 0) throw new RangeError("Invalid contained body length")
    const child = reader.readFixed(bytes)
    if ((readInt32LE(child, 0) >>> 0) === ServiceConstructor.msgContainer) {
      throw new RangeError("Nested message containers are forbidden")
    }
    messages.push({ messageId, sequenceNumber, body: child })
  }
  reader.expectEnd()
  return messages
}

export const encodeMsgCopy = (message: ContainerMessage): Uint8Array => {
  requireAlignedBody(message.body)
  return fixedBody(
    ServiceConstructor.msgCopy,
    int64LE(message.messageId),
    int32LE(message.sequenceNumber),
    int32LE(message.body.length),
    message.body,
  )
}

export const decodeMsgCopy = (body: Uint8Array): ContainerMessage => {
  const reader = readerFor(body, ServiceConstructor.msgCopy)
  const messageId = reader.readLong()
  const sequenceNumber = reader.readInt()
  const length = reader.readInt()
  if (length < 4 || length > MAX_PACKET_BYTES || length % 4 !== 0) {
    throw new RangeError("Invalid copied body length")
  }
  const copied = reader.readFixed(length)
  reader.expectEnd()
  if ((readInt32LE(copied, 0) >>> 0) === ServiceConstructor.msgContainer) {
    throw new RangeError("A copied message cannot contain a container")
  }
  return { messageId, sequenceNumber, body: copied }
}

export const encodeInvokeAfterMsg = (messageId: bigint, query: Uint8Array): Uint8Array => {
  requireAlignedBody(query)
  return fixedBody(ServiceConstructor.invokeAfterMsg, int64LE(messageId), query)
}

export const encodeInvokeAfterMsgs = (messageIds: readonly bigint[], query: Uint8Array): Uint8Array => {
  if (messageIds.length > MAX_SERVICE_MESSAGE_IDS) throw new RangeError("Too many invoke-after dependencies")
  requireAlignedBody(query)
  return fixedBody(ServiceConstructor.invokeAfterMsgs, encodeTlVector(messageIds.map(int64LE)), query)
}

export const decodeInvokeAfter = (body: Uint8Array): InvokeAfter => {
  const id = serviceConstructor(body)
  const reader = readerFor(body, id)
  let messageIds: bigint[]
  if (id === ServiceConstructor.invokeAfterMsg) {
    messageIds = [reader.readLong()]
  } else if (id === ServiceConstructor.invokeAfterMsgs) {
    messageIds = reader.readVector((item) => item.readLong(), MAX_SERVICE_MESSAGE_IDS)
  } else {
    throw new RangeError("Unexpected invoke-after constructor")
  }
  const query = reader.readFixed(reader.remaining)
  requireAlignedBody(query)
  return { messageIds, query }
}

export const encodeRpcResult = (requestMessageId: bigint, result: Uint8Array): Uint8Array => {
  requireAlignedBody(result)
  return fixedBody(ServiceConstructor.rpcResult, int64LE(requestMessageId), result)
}

export const decodeRpcResult = (body: Uint8Array): { requestMessageId: bigint; result: Uint8Array } => {
  const reader = readerFor(body, ServiceConstructor.rpcResult)
  const requestMessageId = reader.readLong()
  const result = reader.readFixed(reader.remaining)
  requireAlignedBody(result)
  return { requestMessageId, result }
}

export const encodeRpcError = (code: number, message: string): Uint8Array =>
  fixedBody(ServiceConstructor.rpcError, int32LE(code), encodeTlBytes(new TextEncoder().encode(message)))

export const encodeMsgsAck = (messageIds: readonly bigint[]): Uint8Array =>
  encodeMessageIds(ServiceConstructor.msgsAck, messageIds)
export const decodeMsgsAck = (body: Uint8Array): bigint[] => decodeMessageIds(body, ServiceConstructor.msgsAck)
export const encodeMsgResendReq = (messageIds: readonly bigint[]): Uint8Array =>
  encodeMessageIds(ServiceConstructor.msgResendReq, messageIds)
export const decodeMsgResendReq = (body: Uint8Array): bigint[] => decodeMessageIds(body, ServiceConstructor.msgResendReq)
export const encodeMsgsStateReq = (messageIds: readonly bigint[]): Uint8Array =>
  encodeMessageIds(ServiceConstructor.msgsStateReq, messageIds)
export const decodeMsgsStateReq = (body: Uint8Array): bigint[] => decodeMessageIds(body, ServiceConstructor.msgsStateReq)

export const encodeMsgsStateInfo = (requestMessageId: bigint, states: Uint8Array): Uint8Array => {
  if (states.length > MAX_SERVICE_MESSAGE_IDS) throw new RangeError("Too many message states")
  return fixedBody(ServiceConstructor.msgsStateInfo, int64LE(requestMessageId), encodeTlBytes(states))
}

export const encodeMsgsAllInfo = (messageIds: readonly bigint[], states: Uint8Array): Uint8Array => {
  if (messageIds.length !== states.length || messageIds.length > MAX_SERVICE_MESSAGE_IDS) {
    throw new RangeError("Message-state cardinality mismatch")
  }
  return fixedBody(ServiceConstructor.msgsAllInfo, encodeTlVector(messageIds.map(int64LE)), encodeTlBytes(states))
}

export const decodeMsgsAllInfo = (body: Uint8Array): { messageIds: bigint[]; states: Uint8Array } => {
  const reader = readerFor(body, ServiceConstructor.msgsAllInfo)
  const messageIds = reader.readVector((item) => item.readLong(), MAX_SERVICE_MESSAGE_IDS)
  const states = reader.readBytes()
  reader.expectEnd()
  if (messageIds.length !== states.length) throw new RangeError("Message-state cardinality mismatch")
  return { messageIds, states }
}

export const encodeBadMsgNotification = (
  badMessageId: bigint, badSequenceNumber: number, errorCode: number,
): Uint8Array => fixedBody(
  ServiceConstructor.badMsgNotification, int64LE(badMessageId), int32LE(badSequenceNumber), int32LE(errorCode),
)

export const encodeBadServerSalt = (
  badMessageId: bigint, badSequenceNumber: number, errorCode: number, newServerSalt: bigint,
): Uint8Array => fixedBody(
  ServiceConstructor.badServerSalt, int64LE(badMessageId), int32LE(badSequenceNumber), int32LE(errorCode),
  int64LE(newServerSalt),
)

export type BadMessageNotification = {
  kind: "message" | "salt"
  badMessageId: bigint
  badSequenceNumber: number
  errorCode: number
  newServerSalt?: bigint
}

export const decodeBadMessageNotification = (body: Uint8Array): BadMessageNotification => {
  if (body.length !== 20 && body.length !== 28) throw new RangeError("Invalid bad-message notification")
  const id = readInt32LE(body, 0) >>> 0
  const salt = id === ServiceConstructor.badServerSalt
  if (!salt && id !== ServiceConstructor.badMsgNotification) throw new RangeError("Unexpected bad-message constructor")
  if (salt !== (body.length === 28)) throw new RangeError("Invalid bad-message length")
  return {
    kind: salt ? "salt" : "message",
    badMessageId: readInt64LE(body, 4),
    badSequenceNumber: readInt32LE(body, 12),
    errorCode: readInt32LE(body, 16),
    newServerSalt: salt ? readInt64LE(body, 20) : undefined,
  }
}

export const encodePing = (pingId: bigint): Uint8Array => fixedBody(ServiceConstructor.ping, int64LE(pingId))
export const encodePingDelayDisconnect = (pingId: bigint, delaySeconds: number): Uint8Array =>
  fixedBody(ServiceConstructor.pingDelayDisconnect, int64LE(pingId), int32LE(delaySeconds))
export const encodePong = (messageId: bigint, pingId: bigint): Uint8Array =>
  fixedBody(ServiceConstructor.pong, int64LE(messageId), int64LE(pingId))
export const encodeNewSessionCreated = (firstMessageId: bigint, uniqueId: bigint, serverSalt: bigint): Uint8Array =>
  fixedBody(ServiceConstructor.newSessionCreated, int64LE(firstMessageId), int64LE(uniqueId), int64LE(serverSalt))

export const encodeGetFutureSalts = (count: number): Uint8Array => {
  if (!Number.isInteger(count) || count < 1 || count > 64) throw new RangeError("Invalid future-salt count")
  return fixedBody(ServiceConstructor.getFutureSalts, int32LE(count))
}

export const decodeGetFutureSalts = (body: Uint8Array): number => {
  const reader = readerFor(body, ServiceConstructor.getFutureSalts)
  const count = reader.readInt()
  reader.expectEnd()
  if (count < 1 || count > 64) throw new RangeError("Invalid future-salt count")
  return count
}

export const encodeFutureSalts = (
  requestMessageId: bigint,
  now: number,
  salts: readonly FutureSalt[],
): Uint8Array => {
  if (salts.length < 1 || salts.length > 64) throw new RangeError("Invalid future-salt count")
  return fixedBody(
    ServiceConstructor.futureSalts,
    int64LE(requestMessageId),
    int32LE(now),
    encodeTlVector(salts.map((salt) => {
      if (!Number.isInteger(salt.validSince) || !Number.isInteger(salt.validUntil) ||
          salt.validUntil <= salt.validSince) throw new RangeError("Invalid future-salt interval")
      return fixedBody(
        ServiceConstructor.futureSalt,
        int32LE(salt.validSince),
        int32LE(salt.validUntil),
        int64LE(salt.salt),
      )
    })),
  )
}

export const encodeDestroySession = (sessionId: bigint): Uint8Array =>
  fixedBody(ServiceConstructor.destroySession, int64LE(sessionId))

export const decodeDestroySession = (body: Uint8Array): bigint => {
  const reader = readerFor(body, ServiceConstructor.destroySession)
  const sessionId = reader.readLong()
  reader.expectEnd()
  return sessionId
}

export const encodeDestroySessionResult = (sessionId: bigint, found: boolean): Uint8Array =>
  fixedBody(found ? ServiceConstructor.destroySessionOk : ServiceConstructor.destroySessionNone, int64LE(sessionId))

export const encodeDestroyAuthKey = (): Uint8Array => fixedBody(ServiceConstructor.destroyAuthKey)
export const encodeDestroyAuthKeyResult = (result: "ok" | "none" | "fail"): Uint8Array =>
  fixedBody(result === "ok"
    ? ServiceConstructor.destroyAuthKeyOk
    : result === "none"
      ? ServiceConstructor.destroyAuthKeyNone
      : ServiceConstructor.destroyAuthKeyFail)

export const encodeGzipPacked = (packed: Uint8Array): Uint8Array =>
  fixedBody(ServiceConstructor.gzipPacked, encodeTlBytes(packed))

export const decodeGzipPacked = (
  body: Uint8Array,
  gunzip: (packed: Uint8Array, maximumOutputBytes: number) => Uint8Array,
  maximumOutputBytes = MAX_GZIP_OUTPUT_BYTES,
): Uint8Array => {
  if (maximumOutputBytes < 4 || maximumOutputBytes > MAX_GZIP_OUTPUT_BYTES) {
    throw new RangeError("Invalid gzip output limit")
  }
  const reader = readerFor(body, ServiceConstructor.gzipPacked)
  const packed = reader.readBytes()
  reader.expectEnd()
  const unpacked = gunzip(packed, maximumOutputBytes)
  if (unpacked.length < 4 || unpacked.length > maximumOutputBytes || unpacked.length % 4 !== 0) {
    throw new RangeError("Invalid decompressed MTProto object")
  }
  return unpacked
}

export const serviceConstructor = (body: Uint8Array): number => {
  requireAlignedBody(body)
  return readInt32LE(body, 0) >>> 0
}

const readerFor = (body: Uint8Array, expected: number): TlReader => {
  requireAlignedBody(body)
  if ((readInt32LE(body, 0) >>> 0) !== expected) throw new RangeError("Unexpected service constructor")
  return new TlReader(body.slice(4))
}
