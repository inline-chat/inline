import type { InlineUploadOwner } from "@in/server/db/models/inlineUploads"

/** STORAGE_FRAMES_PER_PART in worker.ts; duplicated to keep this module dependency-free. */
const FRAMES_PER_STORAGE_GROUP = 10
const DEFAULT_MAX_ENTRIES = 4_096

/**
 * Immutable geometry of an uploading native upload plus the part indices this
 * process has seen accepted. Status and expiry stay authoritative in the accept
 * statement; this only avoids re-reading the row per part and detects when a
 * full storage group is ready.
 */
export type UploadGeometry = {
  readonly uploadDbId: number
  readonly byteCount: bigint
  readonly partSize: number
  readonly partCount: number
  readonly hardExpiresAt: Date
  readonly owner: InlineUploadOwner
  readonly storageFormat: string | null
  readonly accepted: Uint8Array
  readonly cachedAt: number
}

const sameOwner = (left: InlineUploadOwner, right: InlineUploadOwner): boolean =>
  left.userId === right.userId &&
  left.accountSessionId === right.accountSessionId &&
  (left.permanentAuthKeyId === undefined
    ? right.permanentAuthKeyId === undefined
    : right.permanentAuthKeyId !== undefined &&
      Buffer.from(left.permanentAuthKeyId).equals(Buffer.from(right.permanentAuthKeyId)))

const keyFor = (uploadId: Uint8Array): string => Buffer.from(uploadId).toString("hex")

export class UploadGeometryCache {
  readonly #entries = new Map<string, UploadGeometry>()

  constructor(
    private readonly now: () => number = () => Date.now(),
    private readonly maxEntries = DEFAULT_MAX_ENTRIES,
  ) {}

  put(input: {
    uploadId: Uint8Array
    uploadDbId: number
    byteCount: bigint
    partSize: number
    partCount: number
    hardExpiresAt: Date
    owner: InlineUploadOwner
    storageFormat: string | null
    acceptedParts: readonly number[]
  }): UploadGeometry {
    const accepted = new Uint8Array(Math.ceil(input.partCount / 8))
    for (const index of input.acceptedParts) {
      if (Number.isInteger(index) && index >= 0 && index < input.partCount) accepted[index >> 3]! |= 1 << (index & 7)
    }
    const geometry: UploadGeometry = {
      uploadDbId: input.uploadDbId,
      byteCount: input.byteCount,
      partSize: input.partSize,
      partCount: input.partCount,
      hardExpiresAt: input.hardExpiresAt,
      owner: {
        userId: input.owner.userId,
        accountSessionId: input.owner.accountSessionId,
        permanentAuthKeyId: input.owner.permanentAuthKeyId?.slice(),
      },
      storageFormat: input.storageFormat,
      accepted,
      cachedAt: this.now(),
    }
    const key = keyFor(input.uploadId)
    this.#entries.delete(key)
    this.#entries.set(key, geometry)
    while (this.#entries.size > this.maxEntries) {
      const oldest = this.#entries.keys().next().value
      if (oldest === undefined) break
      this.#entries.delete(oldest)
    }
    return geometry
  }

  /**
   * Returns cached geometry for this owner. A different owner is reported as a
   * mismatch so the caller can reject it without touching storage.
   */
  get(uploadId: Uint8Array, owner: InlineUploadOwner): UploadGeometry | "owner_mismatch" | undefined {
    const key = keyFor(uploadId)
    const geometry = this.#entries.get(key)
    if (!geometry) return undefined
    if (geometry.hardExpiresAt.getTime() <= this.now()) {
      this.#entries.delete(key)
      return undefined
    }
    if (!sameOwner(geometry.owner, owner)) return "owner_mismatch"
    this.#entries.delete(key)
    this.#entries.set(key, geometry)
    return geometry
  }

  drop(uploadId: Uint8Array): void {
    this.#entries.delete(keyFor(uploadId))
  }

  dropUploadDbId(uploadDbId: number): void {
    for (const [key, geometry] of this.#entries) {
      if (geometry.uploadDbId === uploadDbId) this.#entries.delete(key)
    }
  }

  get size(): number {
    return this.#entries.size
  }
}

export const expectedPartLength = (geometry: Pick<UploadGeometry, "byteCount" | "partSize" | "partCount">, partIndex: number): number =>
  partIndex === geometry.partCount - 1
    ? Number(geometry.byteCount - BigInt(geometry.partSize) * BigInt(geometry.partCount - 1))
    : geometry.partSize

export const isPartAccepted = (geometry: UploadGeometry, partIndex: number): boolean =>
  (geometry.accepted[partIndex >> 3]! & (1 << (partIndex & 7))) !== 0

/**
 * Marks a part accepted. Returns the storage group number (1-based, matching
 * multipart part numbers) when this part completed a full ten-frame group;
 * the tail group is compacted by finish.
 */
export const markPartAccepted = (geometry: UploadGeometry, partIndex: number): number | undefined => {
  if (isPartAccepted(geometry, partIndex)) return undefined
  geometry.accepted[partIndex >> 3]! |= 1 << (partIndex & 7)
  const group = Math.floor(partIndex / FRAMES_PER_STORAGE_GROUP)
  const first = group * FRAMES_PER_STORAGE_GROUP
  if (first + FRAMES_PER_STORAGE_GROUP > geometry.partCount) return undefined
  for (let index = first; index < first + FRAMES_PER_STORAGE_GROUP; index += 1) {
    if (!isPartAccepted(geometry, index)) return undefined
  }
  return group + 1
}
