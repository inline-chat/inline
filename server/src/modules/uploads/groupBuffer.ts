/**
 * Process-local copies of accepted upload frames, kept until the worker
 * compacts their storage group. Staging objects stay the durable source; a
 * miss here (eviction, restart, another process) falls back to staging reads.
 */
export const UPLOAD_GROUP_BUFFER_MAX_BYTES = 128 * 1024 * 1024

type BufferedUpload = {
  frames: Map<number, Uint8Array>
  bytes: number
}

export class UploadGroupBuffer {
  readonly #uploads = new Map<number, BufferedUpload>()
  #bytes = 0

  constructor(private readonly maxBytes = UPLOAD_GROUP_BUFFER_MAX_BYTES) {
    if (!Number.isSafeInteger(maxBytes) || maxBytes < 1) throw new RangeError("Invalid upload group buffer capacity")
  }

  get bytes(): number {
    return this.#bytes
  }

  /** Retains `bytes` without copying; callers must not mutate them afterwards. */
  put(uploadDbId: number, partIndex: number, bytes: Uint8Array): void {
    if (bytes.byteLength > this.maxBytes) return
    const upload = this.#touch(uploadDbId)
    const existing = upload.frames.get(partIndex)
    if (existing) {
      upload.bytes -= existing.byteLength
      this.#bytes -= existing.byteLength
    }
    upload.frames.set(partIndex, bytes)
    upload.bytes += bytes.byteLength
    this.#bytes += bytes.byteLength
    this.#evict(uploadDbId)
  }

  has(uploadDbId: number, partIndex: number): boolean {
    return this.#uploads.get(uploadDbId)?.frames.has(partIndex) ?? false
  }

  hasAll(uploadDbId: number, firstFrameIndex: number, frameCount: number): boolean {
    const upload = this.#uploads.get(uploadDbId)
    if (!upload) return false
    for (let index = firstFrameIndex; index < firstFrameIndex + frameCount; index += 1) {
      if (!upload.frames.has(index)) return false
    }
    return true
  }

  /** Returns copies of a complete run of frames without removing them. */
  peekGroup(uploadDbId: number, firstFrameIndex: number, frameCount: number): Uint8Array[] | undefined {
    if (!this.hasAll(uploadDbId, firstFrameIndex, frameCount)) return undefined
    const upload = this.#touch(uploadDbId)
    return Array.from({ length: frameCount }, (_, offset) => upload.frames.get(firstFrameIndex + offset)!.slice())
  }

  /** Returns copies of a complete run of frames and removes them; undefined leaves the buffer as is. */
  takeGroup(uploadDbId: number, firstFrameIndex: number, frameCount: number): Uint8Array[] | undefined {
    const frames = this.peekGroup(uploadDbId, firstFrameIndex, frameCount)
    if (!frames) return undefined
    const upload = this.#uploads.get(uploadDbId)!
    for (let index = firstFrameIndex; index < firstFrameIndex + frameCount; index += 1) {
      const frame = upload.frames.get(index)!
      upload.frames.delete(index)
      upload.bytes -= frame.byteLength
      this.#bytes -= frame.byteLength
    }
    if (upload.frames.size === 0) this.#uploads.delete(uploadDbId)
    return frames
  }

  drop(uploadDbId: number): void {
    const upload = this.#uploads.get(uploadDbId)
    if (!upload) return
    this.#bytes -= upload.bytes
    this.#uploads.delete(uploadDbId)
  }

  clear(): void {
    this.#uploads.clear()
    this.#bytes = 0
  }

  #touch(uploadDbId: number): BufferedUpload {
    let upload = this.#uploads.get(uploadDbId)
    if (upload) this.#uploads.delete(uploadDbId)
    else upload = { frames: new Map(), bytes: 0 }
    this.#uploads.set(uploadDbId, upload)
    return upload
  }

  /** Evicts whole uploads, least recently touched first, never the one just written. */
  #evict(keep: number): void {
    for (const [uploadDbId, upload] of this.#uploads) {
      if (this.#bytes <= this.maxBytes) return
      if (uploadDbId === keep) continue
      this.#bytes -= upload.bytes
      this.#uploads.delete(uploadDbId)
    }
    if (this.#bytes > this.maxBytes) this.drop(keep)
  }
}

export const uploadGroupBuffer = new UploadGroupBuffer()
