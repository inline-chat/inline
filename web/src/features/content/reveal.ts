/**
 * Decode, then reveal. The media box has its final size from the model before
 * any byte loads; the image (or a GIF's video) sits in it at opacity 0 and is
 * shown once the browser has decoded it (`img.decode()`) or has a first frame
 * (`loadeddata`), so a half-drawn image never shows and nothing moves.
 *
 * `LoadedMedia` remembers URLs that already revealed in this session, so a row
 * that leaves the window and comes back shows its image at once, without the
 * fade. It is bounded; the media registry will replace it.
 */

import { type ReadSignal, signal } from "@inline/reactive"

export type RevealStatus = "idle" | "loading" | "loaded" | "failed"

/** URLs that revealed recently, oldest dropped first. */
export class LoadedMedia {
  readonly #urls = new Set<string>()
  constructor(readonly limit = 512) {}

  has(url: string): boolean {
    return this.#urls.has(url)
  }

  add(url: string): void {
    this.#urls.delete(url)
    this.#urls.add(url)
    while (this.#urls.size > this.limit) {
      const oldest = this.#urls.values().next().value
      if (oldest === undefined) break
      this.#urls.delete(oldest)
    }
  }

  delete(url: string): void {
    this.#urls.delete(url)
  }

  get size(): number {
    return this.#urls.size
  }
}

/** The parts of `<img>` the controller uses. */
export type RevealImage = {
  src: string
  readonly complete: boolean
  readonly naturalWidth: number
  decode(): Promise<void>
  removeAttribute(name: string): void
}

/** The parts of `<video>` the controller uses (GIFs). */
export type RevealVideo = {
  src: string
  addEventListener(type: string, listener: () => void): void
  removeEventListener(type: string, listener: () => void): void
  removeAttribute(name: string): void
  load?(): void
}

export type RevealOptions = {
  readonly url: string | undefined
  readonly kind?: "image" | "video"
  readonly loaded?: LoadedMedia
  /** Called on every status change (the lab's height check, diagnostics). */
  readonly onStatus?: (status: RevealStatus) => void
}

export class RevealController {
  readonly url: string | undefined
  /** The URL revealed before in this session: show it without a fade. */
  readonly instant: boolean
  readonly #status
  readonly #kind: "image" | "video"
  readonly #loaded: LoadedMedia | undefined
  readonly #onStatus: ((status: RevealStatus) => void) | undefined
  #element: RevealImage | RevealVideo | undefined
  #generation = 0
  #detachVideo: (() => void) | undefined
  #disposed = false

  readonly part = {
    attach: (element: RevealImage | RevealVideo): (() => void) => {
      this.#element = element
      this.#start()
      return () => {
        if (this.#element !== element) return
        this.#generation += 1
        this.#detachVideo?.()
        this.#detachVideo = undefined
        this.#element = undefined
      }
    },
  }

  constructor(options: RevealOptions) {
    this.url = options.url
    this.#kind = options.kind ?? "image"
    this.#loaded = options.loaded
    this.#onStatus = options.onStatus
    this.instant = options.url !== undefined && options.loaded?.has(options.url) === true
    this.#status = signal<RevealStatus>(options.url === undefined ? "idle" : this.instant ? "loaded" : "loading")
  }

  get status(): ReadSignal<RevealStatus> {
    return this.#status
  }

  /** Load the same URL again after a failure. */
  retry(): void {
    if (this.#disposed || this.url === undefined) return
    this.#loaded?.delete(this.url)
    const element = this.#element
    if (element) {
      element.removeAttribute("src")
      this.#start()
    } else {
      this.#set("loading")
    }
  }

  dispose(): void {
    this.#disposed = true
    this.#generation += 1
    this.#detachVideo?.()
    this.#detachVideo = undefined
    this.#element = undefined
  }

  #set(status: RevealStatus): void {
    if (this.#status.peek() === status) return
    this.#status.set(status)
    this.#onStatus?.(status)
  }

  #start(): void {
    const element = this.#element
    const url = this.url
    if (!element || url === undefined || this.#disposed) return
    const generation = ++this.#generation
    const current = () => generation === this.#generation && !this.#disposed
    if (this.#status.peek() !== "loaded") this.#set("loading")
    const succeed = () => {
      if (!current()) return
      this.#loaded?.add(url)
      this.#set("loaded")
    }
    const fail = () => {
      if (current()) this.#set("failed")
    }
    if (this.#kind === "video") {
      const video = element as RevealVideo
      this.#detachVideo?.()
      const onData = () => succeed()
      const onError = () => fail()
      video.addEventListener("loadeddata", onData)
      video.addEventListener("error", onError)
      this.#detachVideo = () => {
        video.removeEventListener("loadeddata", onData)
        video.removeEventListener("error", onError)
      }
      video.src = url
      video.load?.()
      return
    }
    const image = element as RevealImage
    image.src = url
    image.decode().then(succeed, () => {
      // Some engines reject decode() for an image that did load (for
      // example one detached and reattached); trust what the element says.
      if (image.complete && image.naturalWidth > 0) succeed()
      else fail()
    })
  }
}
