/**
 * Voice notes: a native `<audio>` element behind our own compact control.
 * The controller owns playback state; the view renders it. One voice note
 * plays at a time in a `PlaybackGroup` (starting one pauses the other).
 * The audio element is `preload="none"`: nothing downloads until play.
 */

import { type ReadSignal, signal } from "@inline/reactive"

export type VoiceAudio = {
  src: string
  currentTime: number
  readonly duration: number
  readonly paused: boolean
  play(): Promise<void> | void
  pause(): void
  addEventListener(type: string, listener: () => void): void
  removeEventListener(type: string, listener: () => void): void
}

export type VoiceStatus = "idle" | "loading" | "playing" | "paused" | "failed"

/** At most one voice note plays per group. */
export class PlaybackGroup {
  #current: VoicePlayerController | undefined

  claim(player: VoicePlayerController): void {
    if (this.#current && this.#current !== player) this.#current.pause()
    this.#current = player
  }

  release(player: VoicePlayerController): void {
    if (this.#current === player) this.#current = undefined
  }

  get current(): VoicePlayerController | undefined {
    return this.#current
  }
}

export type VoicePlayerOptions = {
  /** Undefined while the media layer has no URL yet: the control is disabled. */
  readonly url: string | undefined
  /** Seconds, from the model; the element's own duration wins once known. */
  readonly duration: number
  readonly group?: PlaybackGroup
}

const events = ["playing", "pause", "ended", "timeupdate", "error", "waiting", "loadedmetadata"] as const

export class VoicePlayerController {
  readonly url: string | undefined
  readonly #group: PlaybackGroup | undefined
  readonly #status = signal<VoiceStatus>("idle")
  readonly #position = signal(0)
  readonly #duration
  #audio: VoiceAudio | undefined
  #disposed = false

  readonly part = {
    attach: (audio: VoiceAudio): (() => void) => {
      this.#audio = audio
      const listeners = events.map((type) => {
        const listener = () => this.#onEvent(type, audio)
        audio.addEventListener(type, listener)
        return [type, listener] as const
      })
      return () => {
        for (const [type, listener] of listeners) audio.removeEventListener(type, listener)
        if (!audio.paused) audio.pause()
        if (this.#audio === audio) this.#audio = undefined
        this.#group?.release(this)
      }
    },
  }

  constructor(options: VoicePlayerOptions) {
    this.url = options.url
    this.#group = options.group
    this.#duration = signal(Number.isFinite(options.duration) && options.duration > 0 ? options.duration : 0)
  }

  get status(): ReadSignal<VoiceStatus> {
    return this.#status
  }

  /** Seconds played. */
  get position(): ReadSignal<number> {
    return this.#position
  }

  /** Seconds in total. */
  get duration(): ReadSignal<number> {
    return this.#duration
  }

  /** Played fraction in [0, 1]. */
  progress(): number {
    const total = this.#duration.get()
    return total > 0 ? Math.min(1, Math.max(0, this.#position.get() / total)) : 0
  }

  get canPlay(): boolean {
    return this.url !== undefined
  }

  toggle(): void {
    const status = this.#status.peek()
    if (status === "playing" || status === "loading") this.pause()
    else this.play()
  }

  play(): void {
    const audio = this.#audio
    if (!audio || this.url === undefined || this.#disposed) return
    this.#group?.claim(this)
    if (this.#status.peek() === "failed" || audio.src === "") audio.src = this.url
    this.#status.set("loading")
    const result = audio.play()
    if (result && typeof result.catch === "function") {
      result.catch(() => {
        if (this.#audio === audio && audio.paused && this.#status.peek() === "loading") this.#status.set("paused")
      })
    }
  }

  pause(): void {
    const audio = this.#audio
    if (audio && !audio.paused) audio.pause()
    if (this.#status.peek() === "loading" || this.#status.peek() === "playing") this.#status.set("paused")
  }

  /** Jump to a fraction of the note. */
  seek(fraction: number): void {
    const audio = this.#audio
    const total = this.#duration.peek()
    if (!audio || total <= 0 || !Number.isFinite(fraction)) return
    const time = Math.min(1, Math.max(0, fraction)) * total
    audio.currentTime = time
    this.#position.set(time)
  }

  dispose(): void {
    this.#disposed = true
    this.pause()
    this.#group?.release(this)
  }

  #onEvent(type: (typeof events)[number], audio: VoiceAudio): void {
    if (this.#disposed) return
    switch (type) {
      case "playing":
        this.#status.set("playing")
        return
      case "waiting":
        if (this.#status.peek() === "playing") this.#status.set("loading")
        return
      case "pause":
        if (this.#status.peek() !== "failed" && this.#status.peek() !== "idle") this.#status.set("paused")
        return
      case "ended":
        this.#status.set("paused")
        this.#position.set(0)
        this.#group?.release(this)
        return
      case "timeupdate":
        this.#position.set(audio.currentTime)
        return
      case "error":
        this.#status.set("failed")
        this.#group?.release(this)
        return
      case "loadedmetadata":
        if (Number.isFinite(audio.duration) && audio.duration > 0) this.#duration.set(audio.duration)
        return
    }
  }
}
