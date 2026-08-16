import { ecb } from "@noble/ciphers/aes"
import { sha1 } from "@noble/hashes/legacy"
import { sha256 } from "@noble/hashes/sha2"
import { concatBytes, equalBytes, xorBytes } from "./bytes.js"

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

export const computeV2MsgKey = (
  authKey: Uint8Array,
  plaintext: Uint8Array,
  direction: "client-to-server" | "server-to-client",
): Uint8Array => {
  assertLength("auth_key", authKey, 256)
  const x = direction === "client-to-server" ? 0 : 8
  return sha256Digest(authKey.slice(88 + x, 120 + x), plaintext).slice(8, 24)
}

export const aesIgeEncrypt = (plaintext: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array => {
  assertLength("AES-256 key", key, 32)
  assertLength("AES-IGE IV", iv, 32)
  if (plaintext.length % BLOCK_BYTES !== 0) throw new RangeError("AES-IGE plaintext must be block aligned")
  const result = new Uint8Array(plaintext.length)
  let previousCipher = iv.slice(0, 16)
  let previousPlain = iv.slice(16, 32)
  for (let offset = 0; offset < plaintext.length; offset += BLOCK_BYTES) {
    const plain = plaintext.slice(offset, offset + BLOCK_BYTES)
    const encrypted = ecb(key, { disablePadding: true }).encrypt(xorBytes(plain, previousCipher))
    const output = xorBytes(encrypted, previousPlain)
    result.set(output, offset)
    previousCipher = Uint8Array.from(output)
    previousPlain = Uint8Array.from(plain)
  }
  return result
}

export const aesIgeDecrypt = (ciphertext: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array => {
  assertLength("AES-256 key", key, 32)
  assertLength("AES-IGE IV", iv, 32)
  if (ciphertext.length % BLOCK_BYTES !== 0) throw new RangeError("AES-IGE ciphertext must be block aligned")
  const result = new Uint8Array(ciphertext.length)
  let previousCipher = iv.slice(0, 16)
  let previousPlain = iv.slice(16, 32)
  for (let offset = 0; offset < ciphertext.length; offset += BLOCK_BYTES) {
    const encrypted = ciphertext.slice(offset, offset + BLOCK_BYTES)
    const decrypted = ecb(key, { disablePadding: true }).decrypt(xorBytes(encrypted, previousPlain))
    const plain = xorBytes(decrypted, previousCipher)
    result.set(plain, offset)
    previousCipher = Uint8Array.from(encrypted)
    previousPlain = Uint8Array.from(plain)
  }
  return result
}

export class AesCtrStream {
  readonly #key: Uint8Array
  readonly #counter: Uint8Array
  #keystream = new Uint8Array(0)
  #position = 0

  constructor(key: Uint8Array, iv: Uint8Array) {
    assertLength("AES-256 key", key, 32)
    assertLength("AES-CTR IV", iv, 16)
    this.#key = key.slice()
    this.#counter = iv.slice()
  }

  process(input: Uint8Array): Uint8Array {
    const output = new Uint8Array(input.length)
    for (let index = 0; index < input.length; index += 1) {
      if (this.#position === this.#keystream.length) {
        this.#keystream = Uint8Array.from(ecb(this.#key, { disablePadding: true }).encrypt(this.#counter))
        this.#position = 0
        this.#incrementCounter()
      }
      output[index] = input[index]! ^ this.#keystream[this.#position]!
      this.#position += 1
    }
    return output
  }

  #incrementCounter(): void {
    for (let index = this.#counter.length - 1; index >= 0; index -= 1) {
      this.#counter[index] = (this.#counter[index]! + 1) & 0xff
      if (this.#counter[index] !== 0) return
    }
  }
}
