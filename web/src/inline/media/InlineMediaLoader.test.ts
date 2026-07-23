import { afterEach, describe, expect, it, vi } from "vitest"
import type { InlineMediaCache } from "./cache/InlineMediaCache"
import {
  InlineMediaLoadCancelled,
  InlineMediaLoader,
} from "./InlineMediaLoader"

const memoryCache = (
  value?: Blob,
): InlineMediaCache & {
  get: ReturnType<typeof vi.fn>
  put: ReturnType<typeof vi.fn>
} => ({
  get: vi.fn(async () => value),
  put: vi.fn(async () => undefined),
})

describe("InlineMediaLoader", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("deduplicates cache lookup, download, and persistence across callers", async () => {
    const cache = memoryCache()
    const fetcher = vi.fn(async () =>
      new Response(new Blob(["avatar"]), { status: 200 }),
    )
    const loader = new InlineMediaLoader({
      cache,
      fetcher,
    })

    const [first, second] = await Promise.all([
      loader.load(
        "photo-1",
        "https://cdn.inline.chat/photo-1",
      ),
      loader.load(
        "photo-1",
        "https://cdn.inline.chat/photo-1",
      ),
    ])

    expect(first.kind).toBe("blob")
    expect(second.kind).toBe("blob")
    expect(cache.get).toHaveBeenCalledOnce()
    expect(fetcher).toHaveBeenCalledOnce()
    expect(cache.put).toHaveBeenCalledOnce()
  })

  it("serves persistent bytes without touching the network", async () => {
    const cached = new Blob(["cached-avatar"])
    const cache = memoryCache(cached)
    const fetcher = vi.fn()
    const loader = new InlineMediaLoader({
      cache,
      fetcher,
    })

    await expect(
      loader.load(
        "photo-1",
        "https://cdn.inline.chat/photo-1",
      ),
    ).resolves.toEqual({
      kind: "blob",
      blob: cached,
    })
    expect(fetcher).not.toHaveBeenCalled()
    expect(cache.put).not.toHaveBeenCalled()
  })

  it("returns a cache-only miss without starting a download", async () => {
    const cache = memoryCache()
    const fetcher = vi.fn()
    const loader = new InlineMediaLoader({ cache, fetcher })

    await expect(loader.loadCached("photo-1")).resolves.toBeUndefined()
    expect(cache.get).toHaveBeenCalledOnce()
    expect(fetcher).not.toHaveBeenCalled()
    expect(cache.put).not.toHaveBeenCalled()
  })

  it("deduplicates a cache-only promotion with a normal media load", async () => {
    let resolveCache: ((value: Blob | undefined) => void) | undefined
    const cached = new Blob(["cached-avatar"])
    const cache = memoryCache()
    cache.get.mockImplementation(
      () =>
        new Promise<Blob | undefined>((resolve) => {
          resolveCache = resolve
        }),
    )
    const fetcher = vi.fn()
    const loader = new InlineMediaLoader({ cache, fetcher })

    const promoted = loader.loadCached("photo-1")
    const loaded = loader.load(
      "photo-1",
      "https://cdn.inline.chat/photo-1",
    )
    resolveCache?.(cached)

    await expect(Promise.all([promoted, loaded])).resolves.toEqual([
      { kind: "blob", blob: cached },
      { kind: "blob", blob: cached },
    ])
    expect(cache.get).toHaveBeenCalledOnce()
    expect(fetcher).not.toHaveBeenCalled()
  })

  it("passes signed R2 media through without a guaranteed CORS failure", async () => {
    const cache = memoryCache()
    const fetcher = vi.fn()
    const loader = new InlineMediaLoader({
      cache,
      fetcher,
    })
    const remoteUrl =
      "https://440e08ac.example.r2.cloudflarestorage.com/inline/photo?X-Amz-Signature=test"

    await expect(
      loader.load("photo-r2", remoteUrl),
    ).resolves.toEqual({
      kind: "remote",
      url: remoteUrl,
    })
    expect(fetcher).not.toHaveBeenCalled()
    expect(cache.put).not.toHaveBeenCalled()
  })

  it("keeps downloaded bytes usable when persistence is unavailable", async () => {
    const cache = memoryCache()
    cache.put.mockRejectedValue(new Error("quota exceeded"))
    const blob = new Blob(["avatar"])
    const loader = new InlineMediaLoader({
      cache,
      fetcher: vi.fn(async () =>
        new Response(blob, { status: 200 }),
      ),
    })

    const resource = await loader.load(
      "photo-1",
      "https://cdn.inline.chat/photo-1",
    )

    expect(resource.kind).toBe("blob")
    if (resource.kind === "blob") {
      expect(resource.blob.size).toBeGreaterThan(0)
    }
  })

  it("cancels owner-held downloads during account teardown", async () => {
    const cache = memoryCache()
    let invocation = 0
    const fetcher = vi.fn(
      (_input: RequestInfo | URL, init?: RequestInit) => {
        invocation += 1
        if (invocation > 1) {
          return Promise.resolve(
            new Response("after-restart", { status: 200 }),
          )
        }
        return new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener(
            "abort",
            () => reject(new DOMException("Aborted", "AbortError")),
            { once: true },
          )
        })
      },
    )
    const loader = new InlineMediaLoader({
      cache,
      fetcher,
    })

    const loading = loader.load(
      "photo-1",
      "https://cdn.inline.chat/photo-1",
    )
    await vi.waitFor(() => {
      expect(fetcher).toHaveBeenCalledOnce()
    })
    loader.cancelAll()

    await expect(loading).rejects.toBeInstanceOf(
      InlineMediaLoadCancelled,
    )
    await expect(
      loader.load(
        "photo-1",
        "https://cdn.inline.chat/photo-1",
      ),
    ).resolves.toMatchObject({ kind: "blob" })
    expect(fetcher).toHaveBeenCalledTimes(2)
  })

  it("settles cancellation even when the storage adapter is stuck", async () => {
    const loader = new InlineMediaLoader({
      cache: {
        get: vi.fn(
          () => new Promise<Blob | undefined>(() => undefined),
        ),
        put: vi.fn(async () => undefined),
      },
      fetcher: vi.fn(),
    })

    const loading = loader.load(
      "photo-1",
      "https://cdn.inline.chat/photo-1",
    )
    loader.cancelAll()

    await expect(loading).rejects.toBeInstanceOf(
      InlineMediaLoadCancelled,
    )
  })
})
