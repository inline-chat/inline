import { dlopen, FFIType, ptr } from "bun:ffi"
import { randomBytes } from "node:crypto"
import { setAesBackend, type AesBackend } from "@inline-chat/protocol/secure"
import { nodeAesBackend } from "@inline-chat/protocol/secure/node"

/**
 * AES-IGE decryption is sequential (each block's input depends on the previous plaintext), so the
 * JS backend makes one cipher call per 16-byte block: about 16 ms of event-loop time per 512 KiB
 * record, which every file part sent to the server pays. OpenSSL's AES_ige_encrypt does the same
 * work natively in about 1.6 ms. Encryption already runs as one CBC pass and stays in JS.
 *
 * The native path is optional: if libcrypto is missing or fails its self-test against the JS
 * implementation, the server keeps the JS backend.
 */

/** OpenSSL's AES_KEY is 244 bytes; leave room. */
const AES_KEY_BYTES = 256
const BLOCK_BYTES = 16

export type NativeAesStatus =
  | { kind: "native"; library: string }
  | { kind: "fallback"; reason: string }

type IgeDecrypt = AesBackend["igeDecrypt"]

const defaultCandidates = (): string[] => {
  const configured = process.env["INLINE_LIBCRYPTO_PATH"]
  if (configured) return [configured]
  if (process.platform === "darwin") {
    return ["/opt/homebrew/lib/libcrypto.dylib", "/usr/local/lib/libcrypto.dylib"]
  }
  return ["libcrypto.so.3", "libcrypto.so"]
}

const openLibrary = (path: string) =>
  dlopen(path, {
    AES_set_decrypt_key: { args: [FFIType.ptr, FFIType.i32, FFIType.ptr], returns: FFIType.i32 },
    AES_ige_encrypt: {
      args: [FFIType.ptr, FFIType.ptr, FFIType.u64, FFIType.ptr, FFIType.ptr, FFIType.i32],
      returns: FFIType.void,
    },
  })

const makeDecrypt = (library: ReturnType<typeof openLibrary>): IgeDecrypt => {
  const { AES_set_decrypt_key, AES_ige_encrypt } = library.symbols
  return (ciphertext, key, iv) => {
    // Anything the record layer never sends goes through the reference path unchanged.
    if (key.length !== 32 || iv.length < 2 * BLOCK_BYTES || ciphertext.length === 0 ||
        ciphertext.length % BLOCK_BYTES !== 0) {
      return nodeAesBackend.igeDecrypt(ciphertext, key, iv)
    }
    const schedule = new Uint8Array(AES_KEY_BYTES)
    // OpenSSL advances the IV in place; never touch the caller's copy.
    const ivCopy = iv.slice(0, 2 * BLOCK_BYTES)
    try {
      if (AES_set_decrypt_key(ptr(key), 256, ptr(schedule)) !== 0) {
        return nodeAesBackend.igeDecrypt(ciphertext, key, iv)
      }
      const output = new Uint8Array(ciphertext.length)
      AES_ige_encrypt(ptr(ciphertext), ptr(output), ciphertext.length, ptr(schedule), ptr(ivCopy), 0)
      return output
    } finally {
      schedule.fill(0)
      ivCopy.fill(0)
    }
  }
}

/**
 * True when `decrypt` matches the JS implementation, including on offset views. An odd offset
 * leaves every pointer unaligned, the case OpenSSL handles on a separate path from aligned input.
 */
const selfTest = (decrypt: IgeDecrypt): boolean => {
  for (const offset of [24, 7]) {
    for (const length of [16, 48, 4_096, 64 * 1_024]) {
      const view = (byteCount: number) => new Uint8Array(randomBytes(byteCount + offset)).subarray(offset)
      const key = view(32)
      const iv = view(32)
      const ciphertext = view(length)
      const expected = nodeAesBackend.igeDecrypt(ciphertext, key, iv)
      const actual = decrypt(ciphertext, key, iv)
      if (!Buffer.from(actual).equals(Buffer.from(expected))) return false
    }
  }
  return true
}

/** Loads and verifies native IGE decryption from the first usable library. */
export const loadNativeIgeDecrypt = (
  candidates: readonly string[] = defaultCandidates(),
): { decrypt: IgeDecrypt; library: string } | { reason: string } => {
  const reasons: string[] = []
  for (const path of candidates) {
    let library: ReturnType<typeof openLibrary>
    try {
      library = openLibrary(path)
    } catch (error) {
      reasons.push(`${path}: ${error instanceof Error ? error.message : String(error)}`)
      continue
    }
    const decrypt = makeDecrypt(library)
    let verified = false
    try {
      verified = selfTest(decrypt)
    } catch (error) {
      reasons.push(`${path}: self-test threw ${error instanceof Error ? error.message : String(error)}`)
    }
    if (verified) return { decrypt, library: path }
    if (reasons.length === 0 || !reasons[reasons.length - 1]!.startsWith(path)) {
      reasons.push(`${path}: self-test mismatch`)
    }
    library.close()
  }
  return { reason: reasons.join("; ") || "no candidates" }
}

/** Installs the server AES backend: JS encryption and CTR, native IGE decryption when available. */
export const installServerAesBackend = (
  candidates: readonly string[] = defaultCandidates(),
): NativeAesStatus => {
  const native = process.env["INLINE_NATIVE_AES"] === "0"
    ? { reason: "disabled by INLINE_NATIVE_AES=0" }
    : loadNativeIgeDecrypt(candidates)
  if ("decrypt" in native) {
    setAesBackend({ ...nodeAesBackend, name: "node-crypto+openssl-ige", igeDecrypt: native.decrypt })
    return { kind: "native", library: native.library }
  }
  setAesBackend(nodeAesBackend)
  return { kind: "fallback", reason: native.reason }
}
