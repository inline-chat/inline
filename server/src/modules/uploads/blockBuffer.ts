/**
 * Parts of `blocks_v1` uploads this process holds until their block is written to storage. These
 * bytes exist nowhere else, so nothing here is evicted to make room: a part that does not fit is
 * refused (the client backs off and resends). An upload idle past `idleMs` is dropped; its parts
 * then read as missing and the client resends them, at most one block back.
 */
export const UPLOAD_BLOCK_BUFFER_MAX_BYTES = 256 * 1024 * 1024
export const UPLOAD_BLOCK_BUFFER_IDLE_MS = 10 * 60_000
/**
 * Bytes one upload may hold. A client keeps a few parts in flight plus one block being filled;
 * this keeps one sender (blocks it never completes) from filling the buffer for everyone.
 */
export const UPLOAD_BLOCK_BUFFER_MAX_UPLOAD_BYTES = 32 * 1024 * 1024
const SWEEP_INTERVAL_MS = 60_000

export type HeldPart = {
  readonly bytes: Uint8Array
  readonly sha256: Uint8Array
}

/** A part shorter than the part size, sent while the size was unknown: the file's last. */
export type StreamEnd = { readonly partIndex: number; readonly byteCount: number }

type HeldUpload = {
  parts: Map<number, HeldPart>
  bytes: number
  touchedAt: number
  end?: StreamEnd
}

export class UploadBlockBuffer {
  readonly #uploads = new Map<number, HeldUpload>()
  #bytes = 0
  #lastSweepAt: number

  constructor(
    private readonly maxBytes = UPLOAD_BLOCK_BUFFER_MAX_BYTES,
    private readonly idleMs = UPLOAD_BLOCK_BUFFER_IDLE_MS,
    private readonly now: () => number = Date.now,
    private readonly maxUploadBytes = UPLOAD_BLOCK_BUFFER_MAX_UPLOAD_BYTES,
  ) {
    if (!Number.isSafeInteger(maxBytes) || maxBytes < 1) throw new RangeError("Invalid upload block buffer capacity")
    this.#lastSweepAt = now()
  }

  get bytes(): number {
    return this.#bytes
  }

  /** Retains `bytes` without copying; callers must not mutate them afterwards. */
  hold(uploadDbId: number, partIndex: number, part: HeldPart): "held" | "present" | "full" {
    const now = this.now()
    if (now - this.#lastSweepAt >= SWEEP_INTERVAL_MS) this.sweep(now)
    let upload = this.#uploads.get(uploadDbId)
    if (upload?.parts.has(partIndex)) {
      upload.touchedAt = now
      return "present"
    }
    if (this.#bytes + part.bytes.byteLength > this.maxBytes ||
        (upload?.bytes ?? 0) + part.bytes.byteLength > this.maxUploadBytes) return "full"
    if (!upload) {
      upload = { parts: new Map(), bytes: 0, touchedAt: now }
      this.#uploads.set(uploadDbId, upload)
    }
    upload.parts.set(partIndex, part)
    upload.bytes += part.bytes.byteLength
    upload.touchedAt = now
    this.#bytes += part.bytes.byteLength
    return "held"
  }

  /** The upload's last part, when it arrived here while the size was unknown. */
  end(uploadDbId: number): StreamEnd | undefined {
    return this.#uploads.get(uploadDbId)?.end
  }

  /** Records the last part; it is held (`hold`) in the same call, so the upload has an entry. */
  setEnd(uploadDbId: number, end: StreamEnd): void {
    const upload = this.#uploads.get(uploadDbId)
    if (upload) upload.end = end
  }

  has(uploadDbId: number, partIndex: number): boolean {
    return this.#uploads.get(uploadDbId)?.parts.has(partIndex) ?? false
  }

  heldParts(uploadDbId: number): number[] {
    const upload = this.#uploads.get(uploadDbId)
    return upload ? [...upload.parts.keys()].sort((left, right) => left - right) : []
  }

  /** The parts `first ..< first + count` in order, or undefined unless every one is held. */
  peek(uploadDbId: number, first: number, count: number): HeldPart[] | undefined {
    const upload = this.#uploads.get(uploadDbId)
    if (!upload) return undefined
    const parts: HeldPart[] = []
    for (let index = first; index < first + count; index++) {
      const part = upload.parts.get(index)
      if (!part) return undefined
      parts.push(part)
    }
    return parts
  }

  /** Forgets parts once their block is stored. */
  release(uploadDbId: number, first: number, count: number): void {
    const upload = this.#uploads.get(uploadDbId)
    if (!upload) return
    for (let index = first; index < first + count; index++) {
      const part = upload.parts.get(index)
      if (!part) continue
      upload.parts.delete(index)
      upload.bytes -= part.bytes.byteLength
      this.#bytes -= part.bytes.byteLength
    }
    // The stream end outlives its part until the finish has named the size.
    if (upload.parts.size === 0 && !upload.end) this.#uploads.delete(uploadDbId)
  }

  /** Forgets the stream end once the size is set; the upload's entry goes with its last part. */
  clearEnd(uploadDbId: number): void {
    const upload = this.#uploads.get(uploadDbId)
    if (!upload) return
    upload.end = undefined
    if (upload.parts.size === 0) this.#uploads.delete(uploadDbId)
  }

  drop(uploadDbId: number): void {
    const upload = this.#uploads.get(uploadDbId)
    if (!upload) return
    this.#uploads.delete(uploadDbId)
    this.#bytes -= upload.bytes
  }

  sweep(now = this.now()): void {
    this.#lastSweepAt = now
    for (const [uploadDbId, upload] of this.#uploads) {
      if (now - upload.touchedAt >= this.idleMs) this.drop(uploadDbId)
    }
  }
}

export const uploadBlockBuffer = new UploadBlockBuffer()
