import { createHash } from "node:crypto"
import type { GetFilePartInput, GetFilePartResult } from "@inline-chat/protocol/core"
import { getR2 } from "@in/server/libs/r2"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { FILES_PATH_PREFIX } from "@in/server/config"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"
import { loadFilePartHashes, resolveDownloadFile } from "./downloadAccess"
import { alignedPartHash, isValidPartHashes } from "./partHashes"
import {
  emptyTransferCounters,
  recordStorageOperation,
  transferTraces,
  withTransferCounters,
} from "@in/server/modules/transfers/trace"
import { readFileBytes } from "./readFileBytes"
import { INLINE_TRANSFER_MAX_LOCATOR_ID, INLINE_TRANSFER_PART_SIZE } from "@inline-chat/protocol/transfers"
import type { DbFile } from "@in/server/db/schema"
import { Log, LogLevel } from "@in/server/utils/log"

export const MAX_DOWNLOAD_PART_SIZE = INLINE_TRANSFER_PART_SIZE
const MAX_DOWNLOADS_PER_SESSION = 16
// Admission counts requested bytes, not ranges: 512 ranges of 512 KiB.
export const MAX_DOWNLOAD_BYTES_IN_FLIGHT = 256 * 1024 * 1024
// Leave time for a useful RPC error before the Apple client's 30-second deadline.
const DEFAULT_DOWNLOAD_PART_TIMEOUT_MS = 25_000
const AUTHORIZATION_CACHE_TTL_MS = 60_000
const AUTHORIZATION_CACHE_MAX_ENTRIES = 4_096
const AUTHORIZATION_CACHE_MAX_ENTRIES_PER_SESSION = 64
// One storage read serves eight 512 KiB ranges of a sequential download.
export const DOWNLOAD_READAHEAD_BYTES = 4 * 1024 * 1024
const DOWNLOAD_READAHEAD_MAX_BYTES = 128 * 1024 * 1024

export type DownloadPartTrace = {
  authorizationMs: number
  storageMs: number
  bytes: number
  carrier: "V2" | "V3"
  cacheHit: boolean
  readAheadHit: boolean
  manifestDigest: boolean
  sqlStatements: number
  outcome: "ok" | "failed" | "timeout" | "canceled"
}

type NativeDownloadOptions = {
  now?: () => number
  maxEntries?: number
  maxEntriesPerSession?: number
  trace?: (trace: DownloadPartTrace) => void
  loadPartHashes?: (fileId: number) => Promise<Uint8Array | undefined>
  readAheadBytes?: number
  readAheadMaxBytes?: number
  maxBytesInFlight?: number
  hashRange?: (data: Uint8Array) => Uint8Array
}

type CachedAuthorization = {
  file: DbFile
  partHashes: Uint8Array | undefined
  expiresAt: number
  session: string
}

type AuthorizedDownload = {
  file: DbFile | undefined
  partHashes: Uint8Array | undefined
  expiresAt: number
  cacheHit: boolean
}

type ReadAheadWindow = {
  readonly offset: number
  readonly length: number
  /** The window never outlives the authorization that admitted its first read. */
  readonly validUntil: number
  bytes?: Uint8Array
  inflight?: Promise<Uint8Array>
  /** Ranges awaiting `inflight`; the read is aborted when the last one leaves. */
  waiters: number
  readonly controller: AbortController
}

type DownloadProgress = { eof: boolean; served: Set<number> }

const downloadTraceLog = new Log("NativeDownload", LogLevel.DEBUG)
const traceRange = (trace: DownloadPartTrace): void => {
  // A single whitelisted JSON line avoids multi-line provider/object logging.
  // No file/message/account identifiers, paths, keys or raw errors are included.
  downloadTraceLog.debug(`DOWNLOAD_TRACE ${JSON.stringify(trace)}`)
}

const checkAbort = (signal?: AbortSignal) => signal?.throwIfAborted()

const readFromStorage = async (path: string, offset: number, length: number, signal?: AbortSignal) => {
  checkAbort(signal)
  const r2 = getR2()
  if (!r2) throw RealtimeRpcError.InternalError()
  recordStorageOperation("get")
  return readFileBytes(r2.file(path).slice(offset, offset + length).stream(), length, signal)
}

const sha256 = (data: Uint8Array): Uint8Array => createHash("sha256").update(data).digest()


export class NativeDownloadOperations {
  #bytesInFlight = 0
  #readAheadBytes = 0
  readonly #sessions = new Map<number, number>()
  readonly #authorizations = new Map<string, CachedAuthorization>()
  readonly #windows = new Map<string, ReadAheadWindow>()
  readonly #progress = new WeakMap<object, DownloadProgress>()
  readonly #now: () => number
  readonly #maxCacheEntries: number
  readonly #maxSessionCacheEntries: number
  readonly #trace: ((trace: DownloadPartTrace) => void) | undefined
  readonly #loadPartHashes: (fileId: number) => Promise<Uint8Array | undefined>
  readonly #windowBytes: number
  readonly #maxReadAheadBytes: number
  readonly #maxBytesInFlight: number
  readonly #hashRange: (data: Uint8Array) => Uint8Array

  constructor(
    private readonly resolveFile = resolveDownloadFile,
    private readonly readRange = readFromStorage,
    private readonly partTimeoutMs = DEFAULT_DOWNLOAD_PART_TIMEOUT_MS,
    options: NativeDownloadOptions = {},
  ) {
    if (!Number.isSafeInteger(partTimeoutMs) || partTimeoutMs < 1) {
      throw new RangeError("Invalid download part timeout")
    }
    // A monotonic clock keeps wall-clock correction from extending revocation lag.
    this.#now = options.now ?? (() => performance.now())
    this.#maxCacheEntries = options.maxEntries ?? AUTHORIZATION_CACHE_MAX_ENTRIES
    this.#maxSessionCacheEntries = options.maxEntriesPerSession ?? AUTHORIZATION_CACHE_MAX_ENTRIES_PER_SESSION
    this.#trace = options.trace ?? (process.env["INLINE_DOWNLOAD_TRACE"] === "1" ? traceRange : undefined)
    this.#loadPartHashes = options.loadPartHashes ?? loadFilePartHashes
    this.#windowBytes = options.readAheadBytes ?? DOWNLOAD_READAHEAD_BYTES
    this.#maxReadAheadBytes = options.readAheadMaxBytes ?? DOWNLOAD_READAHEAD_MAX_BYTES
    this.#maxBytesInFlight = options.maxBytesInFlight ?? MAX_DOWNLOAD_BYTES_IN_FLIGHT
    this.#hashRange = options.hashRange ?? sha256
    if (![this.#maxCacheEntries, this.#maxSessionCacheEntries].every((limit) => Number.isSafeInteger(limit) && limit > 0)) {
      throw new RangeError("Invalid download authorization cache limit")
    }
    if (![this.#windowBytes, this.#maxReadAheadBytes, this.#maxBytesInFlight]
      .every((limit) => Number.isSafeInteger(limit) && limit > 0) ||
        this.#windowBytes % INLINE_TRANSFER_PART_SIZE !== 0) {
      throw new RangeError("Invalid download read-ahead or admission budget")
    }
  }

  get readAheadBytes(): number {
    return this.#readAheadBytes
  }

  async #resolveAuthorizedFile(
    input: GetFilePartInput,
    context: HandlerContext,
    signal: AbortSignal,
  ): Promise<AuthorizedDownload> {
    const session = `${context.userId}:${context.sessionId}`
    const key = `${session}:${input.fileUniqueId}:${input.message?.chatId ?? ""}:${input.message?.messageId ?? ""}`
    const now = this.#now()
    const cached = this.#authorizations.get(key)
    if (cached && cached.expiresAt > now) {
      // LRU eviction does not extend the authorization lifetime.
      this.#authorizations.delete(key)
      this.#authorizations.set(key, cached)
      return { file: cached.file, partHashes: cached.partHashes, expiresAt: cached.expiresAt, cacheHit: true }
    }
    this.#authorizations.delete(key)
    const file = await this.resolveFile(input.fileUniqueId, context.userId, input.message)
    checkAbort(signal)
    // Start the TTL before the lookup so a slow query cannot increase the
    // accepted revocation lag. Missing/inaccessible results are never cached.
    const expiresAt = now + AUTHORIZATION_CACHE_TTL_MS
    if (!file) return { file, partHashes: undefined, expiresAt, cacheHit: false }
    const loadedHashes = Number.isSafeInteger(file.id) && file.id > 0 ? await this.#loadPartHashes(file.id) : undefined
    checkAbort(signal)
    const partHashes = isValidPartHashes(loadedHashes, file.fileSize) ? loadedHashes : undefined
    if (expiresAt <= this.#now()) return { file, partHashes, expiresAt, cacheHit: false }
    // Another range may have populated this key while the lookup was pending.
    // Replacing that one entry must not evict a different session/file grant.
    this.#authorizations.delete(key)
    let sessionEntries = 0
    const currentTime = this.#now()
    for (const [cachedKey, authorization] of this.#authorizations) {
      if (authorization.expiresAt <= currentTime) this.#authorizations.delete(cachedKey)
      else if (authorization.session === session) sessionEntries += 1
    }
    if (sessionEntries >= this.#maxSessionCacheEntries) {
      for (const [cachedKey, authorization] of this.#authorizations) {
        if (authorization.session === session) {
          this.#authorizations.delete(cachedKey)
          break
        }
      }
    }
    if (this.#authorizations.size >= this.#maxCacheEntries) {
      const oldest = this.#authorizations.keys().next().value
      if (oldest !== undefined) this.#authorizations.delete(oldest)
    }
    this.#authorizations.set(key, { file, partHashes, expiresAt, session })
    return { file, partHashes, expiresAt, cacheHit: false }
  }

  /**
   * Serves a range from the per-(session, file) read-ahead window, reading the
   * aligned window from storage on a miss. Concurrent ranges in one window share
   * its single read; any error drops the window.
   */
  async #readThroughWindow(input: {
    key: string
    path: string
    fileSize: number
    offset: number
    length: number
    validUntil: number
    signal: AbortSignal
  }): Promise<{ data: Uint8Array; hit: boolean }> {
    const { key, offset, length } = input
    const now = this.#now()
    let window = this.#windows.get(key)
    if (window && (window.validUntil <= now || offset < window.offset ||
        offset + length > window.offset + window.length)) {
      this.#dropWindow(key)
      window = undefined
    }
    const hit = window !== undefined
    if (window) {
      this.#windows.delete(key)
      this.#windows.set(key, window)
    } else {
      const start = offset - (offset % this.#windowBytes)
      const windowLength = Math.min(this.#windowBytes, input.fileSize - start)
      if (offset + length > start + windowLength || windowLength > this.#maxReadAheadBytes) {
        // An unaligned range across a window boundary reads exactly what it asked for.
        return { data: await this.readRange(input.path, offset, length, input.signal), hit: false }
      }
      const created: ReadAheadWindow = {
        offset: start, length: windowLength, validUntil: input.validUntil, waiters: 0, controller: new AbortController(),
      }
      this.#readAheadBytes += windowLength
      created.inflight = this.readRange(input.path, start, windowLength, created.controller.signal)
        .then((bytes) => {
          if (bytes.byteLength !== windowLength) throw RealtimeRpcError.InternalError()
          if (this.#windows.get(key) === created) {
            created.bytes = bytes
            created.inflight = undefined
          }
          return bytes
        }, (error: unknown) => {
          if (this.#windows.get(key) === created) this.#dropWindow(key)
          throw error
        })
      window = created
      this.#windows.set(key, created)
      this.#evictWindows(key)
    }
    const bytes = window.bytes ?? await this.#awaitWindow(key, window, input.signal)
    return { data: bytes.subarray(offset - window.offset, offset - window.offset + length), hit }
  }

  /**
   * The last waiting range to leave aborts the shared read with its own reason
   * and still awaits its settlement, exactly like an unshared read. Earlier
   * waiters leave at once; the read continues for the others.
   */
  async #awaitWindow(key: string, window: ReadAheadWindow, signal: AbortSignal): Promise<Uint8Array> {
    checkAbort(signal)
    window.waiters += 1
    let left = false
    let rejectEarly!: (reason: unknown) => void
    const early = new Promise<never>((_, reject) => { rejectEarly = reject })
    const onAbort = () => {
      if (left) return
      left = true
      window.waiters -= 1
      if (window.waiters > 0) {
        rejectEarly(signal.reason)
        return
      }
      if (this.#windows.get(key) === window) this.#dropWindow(key)
      window.controller.abort(signal.reason)
    }
    signal.addEventListener("abort", onAbort, { once: true })
    try {
      return await Promise.race([window.inflight!, early])
    } finally {
      signal.removeEventListener("abort", onAbort)
      if (!left) window.waiters -= 1
    }
  }

  #dropWindow(key: string): void {
    const window = this.#windows.get(key)
    if (!window) return
    this.#windows.delete(key)
    this.#readAheadBytes -= window.length
  }

  #evictWindows(keep: string): void {
    for (const key of this.#windows.keys()) {
      if (this.#readAheadBytes <= this.#maxReadAheadBytes) return
      if (key !== keep) this.#dropWindow(key)
    }
  }

  async getPart(input: GetFilePartInput, context: HandlerContext): Promise<GetFilePartResult> {
    // Both carriers supply the authenticated account and session. File and
    // message authorization below remains independent of the transport.
    if (!Number.isSafeInteger(context.userId) || context.userId <= 0 ||
        !Number.isSafeInteger(context.sessionId) || context.sessionId <= 0) {
      throw RealtimeRpcError.Unauthenticated()
    }
    if (!/^[A-Za-z0-9_-]{6,128}$/.test(input.fileUniqueId) ||
        input.offset < 0n || input.offset > BigInt(Number.MAX_SAFE_INTEGER) ||
        !Number.isInteger(input.limit) || input.limit < 1 || input.limit > MAX_DOWNLOAD_PART_SIZE ||
        (input.message && [input.message.chatId, input.message.messageId].some(
          (id) => id <= 0n || id > INLINE_TRANSFER_MAX_LOCATOR_ID,
        ))) throw RealtimeRpcError.BadRequest()
    checkAbort(context.signal)
    const active = this.#sessions.get(context.sessionId) ?? 0
    if (active >= MAX_DOWNLOADS_PER_SESSION || this.#bytesInFlight + input.limit > this.#maxBytesInFlight) {
      throw RealtimeRpcError.RateLimit()
    }
    this.#bytesInFlight += input.limit
    this.#sessions.set(context.sessionId, active + 1)
    const traceKey = `download:${context.userId}:${context.sessionId}:${input.fileUniqueId}`
    const transfer = transferTraces.touch(traceKey, "download", context.inlineProtocol ? "v3" : "v2")
    let progress = this.#progress.get(transfer)
    if (!progress) {
      progress = { eof: false, served: new Set() }
      this.#progress.set(transfer, progress)
    }
    let result: GetFilePartResult | undefined
    try {
      result = await transferTraces.part(traceKey, transfer, input.limit, () => this.#servePart(input, context, traceKey))
      return result
    } finally {
      this.#bytesInFlight -= input.limit
      const remaining = (this.#sessions.get(context.sessionId) ?? 1) - 1
      if (remaining === 0) this.#sessions.delete(context.sessionId)
      else this.#sessions.set(context.sessionId, remaining)
      if (result && result.data.length > 0) {
        const offset = Number(result.offset)
        if (progress.served.has(offset)) transfer.retries += 1
        else if (progress.served.size < 4_096) progress.served.add(offset)
        transfer.parts += 1
        transfer.bytes += result.data.length
        if (offset + result.data.length >= Number(result.totalSize)) progress.eof = true
      }
      if (progress.eof && transfer.inFlightBytes === 0) transferTraces.finish(traceKey, "eof")
    }
  }

  async #servePart(input: GetFilePartInput, context: HandlerContext, readAheadKey: string): Promise<GetFilePartResult> {
    // Legacy V2 has no application deadline. Bound storage reads on both carriers
    // and retain V3 cancellation, including while the R2 stream is being read.
    const deadline = new AbortController()
    const timer = setTimeout(() => {
      deadline.abort(new DOMException("File download part timed out", "TimeoutError"))
    }, this.partTimeoutMs)
    timer.unref()
    const signal = context.signal ? AbortSignal.any([context.signal, deadline.signal]) : deadline.signal
    const counters = this.#trace ? emptyTransferCounters() : undefined
    const trace: DownloadPartTrace | undefined = this.#trace ? {
      authorizationMs: 0, storageMs: 0, bytes: 0,
      carrier: context.inlineProtocol ? "V3" : "V2", cacheHit: false, readAheadHit: false,
      manifestDigest: false, sqlStatements: 0, outcome: "failed",
    } : undefined
    const run = async (): Promise<GetFilePartResult> => {
      // Keep admission owned while the database lookup settles. An expired
      // deadline prevents starting a storage read after that lookup returns.
      const authorizationStartedAt = trace ? this.#now() : 0
      let authorized: AuthorizedDownload
      try {
        authorized = await this.#resolveAuthorizedFile(input, context, signal)
        if (trace) trace.cacheHit = authorized.cacheHit
      } finally {
        if (trace) trace.authorizationMs = Math.max(0, this.#now() - authorizationStartedAt)
      }
      checkAbort(signal)
      const file = authorized.file
      // Unknown and inaccessible IDs have exactly the same response.
      if (!file) throw RealtimeRpcError.BadRequest()
      const size = file.fileSize
      if (size === null || !Number.isSafeInteger(size) || size <= 0 ||
          !file.pathEncrypted || !file.pathIv || !file.pathTag) throw RealtimeRpcError.BadRequest()
      if (input.offset > BigInt(size)) throw RealtimeRpcError.BadRequest()
      const offset = Number(input.offset)
      const length = Math.min(input.limit, size - offset)
      const path = decrypt({ encrypted: file.pathEncrypted, iv: file.pathIv, authTag: file.pathTag })
      const storageStartedAt = trace ? this.#now() : 0
      let data: Uint8Array
      try {
        if (length === 0) data = new Uint8Array()
        else {
          const read = await this.#readThroughWindow({
            key: readAheadKey,
            path: `${FILES_PATH_PREFIX}/${path}`,
            fileSize: size,
            offset,
            length,
            validUntil: authorized.expiresAt,
            signal,
          })
          data = read.data
          if (trace) trace.readAheadHit = read.hit
        }
        if (trace) trace.bytes = data.length
      } finally {
        if (trace) trace.storageMs = Math.max(0, this.#now() - storageStartedAt)
      }
      checkAbort(signal)
      if (data.length !== length) throw RealtimeRpcError.InternalError()
      // Clients verify sha256(data) against this digest. When the upload recorded
      // range hashes, a storage-side substitution therefore fails on the client.
      const manifestDigest = authorized.partHashes && length > 0
        ? alignedPartHash(authorized.partHashes, size, offset, length)
        : undefined
      if (trace) trace.manifestDigest = manifestDigest !== undefined
      const digest = manifestDigest ? Uint8Array.from(manifestDigest) : this.#hashRange(data)
      if (trace) trace.outcome = "ok"
      return { offset: input.offset, totalSize: BigInt(size), data, sha256: digest }
    }
    try {
      return counters ? await withTransferCounters(counters, run) : await run()
    } catch (error) {
      // A failed read must not leave a window that later ranges would trust.
      this.#dropWindow(readAheadKey)
      // Only this operation's deadline is a retryable range timeout. A carrier
      // cancellation (including its own TimeoutError) keeps its original reason.
      if (deadline.signal.aborted && signal.reason === deadline.signal.reason && error === deadline.signal.reason) {
        if (trace) trace.outcome = "timeout"
        throw RealtimeRpcError.RequestTimeout("File download part timed out")
      }
      if (trace && signal.aborted && error === signal.reason) trace.outcome = "canceled"
      throw error
    } finally {
      clearTimeout(timer)
      if (trace) {
        trace.sqlStatements = counters?.sqlStatements ?? 0
        try { this.#trace?.(trace) } catch {
          // Optional diagnostics must not affect range results or slot release.
        }
      }
    }
  }
}

export const nativeDownloadOperations = new NativeDownloadOperations()
