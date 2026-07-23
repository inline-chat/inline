import type {
  InlineMediaLoader,
  InlineMediaResource,
} from "./InlineMediaLoader"

type LoadedMedia = {
  url: string
  revocable: boolean
  sourceUrl: string
  references: number
  retainedAt: number
  releaseTimer: ReturnType<typeof setTimeout> | null
}

type PendingRendererMedia = {
  operation: Promise<LoadedMedia>
  controller: AbortController
  waiters: number
  settled: boolean
}

export type InlineMediaHandle = {
  url: string
  release: () => void
}

export type InlineMediaAcquireOptions = {
  signal?: AbortSignal
}

export class InlineMediaAcquireCancelled extends Error {
  constructor() {
    super("Inline media acquisition was cancelled")
    this.name = "InlineMediaAcquireCancelled"
  }
}

export type InlineMediaSource = Pick<
  InlineMediaLoader,
  "load" | "loadCached"
>

export type InlineMediaRepositoryOptions = {
  retentionMs?: number
  maximumRetainedEntries?: number
  now?: () => number
}

const DEFAULT_RETENTION_MS = 30_000
const DEFAULT_MAXIMUM_RETAINED_ENTRIES = 64

const rendererMedia = (
  resource: InlineMediaResource,
): Pick<LoadedMedia, "url" | "revocable"> => {
  if (resource.kind === "remote") {
    return {
      url: resource.url,
      revocable: false,
    }
  }
  return {
    url: URL.createObjectURL(resource.blob),
    revocable: true,
  }
}

export class InlineMediaRepository {
  private readonly loaded = new Map<string, LoadedMedia>()
  private readonly pending = new Map<
    string,
    PendingRendererMedia
  >()
  private readonly retentionMs: number
  private readonly maximumRetainedEntries: number
  private readonly now: () => number
  private generation = 0

  constructor(
    private readonly source: InlineMediaSource,
    options: InlineMediaRepositoryOptions = {},
  ) {
    this.retentionMs = Math.max(
      0,
      options.retentionMs ?? DEFAULT_RETENTION_MS,
    )
    this.maximumRetainedEntries = Math.max(
      0,
      options.maximumRetainedEntries ??
        DEFAULT_MAXIMUM_RETAINED_ENTRIES,
    )
    this.now = options.now ?? Date.now
  }

  peek(key: string, remoteUrl?: string) {
    const media = this.loaded.get(key)
    if (
      !media ||
      (!media.revocable &&
        remoteUrl != null &&
        media.sourceUrl !== remoteUrl)
    ) {
      return undefined
    }
    return media.url
  }

  /** Promotes persistent bytes into this renderer's hot object-URL layer.
   * It never performs or waits for a network request. */
  async promoteCached(
    key: string,
    options: InlineMediaAcquireOptions = {},
  ) {
    const current = this.loaded.get(key)
    if (current) return true

    const generation = this.generation
    const resource = await this.source.loadCached(key, options)
    if (!resource || generation !== this.generation) return false

    const media = this.installResource(key, resource, "")
    if (media.references === 0 && !media.releaseTimer) {
      this.retainOrDispose(key, media)
    }
    return this.loaded.get(key) === media
  }

  async acquire(
    key: string,
    remoteUrl: string,
    options: InlineMediaAcquireOptions = {},
  ): Promise<InlineMediaHandle> {
    let media = this.loaded.get(key)
    if (
      media &&
      media.references === 0 &&
      !media.revocable &&
      media.sourceUrl !== remoteUrl
    ) {
      this.dispose(key, media)
      media = undefined
    }
    if (!media) {
      let pending = this.pending.get(key)
      if (!pending) {
        const controller = new AbortController()
        pending = {
          operation: this.load(
            key,
            remoteUrl,
            controller.signal,
          ),
          controller,
          waiters: 0,
          settled: false,
        }
        this.pending.set(key, pending)
        const created = pending
        void created.operation.then(
          () => this.finishPending(key, created),
          () => this.finishPending(key, created),
        )
      }
      media = await this.waitForPending(
        key,
        pending,
        options.signal,
      )
    }

    if (media.releaseTimer) {
      clearTimeout(media.releaseTimer)
      media.releaseTimer = null
    }
    media.references += 1
    let released = false
    return {
      url: media.url,
      release: () => {
        if (released) return
        released = true
        media.references -= 1
        if (media.references > 0) return
        if (this.loaded.get(key) !== media) return
        this.retainOrDispose(key, media)
      },
    }
  }

  clear() {
    this.generation += 1
    for (const pending of this.pending.values()) {
      pending.controller.abort()
    }
    this.pending.clear()
    for (const [key, media] of this.loaded) {
      this.dispose(key, media, true)
    }
  }

  private async load(
    key: string,
    remoteUrl: string,
    signal: AbortSignal,
  ): Promise<LoadedMedia> {
    const generation = this.generation
    const resource = await this.source.load(key, remoteUrl, {
      signal,
    })
    if (generation !== this.generation) {
      throw new InlineMediaAcquireCancelled()
    }
    return this.installResource(key, resource, remoteUrl)
  }

  private installResource(
    key: string,
    resource: InlineMediaResource,
    sourceUrl: string,
  ) {
    const current = this.loaded.get(key)
    if (current) return current

    const media = rendererMedia(resource)
    const installed = this.loaded.get(key)
    if (installed) {
      if (media.revocable) URL.revokeObjectURL(media.url)
      return installed
    }
    return this.remember(
      key,
      media.url,
      media.revocable,
      sourceUrl,
    )
  }

  private remember(
    key: string,
    url: string,
    revocable: boolean,
    sourceUrl: string,
  ) {
    const media: LoadedMedia = {
      url,
      revocable,
      sourceUrl,
      references: 0,
      retainedAt: 0,
      releaseTimer: null,
    }
    this.loaded.set(key, media)
    return media
  }

  private retainOrDispose(key: string, media: LoadedMedia) {
    if (
      this.retentionMs === 0 ||
      this.maximumRetainedEntries === 0
    ) {
      this.dispose(key, media)
      return
    }
    media.retainedAt = this.now()
    media.releaseTimer = setTimeout(() => {
      this.dispose(key, media)
    }, this.retentionMs)
    this.trimRetained()
  }

  private trimRetained() {
    const retained = [...this.loaded.entries()]
      .filter(([, media]) => media.references === 0)
      .sort(
        ([, first], [, second]) =>
          first.retainedAt - second.retainedAt,
      )
    const excess =
      retained.length - this.maximumRetainedEntries
    for (let index = 0; index < excess; index += 1) {
      const entry = retained[index]
      if (entry) this.dispose(entry[0], entry[1])
    }
  }

  private dispose(
    key: string,
    media: LoadedMedia,
    force = false,
  ) {
    if (this.loaded.get(key) !== media) return
    if (!force && media.references > 0) return
    this.loaded.delete(key)
    if (media.releaseTimer) {
      clearTimeout(media.releaseTimer)
      media.releaseTimer = null
    }
    if (media.revocable) URL.revokeObjectURL(media.url)
  }

  private finishPending(
    key: string,
    pending: PendingRendererMedia,
  ) {
    pending.settled = true
    if (this.pending.get(key) === pending) {
      this.pending.delete(key)
    }
  }

  private waitForPending(
    key: string,
    pending: PendingRendererMedia,
    signal?: AbortSignal,
  ) {
    pending.waiters += 1
    if (signal?.aborted) {
      this.releasePendingWaiter(key, pending)
      return Promise.reject(new InlineMediaAcquireCancelled())
    }

    let handleAbort: (() => void) | undefined
    const aborted = signal
      ? new Promise<never>((_resolve, reject) => {
          handleAbort = () => {
            reject(new InlineMediaAcquireCancelled())
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
      this.releasePendingWaiter(key, pending)
    })
  }

  private releasePendingWaiter(
    key: string,
    pending: PendingRendererMedia,
  ) {
    pending.waiters = Math.max(0, pending.waiters - 1)
    if (pending.waiters > 0 || pending.settled) return
    if (this.pending.get(key) === pending) {
      this.pending.delete(key)
    }
    pending.controller.abort()
  }
}
