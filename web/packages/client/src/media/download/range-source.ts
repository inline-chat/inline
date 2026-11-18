import type { FileMessageLocation } from "@inline-chat/protocol/core"
import { rpcDownloadTransport, type NativeDownloadRpcTransport } from "@inline-chat/protocol/downloads"
import { bytesEqual, sha256 } from "../bytes"
import { MediaError, type MediaFetch, type MediaRpcCall } from "../types"

/** One byte range of a file. */
export type RangeResult = {
  readonly offset: number
  readonly totalSize: number
  readonly data: Uint8Array
  /** Validator of the representation (an entity tag). A resume sends it back. */
  readonly validator?: string
}

/**
 * Where a download gets its bytes: the media origin over HTTP, or
 * `GET_FILE_PART` over the realtime socket. Both answer exact ranges; the
 * downloader verifies them.
 */
export interface RangeSource {
  fetchRange(offset: number, limit: number, options?: { signal?: AbortSignal; validator?: string }): Promise<RangeResult>
}

/** The file behind the source changed since the partial was written: start over. */
export class RepresentationChanged extends Error {
  constructor() {
    super("The file changed since the download started")
    this.name = "RepresentationChanged"
  }
}

/** `bytes <start>-<end>/<total>`; an unknown total (`*`) is not usable. Mirrors `CDNRangeSource.parseContentRange`. */
export const parseContentRange = (value: string | null): { start: number; end: number; total: number } | undefined => {
  if (!value) return undefined
  const match = /^bytes (\d+)-(\d+)\/(\d+)$/i.exec(value.trim())
  if (!match) return undefined
  const start = Number(match[1])
  const end = Number(match[2])
  const total = Number(match[3])
  if (![start, end, total].every(Number.isSafeInteger) || start > end || end >= total) return undefined
  return { start, end, total }
}

const isLinkRejection = (status: number) => status === 401 || status === 403 || status === 410

const isTransientStatus = (status: number) => status === 408 || status === 429 || (status >= 500 && status <= 599)

/** Reads exactly `length` bytes, failing on a short or long body, without holding more than that. */
const readExactly = async (response: Response, length: number, signal?: AbortSignal): Promise<Uint8Array> => {
  if (!response.body) {
    if (length === 0) return new Uint8Array()
    throw new MediaError("length_mismatch", "The response had no body")
  }
  const out = new Uint8Array(length)
  let received = 0
  const reader = response.body.getReader()
  try {
    for (;;) {
      if (signal?.aborted) throw new MediaError("canceled", "The transfer was canceled")
      const { done, value } = await reader.read()
      if (done) break
      if (received + value.length > length) throw new MediaError("length_mismatch", "The response was longer than its range")
      out.set(value, received)
      received += value.length
    }
  } catch (error) {
    await reader.cancel().catch(() => {})
    if (error instanceof MediaError) throw error
    if (signal?.aborted) throw new MediaError("canceled", "The transfer was canceled")
    throw new MediaError("retryable", `The response body failed: ${String(error)}`)
  } finally {
    reader.releaseLock()
  }
  if (received !== length) throw new MediaError("length_mismatch", "The response was shorter than its range")
  return out
}

/**
 * Ranges over HTTP from a signed media URL, following `CDNRangeSource`. A
 * rejected link is refreshed once per rejection through `refreshUrl`. The
 * response carries no digest; integrity rests on TLS and exact lengths.
 *
 * UNVERIFIED in a browser: CORS on the media origin must expose
 * `Content-Range` and `ETag` and allow the `Range` and `If-Range` request
 * headers, or a cross-origin download cannot resume.
 */
export class HttpRangeSource implements RangeSource {
  #url: string
  #refreshing: Promise<string | undefined> | undefined

  constructor(
    private readonly fetch: MediaFetch,
    url: string,
    private readonly refreshUrl?: (stale: string) => Promise<string | undefined>,
  ) {
    this.#url = url
  }

  get url(): string {
    return this.#url
  }

  async fetchRange(offset: number, limit: number, options: { signal?: AbortSignal; validator?: string } = {}): Promise<RangeResult> {
    if (limit <= 0 || offset < 0) throw new MediaError("protocol", "Invalid range")
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const url = this.#url
      const headers: Record<string, string> = { range: `bytes=${offset}-${offset + limit - 1}` }
      if (options.validator) headers["if-range"] = options.validator
      let response: Response
      try {
        response = await this.fetch(url, { headers, signal: options.signal, cache: "no-store", credentials: "omit" })
      } catch (error) {
        if (options.signal?.aborted) throw new MediaError("canceled", "The transfer was canceled")
        throw new MediaError("retryable", `The request failed: ${String(error)}`)
      }
      if (isLinkRejection(response.status)) {
        await response.body?.cancel().catch(() => {})
        if (attempt === 0 && (await this.#renew(url))) continue
        throw new MediaError("link_rejected", "The media link was rejected", { status: response.status })
      }
      const validator = response.headers.get("etag") ?? undefined
      if (response.status === 206) {
        const range = parseContentRange(response.headers.get("content-range"))
        const expected = range ? range.end - range.start + 1 : -1
        if (!range || range.start !== offset || expected > limit) {
          await response.body?.cancel().catch(() => {})
          throw new MediaError("range_not_supported", "The server answered a different range")
        }
        const data = await readExactly(response, expected, options.signal)
        return { offset, totalSize: range.total, data, validator }
      }
      if (response.status === 200) {
        const length = Number(response.headers.get("content-length") ?? Number.NaN)
        if (offset > 0) {
          await response.body?.cancel().catch(() => {})
          // `If-Range` did not match: the whole, different representation came back.
          if (options.validator) throw new RepresentationChanged()
          throw new MediaError("range_not_supported", "The server ignored the range")
        }
        if (!Number.isSafeInteger(length) || length > limit) {
          await response.body?.cancel().catch(() => {})
          throw new MediaError("range_not_supported", "The server ignored the range")
        }
        const data = await readExactly(response, length, options.signal)
        return { offset: 0, totalSize: length, data, validator }
      }
      await response.body?.cancel().catch(() => {})
      if (response.status === 416) throw new MediaError("range_not_supported", "Range not satisfiable", { status: 416 })
      if (isTransientStatus(response.status)) throw new MediaError("http", `HTTP ${response.status}`, { status: response.status })
      throw new MediaError("rejected", `HTTP ${response.status}`, { status: response.status })
    }
    throw new MediaError("link_rejected", "The media link was rejected")
  }

  /** A link newer than `stale`; concurrent rejections of the same link share one refresh. */
  async #renew(stale: string): Promise<boolean> {
    if (this.#url !== stale) return true
    if (!this.refreshUrl) return false
    this.#refreshing ??= this.refreshUrl(stale).finally(() => {
      this.#refreshing = undefined
    })
    const fresh = await this.#refreshing
    if (fresh && fresh !== stale) this.#url = fresh
    return fresh !== undefined && fresh !== stale
  }
}

/** Ranges over `GET_FILE_PART`, each verified against its SHA-256. */
export class RpcRangeSource implements RangeSource {
  readonly #transport: NativeDownloadRpcTransport

  constructor(rpc: MediaRpcCall, private readonly fileUniqueId: string, private readonly message?: FileMessageLocation) {
    this.#transport = rpcDownloadTransport(rpc)
  }

  async fetchRange(offset: number, limit: number, options: { signal?: AbortSignal } = {}): Promise<RangeResult> {
    let part
    try {
      part = await this.#transport.getPart({
        fileUniqueId: this.fileUniqueId,
        offset: BigInt(offset),
        limit,
        message: this.message,
      }, options.signal)
    } catch (error) {
      if (options.signal?.aborted) throw new MediaError("canceled", "The transfer was canceled")
      throw error instanceof MediaError ? error : new MediaError("retryable", `The part request failed: ${String(error)}`)
    }
    if (part.offset !== BigInt(offset) || part.totalSize > BigInt(Number.MAX_SAFE_INTEGER)) {
      throw new MediaError("protocol", "The server answered a different range")
    }
    if (part.sha256.length !== 32 || !bytesEqual(sha256(part.data), part.sha256)) {
      throw new MediaError("integrity", "A downloaded part does not match its digest")
    }
    return { offset, totalSize: Number(part.totalSize), data: part.data }
  }
}
