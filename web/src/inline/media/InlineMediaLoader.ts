import type { InlineMediaCache } from "./cache/InlineMediaCache"
import type { Log } from "@inline/log"

export type InlineMediaResource =
  | {
      kind: "blob"
      blob: Blob
    }
  | {
      kind: "remote"
      url: string
    }

export type InlineMediaFetcher = (
  input: RequestInfo | URL,
  init?: RequestInit,
) => Promise<Response>

export type InlineMediaLoaderOptions = {
  cache: InlineMediaCache
  fetcher?: InlineMediaFetcher
  logger?: Log
}

export type InlineMediaLoadOptions = {
  signal?: AbortSignal
}

type PendingMediaLoad = {
  operation: Promise<InlineMediaResource>
  controller: AbortController
  consumers: Set<symbol>
}

type PendingCacheRead = {
  operation: Promise<Blob | undefined>
}

const assertValidMediaKey = (key: string) => {
  if (
    typeof key !== "string" ||
    key.length === 0 ||
    key.length > 1_024
  ) {
    throw new TypeError("Invalid Inline media cache key")
  }
}

const assertValidRemoteMediaUrl = (remoteUrl: string) => {
  if (
    typeof remoteUrl !== "string" ||
    remoteUrl.length === 0 ||
    remoteUrl.length > 16_384
  ) {
    throw new TypeError("Invalid Inline remote media URL")
  }
  try {
    const base = globalThis.location?.href
    const url = base
      ? new URL(remoteUrl, base)
      : new URL(remoteUrl)
    if (url.protocol !== "https:" && url.protocol !== "http:") {
      throw new TypeError("Invalid Inline remote media URL")
    }
  } catch (error) {
    if (
      error instanceof TypeError &&
      error.message === "Invalid Inline remote media URL"
    ) {
      throw error
    }
    throw new TypeError("Invalid Inline remote media URL", {
      cause: error,
    })
  }
}

export class InlineMediaLoadCancelled extends Error {
  constructor() {
    super("Inline media load was cancelled")
    this.name = "InlineMediaLoadCancelled"
  }
}

/**
 * Account-owner media loader. The direct Alpha core owns one instance, so
 * cache access and download deduplication share the account runtime without a
 * worker coordination layer. It returns bytes, never an object URL: blob URL
 * lifetime belongs to the renderer repository that displays those bytes.
 */
export class InlineMediaLoader {
  private readonly cache: InlineMediaCache
  private readonly fetcher: InlineMediaFetcher
  private readonly log: Log | undefined
  private readonly pending = new Map<
    string,
    PendingMediaLoad
  >()
  private readonly pendingCacheReads = new Map<
    string,
    PendingCacheRead
  >()

  constructor({
    cache,
    fetcher = globalThis.fetch.bind(globalThis),
    logger,
  }: InlineMediaLoaderOptions) {
    this.cache = cache
    this.fetcher = fetcher
    this.log = logger
  }

  load(
    key: string,
    remoteUrl: string,
    options: InlineMediaLoadOptions = {},
  ): Promise<InlineMediaResource> {
    assertValidMediaKey(key)
    assertValidRemoteMediaUrl(remoteUrl)
    let pending = this.pending.get(key)
    if (!pending) {
      const controller = new AbortController()
      const operation = this.withCancellation(
        this.loadUncoordinated(
          key,
          remoteUrl,
          controller.signal,
        ),
        controller.signal,
      )
      pending = {
        operation,
        controller,
        consumers: new Set(),
      }
      this.pending.set(key, pending)
      void operation.then(
        () => this.finishPending(key, pending!),
        () => this.finishPending(key, pending!),
      )
    }
    const consumer = Symbol(key)
    pending.consumers.add(consumer)
    return this.waitForConsumer(
      key,
      pending,
      consumer,
      options.signal,
    )
  }

  /** Reads only account-owned persistent bytes. A miss never falls through to
   * a remote URL and therefore is safe to await during route preparation. */
  async loadCached(
    key: string,
    options: InlineMediaLoadOptions = {},
  ): Promise<InlineMediaResource | undefined> {
    assertValidMediaKey(key)
    const cached = await this.withOptionalCancellation(
      this.readCached(key),
      options.signal,
    )
    if (options.signal) this.throwIfCancelled(options.signal)
    return cached ? { kind: "blob", blob: cached } : undefined
  }

  cancelAll() {
    if (this.pending.size > 0) {
      this.log?.debug("media.load.cancelled", {
        pendingCount: this.pending.size,
      })
    }
    for (const pending of this.pending.values()) {
      pending.controller.abort()
    }
    this.pending.clear()
  }

  private async loadUncoordinated(
    key: string,
    remoteUrl: string,
    signal: AbortSignal,
  ): Promise<InlineMediaResource> {
    try {
      const cached = await this.loadCached(key, { signal })
      this.throwIfCancelled(signal)
      if (cached) {
        this.log?.debug("media.cache.hit")
        return cached
      }

      const response = await this.fetcher(remoteUrl, {
        credentials: "omit",
        cache: "force-cache",
        signal,
      })
      this.throwIfCancelled(signal)
      if (!response.ok) {
        this.log?.warn("media.fetch.http_failed", {
          status: response.status,
        })
        return { kind: "remote", url: remoteUrl }
      }
      const blob = await response.blob()
      this.throwIfCancelled(signal)
      let persisted = true
      try {
        await this.cache.put(key, blob)
      } catch (error) {
        persisted = false
        this.log?.warn("media.cache.write_failed", { error })
      }
      this.throwIfCancelled(signal)
      this.log?.debug("media.fetch.completed", {
        byteCount: blob.size,
        persisted,
      })
      return { kind: "blob", blob }
    } catch (error) {
      if (signal.aborted) {
        this.log?.debug("media.load.cancelled")
        throw new InlineMediaLoadCancelled()
      }
      this.log?.warn("media.fetch.failed", { error })
      return { kind: "remote", url: remoteUrl }
    }
  }

  private readCached(key: string) {
    let pending = this.pendingCacheReads.get(key)
    if (!pending) {
      const operation = this.cache.get(key).catch((error: unknown) => {
        this.log?.warn("media.cache.read_failed", { error })
        return undefined
      })
      pending = { operation }
      this.pendingCacheReads.set(key, pending)
      const created = pending
      void operation.finally(() => {
        if (this.pendingCacheReads.get(key) === created) {
          this.pendingCacheReads.delete(key)
        }
      })
    }
    return pending.operation
  }

  private finishPending(
    key: string,
    pending: PendingMediaLoad,
  ) {
    if (this.pending.get(key) === pending) {
      this.pending.delete(key)
    }
  }

  private waitForConsumer(
    key: string,
    pending: PendingMediaLoad,
    consumer: symbol,
    signal?: AbortSignal,
  ) {
    if (signal?.aborted) {
      this.releaseConsumer(key, pending, consumer)
      return Promise.reject(new InlineMediaLoadCancelled())
    }

    let handleAbort: (() => void) | undefined
    const aborted = signal
      ? new Promise<never>((_resolve, reject) => {
          handleAbort = () => {
            reject(new InlineMediaLoadCancelled())
          }
          signal.addEventListener("abort", handleAbort, {
            once: true,
          })
        })
      : undefined
    const result = aborted
      ? Promise.race([pending.operation, aborted])
      : pending.operation

    return result.finally(() => {
      if (handleAbort) {
        signal?.removeEventListener("abort", handleAbort)
      }
      this.releaseConsumer(key, pending, consumer)
    })
  }

  private releaseConsumer(
    key: string,
    pending: PendingMediaLoad,
    consumer: symbol,
  ) {
    pending.consumers.delete(consumer)
    if (
      pending.consumers.size === 0 &&
      this.pending.get(key) === pending
    ) {
      this.pending.delete(key)
      pending.controller.abort()
    }
  }

  private throwIfCancelled(signal: AbortSignal) {
    if (signal.aborted) {
      throw new InlineMediaLoadCancelled()
    }
  }

  private withCancellation<T>(
    operation: Promise<T>,
    signal: AbortSignal,
  ) {
    if (signal.aborted) {
      return Promise.reject(new InlineMediaLoadCancelled())
    }
    let handleAbort: (() => void) | undefined
    const cancelled = new Promise<never>((_resolve, reject) => {
      handleAbort = () => {
        reject(new InlineMediaLoadCancelled())
      }
      signal.addEventListener("abort", handleAbort, {
        once: true,
      })
    })
    return Promise.race([operation, cancelled]).finally(() => {
      if (handleAbort) {
        signal.removeEventListener("abort", handleAbort)
      }
    })
  }


  private withOptionalCancellation<T>(
    operation: Promise<T>,
    signal?: AbortSignal,
  ) {
    return signal
      ? this.withCancellation(operation, signal)
      : operation
  }
}
