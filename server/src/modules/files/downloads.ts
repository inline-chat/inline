import { createHash } from "node:crypto"
import type { GetFilePartInput, GetFilePartResult } from "@inline-chat/protocol/core"
import { getR2 } from "@in/server/libs/r2"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { FILES_PATH_PREFIX } from "@in/server/config"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"
import { resolveDownloadFile } from "./downloadAccess"
import { readFileBytes } from "./readFileBytes"
import { INLINE_TRANSFER_MAX_LOCATOR_ID, INLINE_TRANSFER_PART_SIZE } from "@inline-chat/protocol/transfers"
import type { DbFile } from "@in/server/db/schema"
import { Log, LogLevel } from "@in/server/utils/log"

export const MAX_DOWNLOAD_PART_SIZE = INLINE_TRANSFER_PART_SIZE
const MAX_DOWNLOADS_PER_SESSION = 8
const MAX_CONCURRENT_DOWNLOADS = 64
// Leave time for a useful RPC error before the Apple client's 30-second deadline.
const DEFAULT_DOWNLOAD_PART_TIMEOUT_MS = 25_000
const AUTHORIZATION_CACHE_TTL_MS = 60_000
const AUTHORIZATION_CACHE_MAX_ENTRIES = 4_096
const AUTHORIZATION_CACHE_MAX_ENTRIES_PER_SESSION = 64

export type DownloadPartTrace = {
  authorizationMs: number
  storageMs: number
  bytes: number
  carrier: "V2" | "V3"
  cacheHit: boolean
  outcome: "ok" | "failed" | "timeout" | "canceled"
}

type NativeDownloadOptions = {
  now?: () => number
  maxEntries?: number
  maxEntriesPerSession?: number
  trace?: (trace: DownloadPartTrace) => void
}

type CachedAuthorization = { file: DbFile; expiresAt: number; session: string }

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
  return readFileBytes(r2.file(path).slice(offset, offset + length).stream(), length, signal)
}

export class NativeDownloadOperations {
  #active = 0
  readonly #sessions = new Map<number, number>()
  readonly #authorizations = new Map<string, CachedAuthorization>()
  readonly #now: () => number
  readonly #maxCacheEntries: number
  readonly #maxSessionCacheEntries: number
  readonly #trace: ((trace: DownloadPartTrace) => void) | undefined

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
    if (![this.#maxCacheEntries, this.#maxSessionCacheEntries].every((limit) => Number.isSafeInteger(limit) && limit > 0)) {
      throw new RangeError("Invalid download authorization cache limit")
    }
  }

  async #resolveAuthorizedFile(input: GetFilePartInput, context: HandlerContext, signal: AbortSignal) {
    const session = `${context.userId}:${context.sessionId}`
    const key = `${session}:${input.fileUniqueId}:${input.message?.chatId ?? ""}:${input.message?.messageId ?? ""}`
    const now = this.#now()
    const cached = this.#authorizations.get(key)
    if (cached && cached.expiresAt > now) {
      // LRU eviction does not extend the authorization lifetime.
      this.#authorizations.delete(key)
      this.#authorizations.set(key, cached)
      return { file: cached.file, cacheHit: true }
    }
    this.#authorizations.delete(key)
    const file = await this.resolveFile(input.fileUniqueId, context.userId, input.message)
    checkAbort(signal)
    // Start the TTL before the lookup so a slow query cannot increase the
    // accepted revocation lag. Missing/inaccessible results are never cached.
    const expiresAt = now + AUTHORIZATION_CACHE_TTL_MS
    if (!file || expiresAt <= this.#now()) return { file, cacheHit: false }
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
    this.#authorizations.set(key, { file, expiresAt, session })
    return { file, cacheHit: false }
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
    if (active >= MAX_DOWNLOADS_PER_SESSION || this.#active >= MAX_CONCURRENT_DOWNLOADS) {
      throw RealtimeRpcError.RateLimit()
    }
    this.#active += 1
    this.#sessions.set(context.sessionId, active + 1)
    // Legacy V2 has no application deadline. Bound storage reads on both carriers
    // and retain V3 cancellation, including while the R2 stream is being read.
    const deadline = new AbortController()
    const timer = setTimeout(() => {
      deadline.abort(new DOMException("File download part timed out", "TimeoutError"))
    }, this.partTimeoutMs)
    timer.unref()
    const signal = context.signal ? AbortSignal.any([context.signal, deadline.signal]) : deadline.signal
    const trace: DownloadPartTrace | undefined = this.#trace ? {
      authorizationMs: 0, storageMs: 0, bytes: 0,
      carrier: context.inlineProtocol ? "V3" : "V2", cacheHit: false, outcome: "failed",
    } : undefined
    try {
      // Keep admission owned while the database lookup settles. An expired
      // deadline prevents starting a storage read after that lookup returns.
      const authorizationStartedAt = trace ? this.#now() : 0
      let file: DbFile | undefined
      try {
        const authorized = await this.#resolveAuthorizedFile(input, context, signal)
        file = authorized.file
        if (trace) trace.cacheHit = authorized.cacheHit
      } finally {
        if (trace) trace.authorizationMs = Math.max(0, this.#now() - authorizationStartedAt)
      }
      checkAbort(signal)
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
        data = length === 0 ? new Uint8Array() :
          await this.readRange(`${FILES_PATH_PREFIX}/${path}`, offset, length, signal)
        if (trace) trace.bytes = data.length
      } finally {
        if (trace) trace.storageMs = Math.max(0, this.#now() - storageStartedAt)
      }
      checkAbort(signal)
      if (data.length !== length) throw RealtimeRpcError.InternalError()
      const sha256 = createHash("sha256").update(data).digest()
      if (trace) trace.outcome = "ok"
      return { offset: input.offset, totalSize: BigInt(size), data, sha256 }
    } catch (error) {
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
      this.#active -= 1
      const remaining = (this.#sessions.get(context.sessionId) ?? 1) - 1
      if (remaining === 0) this.#sessions.delete(context.sessionId)
      else this.#sessions.set(context.sessionId, remaining)
      if (trace) {
        try { this.#trace?.(trace) } catch {
          // Optional diagnostics must not affect range results or slot release.
        }
      }
    }
  }
}

export const nativeDownloadOperations = new NativeDownloadOperations()
