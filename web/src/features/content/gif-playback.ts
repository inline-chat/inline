/**
 * GIFs are muted, looping videos. They play only while on screen, while the
 * page is visible and when the user has not asked for reduced motion
 * (`timeline-and-composer.md`, "Media in the timeline"). Under reduced motion
 * the first frame stays; a click opens the viewer.
 */

export type PlaybackVideo = {
  muted: boolean
  loop: boolean
  playsInline: boolean
  readonly paused: boolean
  play(): Promise<void> | void
  pause(): void
}

/** A yes/no condition the controller watches. */
export type Condition = {
  get(): boolean
  subscribe(listener: () => void): () => void
}

export type GifPlaybackOptions = {
  /** Calls back with whether the element intersects the viewport. Default: IntersectionObserver. */
  readonly observeVisibility?: (element: PlaybackVideo, listener: (visible: boolean) => void) => () => void
  /** Default: `document.visibilityState === "visible"`. */
  readonly pageVisible?: Condition
  /** Default: `(prefers-reduced-motion: reduce)`. */
  readonly reducedMotion?: Condition
}

const browserVisibility = (element: PlaybackVideo, listener: (visible: boolean) => void): (() => void) => {
  if (typeof IntersectionObserver === "undefined") {
    listener(true)
    return () => {}
  }
  const observer = new IntersectionObserver((entries) => {
    const last = entries[entries.length - 1]
    if (last) listener(last.isIntersecting)
  })
  observer.observe(element as unknown as Element)
  return () => observer.disconnect()
}

const browserPageVisible: Condition = {
  get: () => typeof document === "undefined" || document.visibilityState === "visible",
  subscribe: (listener) => {
    if (typeof document === "undefined") return () => {}
    document.addEventListener("visibilitychange", listener)
    return () => document.removeEventListener("visibilitychange", listener)
  },
}

const mediaCondition = (query: string): Condition => {
  const list = typeof matchMedia === "function" ? matchMedia(query) : undefined
  return {
    get: () => list?.matches ?? false,
    subscribe: (listener) => {
      list?.addEventListener("change", listener)
      return () => list?.removeEventListener("change", listener)
    },
  }
}

export class GifPlaybackController {
  readonly #observeVisibility: NonNullable<GifPlaybackOptions["observeVisibility"]>
  readonly #pageVisible: Condition
  readonly #reducedMotion: Condition

  constructor(options: GifPlaybackOptions = {}) {
    this.#observeVisibility = options.observeVisibility ?? browserVisibility
    this.#pageVisible = options.pageVisible ?? browserPageVisible
    this.#reducedMotion = options.reducedMotion ?? mediaCondition("(prefers-reduced-motion: reduce)")
  }

  /** Whether a GIF should autoplay at all right now (for the first render). */
  get animate(): boolean {
    return !this.#reducedMotion.get()
  }

  readonly part = {
    attach: (video: PlaybackVideo): (() => void) => {
      video.muted = true
      video.loop = true
      video.playsInline = true
      let visible = false
      let disposed = false
      const update = () => {
        if (disposed) return
        const play = visible && this.#pageVisible.get() && !this.#reducedMotion.get()
        if (play && video.paused) {
          const result = video.play()
          // Autoplay can be refused (power saving); the poster stays.
          if (result && typeof result.catch === "function") result.catch(() => {})
        } else if (!play && !video.paused) {
          video.pause()
        }
      }
      const stopVisibility = this.#observeVisibility(video, (next) => {
        visible = next
        update()
      })
      const stopPage = this.#pageVisible.subscribe(update)
      const stopMotion = this.#reducedMotion.subscribe(update)
      return () => {
        disposed = true
        stopVisibility()
        stopPage()
        stopMotion()
        if (!video.paused) video.pause()
      }
    },
  }
}
