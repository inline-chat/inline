import { createHash, type Hash } from "node:crypto"
import { INLINE_TRANSFER_PART_SIZE } from "@inline-chat/protocol/transfers"

/**
 * `files.part_hashes`: the 32-byte SHA-256 of each consecutive 512 KiB range of
 * the stored object, concatenated; the last range may be shorter. It anchors
 * GET_FILE_PART digests to what was verified at upload time instead of to the
 * bytes just read back from storage.
 */
export const PART_HASH_BYTES = 32

export const partHashCount = (fileSize: number): number => Math.ceil(fileSize / INLINE_TRANSFER_PART_SIZE)

export const isValidPartHashes = (hashes: Uint8Array | null | undefined, fileSize: number | null): hashes is Uint8Array =>
  hashes !== null && hashes !== undefined && fileSize !== null && Number.isSafeInteger(fileSize) && fileSize > 0 &&
  hashes.byteLength === partHashCount(fileSize) * PART_HASH_BYTES

/** The manifest digest for a range-aligned request, or undefined when the range must be hashed. */
export const alignedPartHash = (
  hashes: Uint8Array,
  fileSize: number,
  offset: number,
  length: number,
): Uint8Array | undefined => {
  if (offset % INLINE_TRANSFER_PART_SIZE !== 0) return undefined
  const expected = Math.min(INLINE_TRANSFER_PART_SIZE, fileSize - offset)
  if (length !== expected || expected <= 0) return undefined
  const index = offset / INLINE_TRANSFER_PART_SIZE
  return hashes.subarray(index * PART_HASH_BYTES, (index + 1) * PART_HASH_BYTES)
}

/** Builds the list from an upload manifest whose parts are exactly the 512 KiB geometry. */
export const partHashesFromManifest = (
  parts: readonly { partIndex: number; byteCount: number; sha256: Uint8Array }[],
  fileSize: number,
): Buffer | undefined => {
  const count = partHashCount(fileSize)
  if (parts.length !== count) return undefined
  const hashes = Buffer.alloc(count * PART_HASH_BYTES)
  for (const [position, part] of parts.entries()) {
    const expected = Math.min(INLINE_TRANSFER_PART_SIZE, fileSize - position * INLINE_TRANSFER_PART_SIZE)
    if (part.partIndex !== position || part.byteCount !== expected || part.sha256.byteLength !== PART_HASH_BYTES) {
      return undefined
    }
    hashes.set(part.sha256, position * PART_HASH_BYTES)
  }
  return hashes
}

/** Hashes a body in 512 KiB ranges as it streams, whatever its chunking. */
export class PartHasher {
  readonly #digests: Buffer[] = []
  #current: Hash = createHash("sha256")
  #currentBytes = 0
  #total = 0

  update(chunk: Uint8Array): void {
    let offset = 0
    while (offset < chunk.byteLength) {
      const take = Math.min(INLINE_TRANSFER_PART_SIZE - this.#currentBytes, chunk.byteLength - offset)
      this.#current.update(chunk.subarray(offset, offset + take))
      this.#currentBytes += take
      this.#total += take
      offset += take
      if (this.#currentBytes === INLINE_TRANSFER_PART_SIZE) {
        this.#digests.push(this.#current.digest())
        this.#current = createHash("sha256")
        this.#currentBytes = 0
      }
    }
  }

  /** Returns the list only when exactly `fileSize` bytes were observed. */
  finish(fileSize: number): Buffer | undefined {
    if (this.#total !== fileSize || fileSize <= 0) return undefined
    if (this.#currentBytes > 0) this.#digests.push(this.#current.digest())
    this.#currentBytes = 0
    return Buffer.concat(this.#digests)
  }
}
