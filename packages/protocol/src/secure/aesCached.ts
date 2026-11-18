import { unsafe } from "@noble/ciphers/aes"
import type { AesBackend, AesCtrState } from "./aesBackend.js"

const BLOCK_BYTES = 16

const isLittleEndian = new Uint8Array(new Uint32Array([1]).buffer)[0] === 1

const word = (bytes: Uint8Array, offset: number): number =>
  (bytes[offset]! | (bytes[offset + 1]! << 8) | (bytes[offset + 2]! << 16) | (bytes[offset + 3]! << 24)) >>> 0

const putWord = (bytes: Uint8Array, offset: number, value: number): void => {
  bytes[offset] = value & 0xff
  bytes[offset + 1] = (value >>> 8) & 0xff
  bytes[offset + 2] = (value >>> 16) & 0xff
  bytes[offset + 3] = (value >>> 24) & 0xff
}

/**
 * Portable AES backend that expands each key once per operation instead of once
 * per block. Same primitives as `aesPure.ts` (`@noble/ciphers`' table AES, through
 * its exported block functions), so it runs in any JavaScript host; byte-for-byte
 * equivalent to the reference and native backends (tested). The carrier keeps one
 * key schedule for the life of the connection, so its cost per byte drops the most.
 */
export const makeCachedPureAesBackend = (): AesBackend => {
  if (!isLittleEndian) throw new Error("The cached AES backend requires a little-endian host")
  return {
    name: "pure-js-cached",
    igeEncrypt: (plaintext, key, iv) => {
      if (plaintext.length % BLOCK_BYTES !== 0) throw new RangeError("IGE input must be block aligned")
      const xk = unsafe.expandKeyLE(key)
      const result = new Uint8Array(plaintext.length)
      let c0 = word(iv, 0), c1 = word(iv, 4), c2 = word(iv, 8), c3 = word(iv, 12)
      let p0 = word(iv, 16), p1 = word(iv, 20), p2 = word(iv, 24), p3 = word(iv, 28)
      for (let offset = 0; offset < plaintext.length; offset += BLOCK_BYTES) {
        const x0 = word(plaintext, offset), x1 = word(plaintext, offset + 4)
        const x2 = word(plaintext, offset + 8), x3 = word(plaintext, offset + 12)
        const out = unsafe.encrypt(xk, x0 ^ c0, x1 ^ c1, x2 ^ c2, x3 ^ c3)
        c0 = (out.s0 ^ p0) >>> 0
        c1 = (out.s1 ^ p1) >>> 0
        c2 = (out.s2 ^ p2) >>> 0
        c3 = (out.s3 ^ p3) >>> 0
        putWord(result, offset, c0)
        putWord(result, offset + 4, c1)
        putWord(result, offset + 8, c2)
        putWord(result, offset + 12, c3)
        p0 = x0; p1 = x1; p2 = x2; p3 = x3
      }
      xk.fill(0)
      return result
    },
    igeDecrypt: (ciphertext, key, iv) => {
      if (ciphertext.length % BLOCK_BYTES !== 0) throw new RangeError("IGE input must be block aligned")
      const xk = unsafe.expandKeyDecLE(key)
      const result = new Uint8Array(ciphertext.length)
      let c0 = word(iv, 0), c1 = word(iv, 4), c2 = word(iv, 8), c3 = word(iv, 12)
      let p0 = word(iv, 16), p1 = word(iv, 20), p2 = word(iv, 24), p3 = word(iv, 28)
      for (let offset = 0; offset < ciphertext.length; offset += BLOCK_BYTES) {
        const y0 = word(ciphertext, offset), y1 = word(ciphertext, offset + 4)
        const y2 = word(ciphertext, offset + 8), y3 = word(ciphertext, offset + 12)
        const out = unsafe.decrypt(xk, y0 ^ p0, y1 ^ p1, y2 ^ p2, y3 ^ p3)
        p0 = (out.s0 ^ c0) >>> 0
        p1 = (out.s1 ^ c1) >>> 0
        p2 = (out.s2 ^ c2) >>> 0
        p3 = (out.s3 ^ c3) >>> 0
        putWord(result, offset, p0)
        putWord(result, offset + 4, p1)
        putWord(result, offset + 8, p2)
        putWord(result, offset + 12, p3)
        c0 = y0; c1 = y1; c2 = y2; c3 = y3
      }
      xk.fill(0)
      return result
    },
    createCtr: (key, iv): AesCtrState => {
      const xk = unsafe.expandKeyLE(key)
      const counter = iv.slice()
      const keystream = new Uint8Array(BLOCK_BYTES)
      let position = BLOCK_BYTES
      return {
        process: (input) => {
          const output = new Uint8Array(input.length)
          for (let index = 0; index < input.length; index += 1) {
            if (position === BLOCK_BYTES) {
              const out = unsafe.encrypt(xk, word(counter, 0), word(counter, 4), word(counter, 8), word(counter, 12))
              putWord(keystream, 0, out.s0)
              putWord(keystream, 4, out.s1)
              putWord(keystream, 8, out.s2)
              putWord(keystream, 12, out.s3)
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
  }
}
