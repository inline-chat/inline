import type { InlineMediaCache } from "./cache/InlineMediaCache"

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

export class InlineMediaLoadCancelled extends Error {
  constructor() {
    super("Inline media load was cancelled")
    this.name = "InlineMediaLoadCancelled"
  }
}

const canFetchForPersistentCache = (remoteUrl: string) => {
  try {
    const url = new URL(
      remoteUrl,
      globalThis.location?.href,
    )
    return !url.hostname.endsWith(
      ".r2.cloudflarestorage.com",
    )
  } catch {
    return true
  }
}

/**
 * Account-owner media loader. The SharedWorker owns one instance, which makes
 * cache access and download deduplication origin-wide rather than per tab.
 * It returns bytes, never an object URL: blob URL lifetime belongs to the
 * renderer that displays those bytes.
 */
export class InlineMediaLoader {
  private readonly cache: InlineMediaCache
  private readonly fetcher: InlineMediaFetcher
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
  }: InlineMediaLoaderOptions) {
    this.cache = cache
    this.fetcher = fetcher
  }

  load(
    key: string,
    remoteUrl: string,
    options: InlineMediaLoadOptions = {},
  ): Promise<InlineMediaResource> {
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
    const cached = await this.withOptionalCancellation(
      this.readCached(key),
      options.signal,
    )
    if (options.signal) this.throwIfCancelled(options.signal)
    return cached ? { kind: "blob", blob: cached } : undefined
  }

  cancelAll() {
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
        return cached
      }

      // Signed R2 URLs are valid media sources, but the bucket currently
      // rejects browser CORS reads. Preserve rendering without issuing a
      // request that is guaranteed to fail.
      if (!canFetchForPersistentCache(remoteUrl)) {
        return { kind: "remote", url: remoteUrl }
      }

      const response = await this.fetcher(remoteUrl, {
        credentials: "omit",
        cache: "force-cache",
        signal,
      })
      this.throwIfCancelled(signal)
      if (!response.ok) {
        return { kind: "remote", url: remoteUrl }
      }
      const blob = await response.blob()
      this.throwIfCancelled(signal)
      await this.cache.put(key, blob).catch(() => undefined)
      this.throwIfCancelled(signal)
      return { kind: "blob", blob }
    } catch {
      if (signal.aborted) {
        throw new InlineMediaLoadCancelled()
      }
      return { kind: "remote", url: remoteUrl }
    }
  }

  private readCached(key: string) {
    let pending = this.pendingCacheReads.get(key)
    if (!pending) {
      const operation = this.cache.get(key).catch(() => undefined)
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
