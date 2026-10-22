import { ecb } from "@noble/ciphers/aes"
import type { AesBackend, AesCtrState } from "./aesBackend.js"

const BLOCK_BYTES = 16

/**
 * Portable AES backend. `@noble/ciphers` refuses to reuse a cipher instance and
 * expands the key on every call, so this costs one key schedule per block; it is
 * the correctness reference and the browser fallback, not the fast path.
 */
export const makePureAesBackend = (): AesBackend => ({
  name: "pure-js",
  igeEncrypt: (plaintext, key, iv) => {
    const result = new Uint8Array(plaintext.length)
    let previousCipher = iv.subarray(0, 16)
    let previousPlain = iv.subarray(16, 32)
    const scratch = new Uint8Array(BLOCK_BYTES)
    for (let offset = 0; offset < plaintext.length; offset += BLOCK_BYTES) {
      const plain = plaintext.subarray(offset, offset + BLOCK_BYTES)
      for (let index = 0; index < BLOCK_BYTES; index += 1) scratch[index] = plain[index]! ^ previousCipher[index]!
      const encrypted = ecb(key, { disablePadding: true }).encrypt(scratch)
      for (let index = 0; index < BLOCK_BYTES; index += 1) result[offset + index] = encrypted[index]! ^ previousPlain[index]!
      previousCipher = result.subarray(offset, offset + BLOCK_BYTES)
      previousPlain = plain
    }
    return result
  },
  igeDecrypt: (ciphertext, key, iv) => {
    const result = new Uint8Array(ciphertext.length)
    let previousCipher = iv.subarray(0, 16)
    let previousPlain = iv.subarray(16, 32)
    const scratch = new Uint8Array(BLOCK_BYTES)
    for (let offset = 0; offset < ciphertext.length; offset += BLOCK_BYTES) {
      const encrypted = ciphertext.subarray(offset, offset + BLOCK_BYTES)
      for (let index = 0; index < BLOCK_BYTES; index += 1) scratch[index] = encrypted[index]! ^ previousPlain[index]!
      const decrypted = ecb(key, { disablePadding: true }).decrypt(scratch)
      for (let index = 0; index < BLOCK_BYTES; index += 1) result[offset + index] = decrypted[index]! ^ previousCipher[index]!
      previousCipher = encrypted
      previousPlain = result.subarray(offset, offset + BLOCK_BYTES)
    }
    return result
  },
  createCtr: (key, iv): AesCtrState => {
    const counterKey = key.slice()
    const counter = iv.slice()
    let keystream = new Uint8Array(0)
    let position = 0
    return {
      process: (input) => {
        const output = new Uint8Array(input.length)
        for (let index = 0; index < input.length; index += 1) {
          if (position === keystream.length) {
            keystream = Uint8Array.from(ecb(counterKey, { disablePadding: true }).encrypt(counter))
            position = 0
            for (let byte = counter.length - 1; byte >= 0; byte -= 1) {
              counter[byte] = (counter[byte]! + 1) & 0xff
              if (counter[byte] !== 0) break
            }
          }
          output[index] = input[index]! ^ keystream[position]!
          position += 1
        }
        return output
      },
    }
  },
})
