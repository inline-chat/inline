import { sha1 } from "@noble/hashes/legacy"
import { sha256 } from "@noble/hashes/sha2"
import { concatBytes, equalBytes } from "./bytes.js"
import { getAesBackend, type AesCtrState } from "./aesBackend.js"

const BLOCK_BYTES = 16

const assertLength = (name: string, bytes: Uint8Array, length: number): void => {
  if (bytes.length !== length) throw new RangeError(`${name} must be ${length} bytes`)
}

export const sha1Digest = (...parts: readonly Uint8Array[]): Uint8Array => sha1(concatBytes(...parts))
export const sha256Digest = (...parts: readonly Uint8Array[]): Uint8Array => sha256(concatBytes(...parts))
export { equalBytes as constantTimeEqual }

export const authKeyId = (authKey: Uint8Array): Uint8Array => {
  assertLength("auth_key", authKey, 256)
  return sha1Digest(authKey).slice(12, 20)
}

export const deriveV2Aes = (
  authKey: Uint8Array,
  msgKey: Uint8Array,
  direction: "client-to-server" | "server-to-client",
): { key: Uint8Array; iv: Uint8Array } => {
  assertLength("auth_key", authKey, 256)
  assertLength("msg_key", msgKey, 16)
  const x = direction === "client-to-server" ? 0 : 8
  const sha256A = sha256Digest(msgKey, authKey.slice(x, x + 36))
  const sha256B = sha256Digest(authKey.slice(40 + x, 76 + x), msgKey)
  return {
    key: concatBytes(sha256A.slice(0, 8), sha256B.slice(8, 24), sha256A.slice(24, 32)),
    iv: concatBytes(sha256B.slice(0, 8), sha256A.slice(8, 24), sha256B.slice(24, 32)),
  }
}

/** SHA-256(auth_key[88+x..120+x] ‖ plaintext): the msg_key is bytes 8..24, the quick-ACK ID is the first word. */
export const computeV2MsgKeyDigest = (
  authKey: Uint8Array,
  plaintext: Uint8Array,
  direction: "client-to-server" | "server-to-client",
): Uint8Array => {
  assertLength("auth_key", authKey, 256)
  const x = direction === "client-to-server" ? 0 : 8
  return sha256Digest(authKey.slice(88 + x, 120 + x), plaintext)
}

export const msgKeyFromDigest = (digest: Uint8Array): Uint8Array => digest.slice(8, 24)

export const quickAckIdFromDigest = (digest: Uint8Array): number =>
  new DataView(digest.buffer, digest.byteOffset, 4).getUint32(0, true) & 0x7fffffff

export const computeV2MsgKey = (
  authKey: Uint8Array,
  plaintext: Uint8Array,
  direction: "client-to-server" | "server-to-client",
): Uint8Array => msgKeyFromDigest(computeV2MsgKeyDigest(authKey, plaintext, direction))

export const computeV2QuickAckId = (
  authKey: Uint8Array,
  plaintext: Uint8Array,
  direction: "client-to-server" | "server-to-client",
): number => quickAckIdFromDigest(computeV2MsgKeyDigest(authKey, plaintext, direction))

export const aesIgeEncrypt = (plaintext: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array => {
  assertLength("AES-256 key", key, 32)
  assertLength("AES-IGE IV", iv, 32)
  if (plaintext.length % BLOCK_BYTES !== 0) throw new RangeError("AES-IGE plaintext must be block aligned")
  return getAesBackend().igeEncrypt(plaintext, key, iv)
}

export const aesIgeDecrypt = (ciphertext: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array => {
  assertLength("AES-256 key", key, 32)
  assertLength("AES-IGE IV", iv, 32)
  if (ciphertext.length % BLOCK_BYTES !== 0) throw new RangeError("AES-IGE ciphertext must be block aligned")
  return getAesBackend().igeDecrypt(ciphertext, key, iv)
}

/** Continuous AES-256-CTR keystream; one instance per carrier direction for the life of a connection. */
export class AesCtrStream {
  readonly #state: AesCtrState

  constructor(key: Uint8Array, iv: Uint8Array) {
    assertLength("AES-256 key", key, 32)
    assertLength("AES-CTR IV", iv, 16)
    this.#state = getAesBackend().createCtr(key.slice(), iv.slice())
  }

  process(input: Uint8Array): Uint8Array {
    return this.#state.process(input)
  }
}
