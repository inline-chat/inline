/**
 * Work that waits for the first paint: loading the code of surfaces the
 * first frame does not show (quick search, settings, message content, the
 * service worker's registration). Each task is queued at boot and runs on
 * the idle lane, one per idle slice, once the window has painted (the shell,
 * the sign-in screen or the boot snapshot calls `painted()`), so none of it
 * competes with the first paint. A surface the user asks for earlier loads
 * on that intent with its own placeholder and does not wait for this.
 */

export type WarmupTask = () => void | Promise<unknown>

export type WarmupOptions = {
  /** Runs `fn` after the next paint (a frame, then a task). */
  readonly afterPaint: (fn: () => void) => void
  /** The idle lane (`scheduler.idle`). A task returning true is run again later. */
  readonly idle: (task: () => boolean | void) => void
  /**
   * A timer (`setTimeout`), returning its cancel. A page that is never idle
   * (a busy timeline, an idle lane whose timeouts come with no time left)
   * would otherwise hold the queue for seconds: when no idle slice has run a
   * task for `maxWaitMs`, the next task runs from the timer. Omitted: idle
   * slices only.
   */
  readonly timeout?: (fn: () => void, ms: number) => () => void
  /** Default 1,000 ms. */
  readonly maxWaitMs?: number
  /** Where a failing task's error goes. */
  readonly onError?: (error: unknown) => void
}

export class Warmup {
  readonly #options: WarmupOptions
  readonly #queue: WarmupTask[] = []
  #painted = false
  #scheduled = false
  #cancelTimer: (() => void) | undefined

  constructor(options: WarmupOptions) {
    this.#options = options
  }

  /** Queue a task. After the first paint it runs on the next idle slice. */
  add(task: WarmupTask): void {
    this.#queue.push(task)
    if (this.#painted) this.#schedule()
  }

  /** The window painted for the first time. Repeats are ignored. */
  painted(): void {
    if (this.#painted) return
    this.#painted = true
    this.#options.afterPaint(() => this.#schedule())
  }

  get pending(): number {
    return this.#queue.length
  }

  #schedule(): void {
    if (this.#scheduled || this.#queue.length === 0) return
    this.#scheduled = true
    this.#options.idle(() => {
      this.#runOne()
      if (this.#queue.length > 0) {
        this.#arm()
        return true
      }
      this.#scheduled = false
      this.#disarm()
      return false
    })
    this.#arm()
  }

  /** (Re)start the fallback timer for the next task. */
  #arm(): void {
    const timeout = this.#options.timeout
    if (!timeout) return
    this.#disarm()
    this.#cancelTimer = timeout(() => {
      this.#cancelTimer = undefined
      this.#runOne()
      if (this.#queue.length > 0) this.#arm()
    }, this.#options.maxWaitMs ?? 1000)
  }

  #disarm(): void {
    this.#cancelTimer?.()
    this.#cancelTimer = undefined
  }

  #runOne(): void {
    const task = this.#queue.shift()
    if (!task) return
    try {
      const result = task()
      if (result && typeof (result as Promise<unknown>).catch === "function") {
        ;(result as Promise<unknown>).catch((error: unknown) => this.#options.onError?.(error))
      }
    } catch (error) {
      this.#options.onError?.(error)
    }
  }
}
