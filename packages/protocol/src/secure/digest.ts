import { sha1 } from "@noble/hashes/legacy"
import { sha256 } from "@noble/hashes/sha2"
import { concatBytes, equalBytes } from "./bytes.js"

/**
 * SHA-1 and SHA-256 behind auth key IDs, msg_key and record key derivation. msg_key hashes every
 * record's whole plaintext in both directions: about 2 ms of event-loop time per 512 KiB in pure
 * JS against 0.15 ms through node:crypto. Hosts with node:crypto (Node 20.16+, Bun) use it; others,
 * such as browsers, keep the portable `@noble/hashes` path. Both must be byte-for-byte equal; the
 * conformance vectors and `tests/digest.test.ts` enforce that.
 */
export type DigestAlgorithm = "sha1" | "sha256"
export type Digest = (algorithm: DigestAlgorithm, parts: readonly Uint8Array[]) => Uint8Array

type CreateHash = (algorithm: DigestAlgorithm) => { update(data: Uint8Array): unknown; digest(): Uint8Array }

export const portableDigest: Digest = (algorithm, parts) =>
  (algorithm === "sha1" ? sha1 : sha256)(concatBytes(...parts))

/** Hashes each part in place, so a record's plaintext is never copied into one buffer first. */
export const makeNativeDigest = (createHash: CreateHash): Digest => (algorithm, parts) => {
  const hash = createHash(algorithm)
  for (const part of parts) hash.update(part)
  // Never hand a Buffer to callers: Buffer#slice aliases memory where Uint8Array#slice copies.
  return new Uint8Array(hash.digest())
}

const SELF_TEST_PARTS = [Uint8Array.of(0x61, 0x62), new Uint8Array(0), Uint8Array.of(0x63)]

/**
 * `process.getBuiltinModule` reaches node:crypto without a static import, so browser bundles never
 * see it. A host whose hashes disagree with the portable path on a fixed input keeps the portable one.
 */
export const loadNativeDigest = (): Digest | undefined => {
  try {
    const createHash = globalThis.process?.getBuiltinModule?.("node:crypto")?.createHash
    if (typeof createHash !== "function") return undefined
    const native = makeNativeDigest(createHash)
    for (const algorithm of ["sha1", "sha256"] as const) {
      if (!equalBytes(native(algorithm, SELF_TEST_PARTS), portableDigest(algorithm, SELF_TEST_PARTS))) return undefined
    }
    return native
  } catch {
    return undefined
  }
}

export const nativeDigest = loadNativeDigest()
export const digest: Digest = nativeDigest ?? portableDigest
