import { concatBytes, equalBytes, int32LE, int64LE, readInt32LE, readInt64LE, uint32LE } from "./bytes.js"
import { aesIgeDecrypt, aesIgeEncrypt, authKeyId, sha1Digest } from "./crypto.js"
import { TlReader, encodeTlBytes } from "./tl.js"

export const BindingConstructor = {
  bindAuthKeyInner: 0x75a3f765,
  bindTempAuthKey: 0xcdd42a05,
} as const

export interface BindAuthKeyInner {
  nonce: bigint
  temporaryAuthKeyId: bigint
  permanentAuthKeyId: bigint
  temporarySessionId: bigint
  expiresAt: number
}

export interface BindTempAuthKeyRequest {
  permanentAuthKeyId: bigint
  nonce: bigint
  expiresAt: number
  encryptedMessage: Uint8Array
}

const keyIdLong = (key: Uint8Array): bigint =>
  new DataView(authKeyId(key).buffer).getBigInt64(0, true)

export const encodeBindAuthKeyInner = (value: BindAuthKeyInner): Uint8Array => concatBytes(
  uint32LE(BindingConstructor.bindAuthKeyInner),
  int64LE(value.nonce),
  int64LE(value.temporaryAuthKeyId),
  int64LE(value.permanentAuthKeyId),
  int64LE(value.temporarySessionId),
  int32LE(value.expiresAt),
)

export const decodeBindAuthKeyInner = (body: Uint8Array): BindAuthKeyInner => {
  if (body.length !== 40 || (readInt32LE(body, 0) >>> 0) !== BindingConstructor.bindAuthKeyInner) {
    throw new RangeError("Invalid bind_auth_key_inner")
  }
  return {
    nonce: readInt64LE(body, 4),
    temporaryAuthKeyId: readInt64LE(body, 12),
    permanentAuthKeyId: readInt64LE(body, 20),
    temporarySessionId: readInt64LE(body, 28),
    expiresAt: readInt32LE(body, 36),
  }
}

export const encodeBindTempAuthKey = (value: BindTempAuthKeyRequest): Uint8Array => {
  if (value.encryptedMessage.length !== 104) throw new RangeError("Binding proof must be exactly 104 bytes")
  return concatBytes(
    uint32LE(BindingConstructor.bindTempAuthKey),
    int64LE(value.permanentAuthKeyId),
    int64LE(value.nonce),
    int32LE(value.expiresAt),
    encodeTlBytes(value.encryptedMessage),
  )
}

export const decodeBindTempAuthKey = (body: Uint8Array): BindTempAuthKeyRequest => {
  if (body.length < 4 || (readInt32LE(body, 0) >>> 0) !== BindingConstructor.bindTempAuthKey) {
    throw new RangeError("Invalid auth.bindTempAuthKey")
  }
  const reader = new TlReader(body.slice(4))
  const value = {
    permanentAuthKeyId: reader.readLong(),
    nonce: reader.readLong(),
    expiresAt: reader.readInt(),
    encryptedMessage: reader.readBytes(),
  }
  reader.expectEnd()
  if (value.encryptedMessage.length !== 104) throw new RangeError("Binding proof must be exactly 104 bytes")
  return value
}

const deriveV1Aes = (authKey: Uint8Array, messageKey: Uint8Array): { key: Uint8Array; iv: Uint8Array } => {
  if (authKey.length !== 256 || messageKey.length !== 16) throw new RangeError("Invalid binding key material")
  const a = sha1Digest(messageKey, authKey.slice(0, 32))
  const b = sha1Digest(authKey.slice(32, 48), messageKey, authKey.slice(48, 64))
  const c = sha1Digest(authKey.slice(64, 96), messageKey)
  const d = sha1Digest(messageKey, authKey.slice(96, 128))
  return {
    key: concatBytes(a.slice(0, 8), b.slice(8, 20), c.slice(4, 16)),
    iv: concatBytes(a.slice(8, 20), b.slice(0, 8), c.slice(16, 20), d.slice(0, 8)),
  }
}

export const createTemporaryKeyBindingProof = (input: {
  permanentAuthKey: Uint8Array
  temporaryAuthKey: Uint8Array
  temporarySessionId: bigint
  messageId: bigint
  nonce: bigint
  expiresAt: number
  randomInt128: Uint8Array
  randomPadding: Uint8Array
}): Uint8Array => {
  if (input.randomInt128.length !== 16 || input.randomPadding.length !== 8) {
    throw new RangeError("Binding proof requires 16-byte prefix and 8-byte padding")
  }
  const inner = encodeBindAuthKeyInner({
    nonce: input.nonce,
    temporaryAuthKeyId: keyIdLong(input.temporaryAuthKey),
    permanentAuthKeyId: keyIdLong(input.permanentAuthKey),
    temporarySessionId: input.temporarySessionId,
    expiresAt: input.expiresAt,
  })
  const plaintextWithoutPadding = concatBytes(
    input.randomInt128, int64LE(input.messageId), int32LE(0), int32LE(inner.length), inner,
  )
  const messageKey = sha1Digest(plaintextWithoutPadding).slice(4, 20)
  const { key, iv } = deriveV1Aes(input.permanentAuthKey, messageKey)
  return concatBytes(
    authKeyId(input.permanentAuthKey),
    messageKey,
    aesIgeEncrypt(concatBytes(plaintextWithoutPadding, input.randomPadding), key, iv),
  )
}

export interface VerifiedTemporaryKeyBinding {
  inner: BindAuthKeyInner
  messageId: bigint
}

export const verifyTemporaryKeyBindingProof = (input: {
  encryptedMessage: Uint8Array
  permanentAuthKey: Uint8Array
  outerPermanentAuthKeyId: bigint
  outerTemporaryAuthKeyId: bigint
  outerTemporarySessionId: bigint
  outerMessageId: bigint
  outerNonce: bigint
  outerExpiresAt: number
  temporaryKeyExpiresAt: number
  nowSeconds: number
}): VerifiedTemporaryKeyBinding => {
  if (input.encryptedMessage.length !== 104 || input.permanentAuthKey.length !== 256) {
    throw new RangeError("Invalid temporary-key binding proof")
  }
  const receivedKeyId = input.encryptedMessage.slice(0, 8)
  const messageKey = input.encryptedMessage.slice(8, 24)
  const { key, iv } = deriveV1Aes(input.permanentAuthKey, messageKey)
  const plaintext = aesIgeDecrypt(input.encryptedMessage.slice(24), key, iv)
  const plaintextWithoutPadding = plaintext.slice(0, 72)
  if (!equalBytes(receivedKeyId, authKeyId(input.permanentAuthKey)) ||
      !equalBytes(messageKey, sha1Digest(plaintextWithoutPadding).slice(4, 20))) {
    throw new RangeError("Invalid temporary-key binding confirmation")
  }
  const messageId = readInt64LE(plaintext, 16)
  const sequenceNumber = readInt32LE(plaintext, 24)
  const bodyLength = readInt32LE(plaintext, 28)
  if (sequenceNumber !== 0 || bodyLength !== 40 || plaintext.length !== 80) {
    throw new RangeError("Invalid isolated binding record")
  }
  const inner = decodeBindAuthKeyInner(plaintext.slice(32, 72))
  if (
    keyIdLong(input.permanentAuthKey) !== input.outerPermanentAuthKeyId ||
    inner.permanentAuthKeyId !== input.outerPermanentAuthKeyId ||
    inner.temporaryAuthKeyId !== input.outerTemporaryAuthKeyId ||
    inner.temporarySessionId !== input.outerTemporarySessionId ||
    inner.nonce !== input.outerNonce ||
    inner.expiresAt !== input.outerExpiresAt ||
    messageId !== input.outerMessageId ||
    input.outerExpiresAt <= input.nowSeconds ||
    input.outerExpiresAt > input.temporaryKeyExpiresAt + 30
  ) throw new RangeError("Temporary-key binding mismatch")
  return { inner, messageId }
}
