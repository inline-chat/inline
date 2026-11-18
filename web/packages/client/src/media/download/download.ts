import { bytesEqual, Sha256 } from "../bytes"
import type { CacheEntry, CacheKey, CacheWriter, MediaCache } from "../cache/media-cache"
import { DOWNLOAD_CHECKPOINT_BYTES, DOWNLOAD_RANGES_IN_FLIGHT, HASH_READ_SIZE, PART_SIZE } from "../constants"
import { canceled, MediaError } from "../types"
import { RepresentationChanged, type RangeResult, type RangeSource } from "./range-source"

export type DownloadProgress = { readonly receivedBytes: number; readonly totalBytes: number }

export type DownloadRequest = {
  readonly key: CacheKey
  readonly source: RangeSource
  /** Size from the message metadata. A different total fails the download. */
  readonly expectedSize?: number
  /** Whole-file SHA-256 when the caller has one; checked before the entry is kept. */
  readonly sha256?: Uint8Array
  readonly signal?: AbortSignal
  readonly onProgress?: (progress: DownloadProgress) => void
  readonly rangesInFlight?: number
  readonly partSize?: number
  readonly checkpointBytes?: number
}

type Outcome = { result: RangeResult; error?: never } | { error: unknown; result?: never }

/**
 * Downloads one file into the cache in ordered ranges, resuming from the
 * partial a previous attempt left. Memory stays at most `rangesInFlight`
 * ranges. Each range must be exactly the bytes asked for; the total must not
 * change; a resume sends the saved validator (`If-Range`), and a changed file
 * restarts from zero once. Checkpoints record the resume point; an abort keeps
 * the bytes up to the last checkpoint.
 */
export const downloadToCache = async (cache: MediaCache, request: DownloadRequest): Promise<CacheEntry> => {
  const existing = cache.entry(request.key)
  if (existing?.complete) return existing
  const signal = request.signal
  if (signal?.aborted) throw canceled()
  const partSize = request.partSize ?? PART_SIZE
  const inFlight = Math.max(1, request.rangesInFlight ?? DOWNLOAD_RANGES_IN_FLIGHT)
  const checkpointBytes = request.checkpointBytes ?? DOWNLOAD_CHECKPOINT_BYTES
  const writer = await cache.beginWrite(request.key)
  let keepPartial = true
  try {
    let restarted = false
    for (;;) {
      try {
        await transfer(writer, request, partSize, inFlight, checkpointBytes)
        break
      } catch (error) {
        if (!(error instanceof RepresentationChanged) || restarted) throw error
        restarted = true
        await writer.restart()
      }
    }
    if (request.sha256) {
      const total = writer.meta?.totalSize ?? 0
      const hash = new Sha256()
      for (let offset = 0; offset < total; offset += HASH_READ_SIZE) {
        if (signal?.aborted) throw canceled()
        const bytes = await writer.read(offset, Math.min(HASH_READ_SIZE, total - offset))
        if (!bytes) throw new MediaError("integrity", "The download could not be read back")
        hash.update(bytes)
      }
      if (!bytesEqual(hash.digest(), request.sha256)) {
        keepPartial = false
        throw new MediaError("integrity", "The downloaded file does not match its digest")
      }
    }
    return await writer.commit()
  } catch (error) {
    if (error instanceof MediaError && (error.code === "integrity" || error.code === "length_mismatch" || error.code === "protocol")) {
      keepPartial = false
    }
    if (keepPartial) await writer.release().catch(() => {})
    else await writer.discard().catch(() => {})
    if (signal?.aborted) throw canceled()
    throw error
  }
}

const transfer = async (
  writer: CacheWriter,
  request: DownloadRequest,
  partSize: number,
  inFlight: number,
  checkpointBytes: number,
): Promise<void> => {
  const signal = request.signal
  let offset = writer.offset
  let total = writer.meta?.totalSize
  const validator = writer.meta?.validator
  if (total !== undefined && request.expectedSize !== undefined && total !== request.expectedSize) {
    throw new MediaError("length_mismatch", "The saved partial is for a different size")
  }
  if (total !== undefined && offset === total && total > 0) return
  const controller = new AbortController()
  const abort = () => controller.abort()
  signal?.addEventListener("abort", abort, { once: true })
  if (signal?.aborted) abort()
  const pending: Promise<Outcome>[] = []
  const fetchAt = (at: number): Promise<Outcome> =>
    request.source.fetchRange(at, partSize, { signal: controller.signal, validator })
      .then((result) => ({ result }), (error: unknown) => ({ error }))
  let lastCheckpoint = offset
  try {
    // The first range alone discovers the size, as `NativeDownloadClient` does.
    let next = offset
    pending.push(fetchAt(next))
    next += partSize
    for (;;) {
      const outcome = await pending.shift()!
      if (signal?.aborted) throw canceled()
      if (outcome.error !== undefined) throw outcome.error
      const result = outcome.result!
      if (total === undefined) {
        total = result.totalSize
        if (!Number.isSafeInteger(total) || total <= 0) throw new MediaError("protocol", "Invalid file size")
        if (request.expectedSize !== undefined && total !== request.expectedSize) {
          throw new MediaError("length_mismatch", "The file is not the size its message says")
        }
        await writer.setMeta({ totalSize: total, validator: result.validator })
      }
      const expected = Math.min(partSize, total - offset)
      if (result.offset !== offset || result.totalSize !== total || result.data.length !== expected) {
        throw new MediaError("length_mismatch", "A range had the wrong offset, length or total")
      }
      if (validator !== undefined && result.validator !== undefined && result.validator !== validator) {
        throw new RepresentationChanged()
      }
      await writer.write(result.data)
      offset += result.data.length
      if (offset - lastCheckpoint >= checkpointBytes || offset === total) {
        await writer.checkpoint()
        lastCheckpoint = offset
      }
      try {
        request.onProgress?.({ receivedBytes: offset, totalBytes: total })
      } catch {
        // Observers do not change the transfer.
      }
      if (offset === total) return
      while (pending.length < inFlight && next < total) {
        pending.push(fetchAt(next))
        next += partSize
      }
      if (pending.length === 0) throw new MediaError("protocol", "Ranges ended before the file did")
    }
  } finally {
    signal?.removeEventListener("abort", abort)
    controller.abort()
    // Every scheduled range settles before ownership returns to the caller.
    await Promise.all(pending)
  }
}
