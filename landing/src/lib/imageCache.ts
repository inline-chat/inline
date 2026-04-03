import { useEffect, useState } from "react"
import { DbObjectKind, DbQueryPlanType, type Db, type User } from "@inline/client"

const CACHE_NAME = "inline-images"

class ImageCache {
  private cache: Cache | null = null
  private memory = new Map<string, string>()
  private preloaded = false

  private async getCache(): Promise<Cache | null> {
    if (this.cache) return this.cache
    if (!("caches" in window)) return null
    this.cache = await caches.open(CACHE_NAME)
    return this.cache
  }

  private key(id: string): string {
    return `https://cache.inline.local/photos/${id}`
  }

  /** Synchronous memory-only lookup. Returns null if not preloaded. */
  getSync(id: string): string | null {
    console.log("getSync", id, this.memory.get(id))
    return this.memory.get(id) ?? null
  }

  /** Preload IDs from persistent cache into memory. Call on app init. */
  async preload(ids: string[]): Promise<void> {
    if (this.preloaded) return
    this.preloaded = true

    const cache = await this.getCache()
    if (!cache) return

    await Promise.all(
      ids.map(async (id) => {
        if (this.memory.has(id)) return

        const cached = await cache.match(this.key(id))
        if (!cached) return

        const blob = await cached.blob()
        const blobUrl = URL.createObjectURL(blob)
        this.memory.set(id, blobUrl)
      }),
    )
  }

  /** Async lookup - checks memory then persistent cache. */
  async get(id: string): Promise<string | null> {
    const mem = this.memory.get(id)
    if (mem) return mem

    const cache = await this.getCache()
    if (!cache) return null

    const cached = await cache.match(this.key(id))
    if (!cached) return null

    const blob = await cached.blob()
    const blobUrl = URL.createObjectURL(blob)
    this.memory.set(id, blobUrl)
    return blobUrl
  }

  /** Store image from loaded img element. */
  async store(id: string, img: HTMLImageElement): Promise<void> {
    if (this.memory.has(id)) return

    const cache = await this.getCache()
    if (!cache) return

    const canvas = document.createElement("canvas")
    canvas.width = img.naturalWidth
    canvas.height = img.naturalHeight
    const ctx = canvas.getContext("2d")
    if (!ctx) return

    ctx.drawImage(img, 0, 0)
    const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/png"))
    if (!blob) return

    await cache.put(this.key(id), new Response(blob))
    const blobUrl = URL.createObjectURL(blob)
    this.memory.set(id, blobUrl)
  }
}

export const imageCache = new ImageCache()

type CachedImageResult = {
  imageProps: {
    src: string | undefined
    onLoad: (e: React.SyntheticEvent<HTMLImageElement>) => void
    crossOrigin: "anonymous"
  }
}

export function useCachedImage(id: string | undefined, cdnUrl: string | undefined): CachedImageResult {
  // Try sync lookup first (works if preloaded)
  const [src, setSrc] = useState<string | undefined>(() => {
    if (!cdnUrl) return undefined
    if (!id) return cdnUrl
    return imageCache.getSync(id) ?? undefined
  })

  useEffect(() => {
    if (!cdnUrl) {
      setSrc(undefined)
      return
    }

    if (!id) {
      setSrc(cdnUrl)
      return
    }

    // If already have sync result, skip async lookup
    const sync = imageCache.getSync(id)
    if (sync) {
      setSrc(sync)
      return
    }

    let cancelled = false

    imageCache.get(id).then((cached) => {
      if (cancelled) return
      setSrc(cached ?? cdnUrl)
    })

    return () => {
      cancelled = true
    }
  }, [id, cdnUrl])

  const onLoad = (e: React.SyntheticEvent<HTMLImageElement>) => {
    if (!id) return
    imageCache.store(id, e.currentTarget)
  }

  return { imageProps: { src, onLoad, crossOrigin: "anonymous" } }
}

export function useImagePreload(db: Db, enabled: boolean): boolean {
  const [preloaded, setPreloaded] = useState(false)

  useEffect(() => {
    if (!enabled) {
      setPreloaded(false)
      return
    }

    let active = true
    const users = db.queryCollection<DbObjectKind.User, User, DbQueryPlanType.Objects>(
      DbQueryPlanType.Objects,
      DbObjectKind.User,
    )
    const ids = users.map((u) => u.profilePhoto?.fileUniqueId).filter((id): id is string => !!id)

    void imageCache.preload(ids).finally(() => {
      console.log("image cache preloaded", ids)
      if (active) setPreloaded(true)
    })

    return () => {
      active = false
    }
  }, [db, enabled])

  return preloaded
}
