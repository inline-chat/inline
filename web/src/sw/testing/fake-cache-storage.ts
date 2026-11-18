/**
 * Cache Storage in memory, with the behavior the worker relies on:
 * `match(request, { cacheName })` never creates a cache, `open` does, a
 * deleted cache is gone for every later lookup, and a write can be made to
 * fail (quota) to test atomic install.
 */

import type { CacheLike, CacheStorageLike, PageCachesLike } from "../types"
import { TEST_ORIGIN } from "./fake-network"

interface StoredResponse {
  readonly body: Uint8Array
  readonly status: number
  readonly statusText: string
  readonly headers: [string, string][]
}

const keyOf = (request: Request | string): string => (typeof request === "string" ? new URL(request).href : request.url)

const revive = (stored: StoredResponse): Response =>
  new Response(stored.body.slice(), { status: stored.status, statusText: stored.statusText, headers: stored.headers })

export class FakeCache implements CacheLike {
  readonly entries = new Map<string, StoredResponse>()

  constructor(private readonly storage: FakeCacheStorage) {}

  async match(request: Request | string): Promise<Response | undefined> {
    const stored = this.entries.get(keyOf(request))
    return stored ? revive(stored) : undefined
  }

  async put(request: Request | string, response: Response): Promise<void> {
    this.storage.beforePut()
    const body = new Uint8Array(await response.arrayBuffer())
    this.entries.set(keyOf(request), {
      body,
      status: response.status,
      statusText: response.statusText,
      headers: Array.from(response.headers.entries()),
    })
  }

  async keys(): Promise<readonly Request[]> {
    return Array.from(this.entries.keys(), (url) => new Request(url))
  }
}

export class FakeCacheStorage implements CacheStorageLike, PageCachesLike {
  private readonly caches = new Map<string, FakeCache>()
  private putsUntilFailure: number | null = null

  /** The next `count` writes succeed, then every write throws a quota error until `allowWrites`. */
  failWritesAfter(count: number): void {
    this.putsUntilFailure = count
  }

  allowWrites(): void {
    this.putsUntilFailure = null
  }

  /** @internal */
  beforePut(): void {
    if (this.putsUntilFailure === null) return
    if (this.putsUntilFailure <= 0) throw new DOMException("Quota exceeded", "QuotaExceededError")
    this.putsUntilFailure--
  }

  async match(request: Request | string, options?: { readonly cacheName?: string }): Promise<Response | undefined> {
    if (options?.cacheName !== undefined) return this.caches.get(options.cacheName)?.match(request)
    for (const cache of this.caches.values()) {
      const hit = await cache.match(request)
      if (hit) return hit
    }
    return undefined
  }

  async open(name: string): Promise<FakeCache> {
    let cache = this.caches.get(name)
    if (!cache) {
      cache = new FakeCache(this)
      this.caches.set(name, cache)
    }
    return cache
  }

  async has(name: string): Promise<boolean> {
    return this.caches.has(name)
  }

  async delete(name: string): Promise<boolean> {
    return this.caches.delete(name)
  }

  async keys(): Promise<readonly string[]> {
    return Array.from(this.caches.keys())
  }

  // Inspection for tests

  names(): string[] {
    return Array.from(this.caches.keys())
  }

  /** Paths (or full URLs for other origins) stored in a cache, sorted. */
  paths(name: string): string[] {
    const cache = this.caches.get(name)
    if (!cache) return []
    return Array.from(cache.entries.keys(), (href) => {
      const url = new URL(href)
      return url.origin === TEST_ORIGIN ? url.pathname : href
    }).sort()
  }
}
