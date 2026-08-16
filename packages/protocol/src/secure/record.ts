import { MAX_PACKET_BYTES, concatBytes, equalBytes, int32LE, int64LE, readInt32LE, readInt64LE } from "./bytes.js"
import { aesIgeDecrypt, aesIgeEncrypt, authKeyId, computeV2MsgKey, deriveV2Aes } from "./crypto.js"

export type RecordDirection = "client-to-server" | "server-to-client"

export interface EncryptedRecordFields {
  serverSalt: bigint
  sessionId: bigint
  messageId: bigint
  sequenceNumber: number
  body: Uint8Array
}

export interface RecordValidation {
  direction: RecordDirection
  sessionId?: bigint
  validServerSalts: ReadonlySet<bigint>
  nowSeconds: number
}

export class InvalidEncryptedRecord extends Error {
  constructor() { super("Invalid Inline Protocol encrypted record") }
}

export class RecoverableEncryptedRecordError extends Error {
  constructor(
    readonly errorCode: 16 | 17 | 18 | 20 | 48,
    readonly fields: EncryptedRecordFields,
  ) {
    super("Recoverable Inline Protocol record error")
  }
}

export const encryptRecord = (
  authKey: Uint8Array,
  direction: RecordDirection,
  fields: EncryptedRecordFields,
  padding: Uint8Array,
): Uint8Array => {
  if (fields.body.length > MAX_PACKET_BYTES || fields.body.length % 4 !== 0) throw new RangeError("Record body must be aligned and within limits")
  if (padding.length < 12 || padding.length > 1024) throw new RangeError("Record padding must be 12...1024 bytes")
  const plaintext = concatBytes(
    int64LE(fields.serverSalt), int64LE(fields.sessionId), int64LE(fields.messageId),
    int32LE(fields.sequenceNumber), int32LE(fields.body.length), fields.body, padding,
  )
  if (plaintext.length % 16 !== 0) throw new RangeError("Record plaintext must be block aligned")
  const msgKey = computeV2MsgKey(authKey, plaintext, direction)
  const { key, iv } = deriveV2Aes(authKey, msgKey, direction)
  return concatBytes(authKeyId(authKey), msgKey, aesIgeEncrypt(plaintext, key, iv))
}

export const decryptRecord = (
  record: Uint8Array,
  authKey: Uint8Array,
  validation: RecordValidation,
): EncryptedRecordFields => {
  try {
    if (record.length < 24 + 48 || record.length > MAX_PACKET_BYTES || (record.length - 24) % 16 !== 0) throw new InvalidEncryptedRecord()
    const receivedKeyId = record.slice(0, 8)
    const msgKey = record.slice(8, 24)
    const { key, iv } = deriveV2Aes(authKey, msgKey, validation.direction)
    const plaintext = aesIgeDecrypt(record.slice(24), key, iv)
    const expectedMsgKey = computeV2MsgKey(authKey, plaintext, validation.direction)
    const validKeyId = equalBytes(receivedKeyId, authKeyId(authKey))
    const validMessageKey = equalBytes(msgKey, expectedMsgKey)
    if (!validKeyId || !validMessageKey) throw new InvalidEncryptedRecord()

    const bodyLength = readInt32LE(plaintext, 28)
    const paddingLength = plaintext.length - 32 - bodyLength
    if (bodyLength < 0 || bodyLength > MAX_PACKET_BYTES || bodyLength % 4 !== 0 || paddingLength < 12 || paddingLength > 1024) throw new InvalidEncryptedRecord()
    const serverSalt = readInt64LE(plaintext, 0)
    const sessionId = readInt64LE(plaintext, 8)
    const messageId = readInt64LE(plaintext, 16)
    const sequenceNumber = readInt32LE(plaintext, 24)
    const messageSeconds = Number(messageId >> 32n)
    const validDirection = validation.direction === "client-to-server"
      ? (messageId & 3n) === 0n && (messageId & 0xffffffffn) !== 0n
      : (messageId & 1n) === 1n
    if ((validation.sessionId !== undefined && sessionId !== validation.sessionId) ||
        messageId === 0n || sequenceNumber < 0) throw new InvalidEncryptedRecord()
    const fields = { serverSalt, sessionId, messageId, sequenceNumber, body: plaintext.slice(32, 32 + bodyLength) }
    if (!validDirection) throw new RecoverableEncryptedRecordError(18, fields)
    if (messageSeconds > validation.nowSeconds + 30) throw new RecoverableEncryptedRecordError(17, fields)
    if (messageSeconds < validation.nowSeconds - 300) throw new RecoverableEncryptedRecordError(20, fields)
    if (!validation.validServerSalts.has(serverSalt)) throw new RecoverableEncryptedRecordError(48, fields)
    return fields
  } catch (error) {
    if (error instanceof InvalidEncryptedRecord || error instanceof RecoverableEncryptedRecordError) throw error
    throw new InvalidEncryptedRecord()
  }
}
