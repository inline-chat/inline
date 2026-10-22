/**
 * Native AES backend for Node.js and Bun (`node:crypto`). Server and SDK entry
 * points install it once at startup with `installNodeAesBackend()`. The portable
 * `aesPure.ts` backend remains the reference; this one must match it exactly.
 */
import { createCipheriv, createDecipheriv } from "node:crypto"
import { setAesBackend, type AesBackend, type AesCtrState } from "./aesBackend.js"

const BLOCK_BYTES = 16

const toUint8Array = (buffer: Uint8Array): Uint8Array => {
  // Never hand a Buffer to callers: Buffer#slice aliases memory where
  // Uint8Array#slice copies, and record parsing relies on copies.
  const copy = new Uint8Array(buffer.byteLength)
  copy.set(buffer)
  return copy
}

/**
 * IGE encryption through one CBC pass (the construction TDLib uses):
 *   c_i = E(p_i ⊕ c_{i-1}) ⊕ p_{i-1}
 * With x_i = p_i ⊕ p_{i-2} (p_{-2} = 0, p_{-1} = iv[16..32]) and CBC IV = iv[0..16],
 * CBC yields y_i = E(x_i ⊕ y_{i-1}) = E(p_i ⊕ c_{i-1}), so c_i = y_i ⊕ p_{i-1}.
 */
const igeEncrypt = (plaintext: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array => {
  const length = plaintext.length
  const input = new Uint8Array(length)
  input.set(plaintext.subarray(0, Math.min(BLOCK_BYTES, length)))
  for (let index = BLOCK_BYTES; index < Math.min(2 * BLOCK_BYTES, length); index += 1) {
    input[index] = plaintext[index]! ^ iv[index]!
  }
  for (let index = 2 * BLOCK_BYTES; index < length; index += 1) {
    input[index] = plaintext[index]! ^ plaintext[index - 2 * BLOCK_BYTES]!
  }
  const cipher = createCipheriv("aes-256-cbc", key, iv.subarray(0, BLOCK_BYTES))
  cipher.setAutoPadding(false)
  const chained = cipher.update(input)
  const tail = cipher.final()
  if (chained.length !== length || tail.length !== 0) throw new RangeError("AES-CBC produced an unexpected length")
  const output = new Uint8Array(length)
  for (let index = 0; index < Math.min(BLOCK_BYTES, length); index += 1) {
    output[index] = chained[index]! ^ iv[BLOCK_BYTES + index]!
  }
  for (let index = BLOCK_BYTES; index < length; index += 1) {
    output[index] = chained[index]! ^ plaintext[index - BLOCK_BYTES]!
  }
  return output
}

/** IGE decryption is inherently sequential: p_i = D(c_i ⊕ p_{i-1}) ⊕ c_{i-1}. One key schedule, one ECB call per block. */
const igeDecrypt = (ciphertext: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array => {
  const length = ciphertext.length
  const decipher = createDecipheriv("aes-256-ecb", key, null)
  decipher.setAutoPadding(false)
  const output = new Uint8Array(length)
  const scratch = new Uint8Array(BLOCK_BYTES)
  let previousCipher = iv.subarray(0, BLOCK_BYTES)
  let previousPlain = iv.subarray(BLOCK_BYTES, 2 * BLOCK_BYTES)
  for (let offset = 0; offset < length; offset += BLOCK_BYTES) {
    for (let index = 0; index < BLOCK_BYTES; index += 1) {
      scratch[index] = ciphertext[offset + index]! ^ previousPlain[index]!
    }
    const decrypted = decipher.update(scratch)
    if (decrypted.length !== BLOCK_BYTES) throw new RangeError("AES-ECB produced an unexpected length")
    for (let index = 0; index < BLOCK_BYTES; index += 1) {
      output[offset + index] = decrypted[index]! ^ previousCipher[index]!
    }
    previousCipher = ciphertext.subarray(offset, offset + BLOCK_BYTES)
    previousPlain = output.subarray(offset, offset + BLOCK_BYTES)
  }
  if (decipher.final().length !== 0) throw new RangeError("AES-ECB produced trailing bytes")
  return output
}

const createCtr = (key: Uint8Array, iv: Uint8Array): AesCtrState => {
  // node:crypto keeps the 128-bit big-endian counter and keystream position across calls.
  const cipher = createCipheriv("aes-256-ctr", key, iv)
  return { process: (input) => toUint8Array(cipher.update(input)) }
}

export const nodeAesBackend: AesBackend = {
  name: "node-crypto",
  igeEncrypt,
  igeDecrypt,
  createCtr,
}

/** Installs the native backend process-wide. Idempotent. */
export const installNodeAesBackend = (): void => {
  setAesBackend(nodeAesBackend)
}
