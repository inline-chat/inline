/**
 * Waiting for frames, not for wall-clock time. An occluded or background
 * window throttles or stops animation frames; the lab then waits for the
 * frames it needs and fails with a clear error instead of measuring a frame
 * that never happened. Tested in `frames.test.ts` with an injected scheduler.
 */

export type FrameScheduler = {
  requestFrame(fn: (now: number) => void): () => void
  setTimeout(fn: () => void, ms: number): () => void
  now(): number
}

export const browserFrameScheduler = (): FrameScheduler => ({
  requestFrame: (fn) => {
    const id = globalThis.requestAnimationFrame(fn)
    return () => globalThis.cancelAnimationFrame(id)
  },
  setTimeout: (fn, ms) => {
    const id = globalThis.setTimeout(fn, ms)
    return () => globalThis.clearTimeout(id)
  },
  now: () => performance.now(),
})

/** How long one frame may take before the lab gives up. Generous: a busy main thread is not an error. */
export const FRAME_TIMEOUT_MS = 5_000

export class FrameTimeoutError extends Error {
  constructor(what: string, ms: number) {
    super(
      `${what}: no animation frame for ${ms} ms. The lab window is probably hidden, minimized or occluded, ` +
        "which stops animation frames. Bring it to the front and run again.",
    )
    this.name = "FrameTimeoutError"
  }
}

export class WaitTimeoutError extends Error {
  constructor(what: string, frames: number, ms: number) {
    super(`${what}: not reached after ${frames} frames (${Math.round(ms)} ms).`)
    this.name = "WaitTimeoutError"
  }
}

export const createFrameWaiter = (scheduler: FrameScheduler) => {
  /** The next animation frame. Rejects with `FrameTimeoutError` when none comes. */
  const nextFrame = (what = "Waiting for a frame", timeoutMs = FRAME_TIMEOUT_MS): Promise<number> =>
    new Promise((resolve, reject) => {
      let cancelTimer = () => {}
      const cancelFrame = scheduler.requestFrame((now) => {
        cancelTimer()
        resolve(now)
      })
      cancelTimer = scheduler.setTimeout(() => {
        cancelFrame()
        reject(new FrameTimeoutError(what, timeoutMs))
      }, timeoutMs)
    })

  /** `count` frames; `each` runs in every one (to sample layout as the frame is about to paint). */
  const frames = async (count: number, each?: (index: number) => void, what = "Waiting for frames") => {
    for (let i = 0; i < count; i++) {
      await nextFrame(what)
      each?.(i)
    }
  }

  /**
   * Frames until `condition` holds, checked in each frame. Gives up after
   * `maxFrames` frames or `maxMs`, whichever comes later (a throttled window
   * delivers few frames, a fast one many).
   */
  const until = async (
    condition: () => boolean,
    what: string,
    options: { maxFrames?: number; maxMs?: number; each?: () => void } = {},
  ): Promise<number> => {
    const maxFrames = options.maxFrames ?? 600
    const maxMs = options.maxMs ?? 10_000
    const started = scheduler.now()
    let count = 0
    while (!condition()) {
      await nextFrame(what)
      count += 1
      options.each?.()
      if (count >= maxFrames && scheduler.now() - started >= maxMs) throw new WaitTimeoutError(what, count, scheduler.now() - started)
    }
    return count
  }

  /** Wall-clock delay, for the lab's simulated network. Timers still fire in a throttled window. */
  const delay = (ms: number) =>
    new Promise<void>((resolve) => {
      scheduler.setTimeout(resolve, ms)
    })

  return { nextFrame, frames, until, delay }
}

export type FrameWaiter = ReturnType<typeof createFrameWaiter>
