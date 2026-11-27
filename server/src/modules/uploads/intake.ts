import { Log } from "@in/server/utils/log"
import { uploadTraceLogLevel } from "./trace"

const log = new Log("modules/uploads/intake", uploadTraceLogLevel())

/**
 * Pieces of a part start at a multiple of this many bytes and are a multiple of it long, except the
 * piece that ends the part. Advertised to clients as `CreateUploadResult.piece_granularity`.
 */
export const UPLOAD_PIECE_GRANULARITY = 16 * 1_024

/** Bytes held for storage behind acknowledged replies before new parts wait for their own write. */
export const UPLOAD_INTAKE_MAX_PENDING_BYTES = 96 * 1_024 * 1_024
/** The same bound for one upload, so a crash can cost one file at most this much resending. */
export const UPLOAD_INTAKE_MAX_PENDING_BYTES_PER_UPLOAD = 16 * 1_024 * 1_024
/** Storage writes the intake runs at once; the rest wait in arrival order. */
export const UPLOAD_INTAKE_CONCURRENCY = 32
/** After a storage outage, parts are stored before their reply again for this long. */
export const UPLOAD_INTAKE_STORAGE_BACKOFF_MS = 30_000

/** Memory for parts still arriving in pieces, across all uploads in this process. */
export const UPLOAD_PIECES_MAX_BYTES = 64 * 1_024 * 1_024
/** A part whose pieces stop arriving for this long is dropped; finish reports it missing. */
export const UPLOAD_PIECES_IDLE_MS = 10 * 60_000

/** True when a piece fits the part and the granularity rule. */
export const isValidPiece = (partLength: number, offset: number, length: number): boolean =>
  Number.isSafeInteger(offset) && offset >= 0 && offset % UPLOAD_PIECE_GRANULARITY === 0 &&
  length >= 1 && offset + length <= partLength &&
  (length % UPLOAD_PIECE_GRANULARITY === 0 || offset + length === partLength)

type AssemblingPart = {
  readonly uploadDbId: number
  readonly buffer: Uint8Array
  /** One bit per granule; set when that granule's bytes arrived. */
  readonly arrived: Uint8Array
  missingGranules: number
  touchedAt: number
}

const partKey = (uploadDbId: number, partIndex: number): string => `${uploadDbId}:${partIndex}`

/**
 * Builds whole parts out of pieces. Only memory: a part is not accepted until its last byte
 * arrives, so a dropped or evicted part is simply missing at finish and the client sends it again.
 */
export class UploadPieceAssembler {
  readonly #parts = new Map<string, AssemblingPart>()
  #bytes = 0

  constructor(
    private readonly maxBytes = UPLOAD_PIECES_MAX_BYTES,
    private readonly idleMs = UPLOAD_PIECES_IDLE_MS,
    private readonly now: () => number = () => Date.now(),
  ) {}

  get bytes(): number {
    return this.#bytes
  }

  get size(): number {
    return this.#parts.size
  }

  /**
   * Copies a validated piece (see `isValidPiece`) into its part. Returns the whole part when this
   * piece supplied its last missing bytes; the part then leaves the assembler.
   */
  add(uploadDbId: number, partIndex: number, partLength: number, offset: number, data: Uint8Array): Uint8Array | undefined {
    const key = partKey(uploadDbId, partIndex)
    const now = this.now()
    let part = this.#parts.get(key)
    if (part && part.buffer.byteLength !== partLength) {
      this.#remove(key, part)
      part = undefined
    }
    if (part) {
      this.#parts.delete(key)
      this.#parts.set(key, part)
    } else {
      this.#sweep(now)
      this.#makeRoom(partLength)
      const granules = Math.ceil(partLength / UPLOAD_PIECE_GRANULARITY)
      part = {
        uploadDbId,
        buffer: new Uint8Array(partLength),
        arrived: new Uint8Array(Math.ceil(granules / 8)),
        missingGranules: granules,
        touchedAt: now,
      }
      this.#parts.set(key, part)
      this.#bytes += partLength
    }
    part.touchedAt = now
    part.buffer.set(data, offset)
    const first = offset / UPLOAD_PIECE_GRANULARITY
    const end = Math.ceil((offset + data.byteLength) / UPLOAD_PIECE_GRANULARITY)
    for (let granule = first; granule < end; granule += 1) {
      const bit = 1 << (granule & 7)
      if ((part.arrived[granule >> 3]! & bit) !== 0) continue
      part.arrived[granule >> 3]! |= bit
      part.missingGranules -= 1
    }
    if (part.missingGranules > 0) return undefined
    this.#remove(key, part)
    return part.buffer
  }

  /** Forgets every part of an upload (finished, canceled or rejected). */
  drop(uploadDbId: number): void {
    for (const [key, part] of this.#parts) {
      if (part.uploadDbId === uploadDbId) this.#remove(key, part)
    }
  }

  #remove(key: string, part: AssemblingPart): void {
    if (this.#parts.delete(key)) this.#bytes -= part.buffer.byteLength
  }

  #sweep(now: number): void {
    for (const [key, part] of this.#parts) {
      if (now - part.touchedAt < this.idleMs) break
      this.#remove(key, part)
    }
  }

  /** Evicts least recently touched parts until `partLength` more bytes fit. */
  #makeRoom(partLength: number): void {
    for (const [key, part] of this.#parts) {
      if (this.#bytes + partLength <= this.maxBytes) return
      log.debug("UPLOAD_TRACE phase=piece_evict", { bytes: part.buffer.byteLength })
      this.#remove(key, part)
    }
  }
}

type PendingPart = {
  readonly bytes: number
  readonly settled: Promise<void>
}

type PendingUpload = {
  readonly parts: Map<number, PendingPart>
  bytes: number
}

export type UploadPartIntakeOptions = {
  maxPendingBytes?: number
  maxPendingBytesPerUpload?: number
  concurrency?: number
  storageBackoffMs?: number
  now?: () => number
  /** Called when a write behind an acknowledged reply fails; return true for a storage outage. */
  isStorageOutage?: (error: unknown) => boolean
}

/**
 * Acknowledges a part as soon as this process holds its bytes and stores it behind the reply.
 *
 * Storing a part (staging object, then manifest row) takes a few hundred milliseconds, almost all
 * of it the object store's per-request latency. Clients used to wait for it on every part, which
 * made the first progress tick and small parts slow. The reply now means "received": a part this
 * process loses before it is stored (a failed write, a crash) is missing from the manifest, and
 * FINISH_UPLOAD reports it missing so the client sends it again, as it already does for any gap.
 * Finish waits for this process's writes of the upload first, so a healthy upload never sees that.
 *
 * Parts are stored before their reply, as before, when the held bytes would pass the memory bound
 * or shortly after a storage outage, so an outage still reaches clients as a retryable 503.
 */
export class UploadPartIntake {
  readonly #uploads = new Map<number, PendingUpload>()
  readonly #waiting: Array<() => void> = []
  readonly #maxPendingBytes: number
  readonly #maxPendingBytesPerUpload: number
  readonly #concurrency: number
  readonly #storageBackoffMs: number
  readonly #now: () => number
  readonly #isStorageOutage: (error: unknown) => boolean
  #pendingBytes = 0
  #running = 0
  #storeBeforeReplyUntil = 0

  constructor(options: UploadPartIntakeOptions = {}) {
    this.#maxPendingBytes = options.maxPendingBytes ?? UPLOAD_INTAKE_MAX_PENDING_BYTES
    this.#maxPendingBytesPerUpload = options.maxPendingBytesPerUpload ?? UPLOAD_INTAKE_MAX_PENDING_BYTES_PER_UPLOAD
    this.#concurrency = options.concurrency ?? UPLOAD_INTAKE_CONCURRENCY
    this.#storageBackoffMs = options.storageBackoffMs ?? UPLOAD_INTAKE_STORAGE_BACKOFF_MS
    this.#now = options.now ?? (() => Date.now())
    this.#isStorageOutage = options.isStorageOutage ?? (() => false)
  }

  get pendingBytes(): number {
    return this.#pendingBytes
  }

  /** True while this process holds the part for a write that has not settled. */
  isPending(uploadDbId: number, partIndex: number): boolean {
    return this.#uploads.get(uploadDbId)?.parts.has(partIndex) ?? false
  }

  /** Parts of the upload this process holds for storage, ascending. */
  pendingParts(uploadDbId: number): number[] {
    const upload = this.#uploads.get(uploadDbId)
    return upload ? [...upload.parts.keys()].sort((left, right) => left - right) : []
  }

  /**
   * Takes a whole part. `store` runs now and its result is returned when the part must be stored
   * before the reply; otherwise it runs behind the reply and this resolves `{ queued: true }`.
   * A part already held here is acknowledged again without a second write.
   */
  async accept<T>(
    uploadDbId: number,
    partIndex: number,
    bytes: number,
    store: () => Promise<T>,
  ): Promise<{ queued: true } | { queued: false; value: T }> {
    if (this.isPending(uploadDbId, partIndex)) return { queued: true }
    const held = this.#uploads.get(uploadDbId)?.bytes ?? 0
    if (this.#now() < this.#storeBeforeReplyUntil || this.#pendingBytes + bytes > this.#maxPendingBytes ||
        held + bytes > this.#maxPendingBytesPerUpload) {
      try {
        return { queued: false, value: await store() }
      } catch (error) {
        if (this.#isStorageOutage(error)) this.#backOff()
        throw error
      }
    }
    let upload = this.#uploads.get(uploadDbId)
    if (!upload) {
      upload = { parts: new Map(), bytes: 0 }
      this.#uploads.set(uploadDbId, upload)
    }
    this.#pendingBytes += bytes
    upload.bytes += bytes
    const settled = this.#run(store).then(
      () => {},
      (error: unknown) => {
        if (this.#isStorageOutage(error)) this.#backOff()
        log.warn("Upload part write behind its acknowledgement failed", { error, partIndex })
      },
    ).finally(() => {
      this.#pendingBytes -= bytes
      const current = this.#uploads.get(uploadDbId)
      if (current?.parts.get(partIndex)?.settled === settled) {
        current.parts.delete(partIndex)
        current.bytes -= bytes
        if (current.parts.size === 0) this.#uploads.delete(uploadDbId)
      }
    })
    upload.parts.set(partIndex, { bytes, settled })
    return { queued: true }
  }

  /** Waits, at most `timeoutMs`, for this process's writes of the upload to settle. */
  async settle(uploadDbId: number, timeoutMs: number): Promise<boolean> {
    const upload = this.#uploads.get(uploadDbId)
    if (!upload || upload.parts.size === 0) return true
    return await settlesWithin(Promise.all([...upload.parts.values()].map(({ settled }) => settled)), timeoutMs)
  }

  /** Waits, at most `timeoutMs`, for every write behind a reply (shutdown). */
  async drain(timeoutMs: number): Promise<boolean> {
    const pending = [...this.#uploads.values()].flatMap(({ parts }) => [...parts.values()].map(({ settled }) => settled))
    if (pending.length === 0) return true
    const drained = await settlesWithin(Promise.all(pending), timeoutMs)
    if (!drained) log.warn("Upload part writes still pending at shutdown", { bytes: this.#pendingBytes })
    return drained
  }

  #backOff(): void {
    this.#storeBeforeReplyUntil = this.#now() + this.#storageBackoffMs
  }

  async #run<T>(store: () => Promise<T>): Promise<T> {
    if (this.#running >= this.#concurrency) {
      await new Promise<void>((resume) => this.#waiting.push(resume))
    } else {
      this.#running += 1
    }
    try {
      return await store()
    } finally {
      const next = this.#waiting.shift()
      if (next) next()
      else this.#running -= 1
    }
  }
}

const settlesWithin = async (promise: Promise<unknown>, timeoutMs: number): Promise<boolean> => {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      promise.then(() => true, () => true),
      new Promise<boolean>((resolve) => { timer = setTimeout(() => resolve(false), timeoutMs) }),
    ])
  } finally {
    if (timer) clearTimeout(timer)
  }
}
