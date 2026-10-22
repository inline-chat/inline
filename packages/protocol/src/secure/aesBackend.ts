/**
 * AES primitives behind Inline Protocol records (AES-256-IGE) and the
 * obfuscated carrier (AES-256-CTR). The portable backend is pure JavaScript and
 * runs anywhere; hosts with native crypto install a faster backend at startup
 * (see `secure/node.ts`). Backends must be byte-for-byte equivalent; the
 * conformance vectors and `tests/aes-backends.test.ts` enforce that.
 */
export interface AesCtrState {
  /** Advances the keystream by `input.length` bytes and returns the XORed output. */
  process(input: Uint8Array): Uint8Array
}

export interface AesBackend {
  readonly name: string
  /** `plaintext.length % 16 === 0`, 32-byte key, 32-byte IV. */
  igeEncrypt(plaintext: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array
  /** `ciphertext.length % 16 === 0`, 32-byte key, 32-byte IV. */
  igeDecrypt(ciphertext: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array
  /** 32-byte key, 16-byte initial counter block. */
  createCtr(key: Uint8Array, iv: Uint8Array): AesCtrState
}

import { makePureAesBackend } from "./aesPure.js"

let current: AesBackend | undefined

/** Installs a backend for every subsequent record and carrier operation. Returns the previous one. */
export const setAesBackend = (backend: AesBackend): AesBackend => {
  const previous = getAesBackend()
  current = backend
  return previous
}

export const getAesBackend = (): AesBackend => current ?? (current = pureAesBackend())

let pure: AesBackend | undefined
const pureAesBackend = (): AesBackend => pure ?? (pure = makePureAesBackend())
