import {
  createCipheriv,
  createDecipheriv,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  type KeyObject,
  randomBytes,
} from "node:crypto"

const X25519_RAW_PUBLIC_KEY_LENGTH = 32
const X25519_SPKI_DER_PREFIX = Buffer.from("302a300506032b656e032100", "hex")
const PUSH_CONTENT_HKDF_INFO = Buffer.from("inline.push-content.v1", "utf8")

export const PUSH_CONTENT_VERSION = 1
export const PUSH_CONTENT_ALGORITHM = "X25519_HKDF_SHA256_AES256_GCM"

export type EncryptedPushContentEnvelope = {
  version: number
  algorithm: string
  keyId?: string
  ephemeralPublicKey: string
  salt: string
  iv: string
  ciphertext: string
  tag: string
}

export type EncryptedSendMessagePushContent = {
  kind: "send_message"
  sender: {
    id: number
    displayName?: string
    profilePhotoUrl?: string
  }
  title: string
  body: string
  subtitle?: string
  threadId: string
  messageId: string
  isThread: boolean
  threadEmoji?: string
}

const encodeBase64Url = (value: Buffer): string => value.toString("base64url")

const decodeBase64Url = (value: string): Buffer => Buffer.from(value, "base64url")

const ensureX25519PublicKey = (rawPublicKey: Uint8Array): KeyObject => {
  if (rawPublicKey.length !== X25519_RAW_PUBLIC_KEY_LENGTH) {
    throw new Error("Invalid X25519 public key length")
  }

  return createPublicKey({
    key: Buffer.concat([X25519_SPKI_DER_PREFIX, Buffer.from(rawPublicKey)]),
    format: "der",
    type: "spki",
  })
}

const extractRawX25519PublicKey = (publicKey: KeyObject): Buffer => {
  const spki = publicKey.export({ format: "der", type: "spki" })
  if (!Buffer.isBuffer(spki)) {
    throw new Error("Unexpected public key export format")
  }

  if (spki.length < X25519_RAW_PUBLIC_KEY_LENGTH) {
    throw new Error("Unexpected X25519 public key export length")
  }

  return spki.subarray(spki.length - X25519_RAW_PUBLIC_KEY_LENGTH)
}

export const encryptSendMessagePushContent = (input: {
  recipientPublicKey: Uint8Array
  recipientKeyId?: string
  content: EncryptedSendMessagePushContent
}): EncryptedPushContentEnvelope => {
  const recipientPublicKey = ensureX25519PublicKey(input.recipientPublicKey)
  const ephemeral = generateKeyPairSync("x25519")
  const sharedSecret = diffieHellman({
    privateKey: ephemeral.privateKey,
    publicKey: recipientPublicKey,
  })

  const salt = randomBytes(16)
  const aesKey = Buffer.from(hkdfSync("sha256", sharedSecret, salt, PUSH_CONTENT_HKDF_INFO, 32))
  const iv = randomBytes(12)

  const cipher = createCipheriv("aes-256-gcm", aesKey, iv)
  const plaintext = Buffer.from(JSON.stringify(input.content), "utf8")
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()])
  const tag = cipher.getAuthTag()

  return {
    version: PUSH_CONTENT_VERSION,
    algorithm: PUSH_CONTENT_ALGORITHM,
    keyId: input.recipientKeyId,
    ephemeralPublicKey: encodeBase64Url(extractRawX25519PublicKey(ephemeral.publicKey)),
    salt: encodeBase64Url(salt),
    iv: encodeBase64Url(iv),
    ciphertext: encodeBase64Url(ciphertext),
    tag: encodeBase64Url(tag),
  }
}

// Test helper used to validate envelope compatibility.
export const decryptSendMessagePushContentForTests = (input: {
  privateKey: KeyObject
  envelope: EncryptedPushContentEnvelope
}): EncryptedSendMessagePushContent => {
  const envelope = input.envelope
  const ephemeralPublicKey = ensureX25519PublicKey(decodeBase64Url(envelope.ephemeralPublicKey))
  const sharedSecret = diffieHellman({
    privateKey: input.privateKey,
    publicKey: ephemeralPublicKey,
  })

  const aesKey = Buffer.from(hkdfSync("sha256", sharedSecret, decodeBase64Url(envelope.salt), PUSH_CONTENT_HKDF_INFO, 32))
  const decipher = createDecipheriv("aes-256-gcm", aesKey, decodeBase64Url(envelope.iv))
  decipher.setAuthTag(decodeBase64Url(envelope.tag))

  const decrypted = Buffer.concat([decipher.update(decodeBase64Url(envelope.ciphertext)), decipher.final()])
  return JSON.parse(decrypted.toString("utf8")) as EncryptedSendMessagePushContent
}
