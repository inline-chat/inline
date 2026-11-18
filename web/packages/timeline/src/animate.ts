import { ease } from "./easing"
import type { Clock, FrameSource, ScrollAnimation } from "./host"

/**
 * Animate a scroll offset frame by frame. Shared by the DOM host and the
 * fake host so both move the same way. The first frame already moves; the
 * last frame writes `to` exactly and then calls `done`. The returned function
 * cancels and leaves the offset where it is.
 */
export const animateOffset = (
  frames: FrameSource,
  clock: Clock,
  read: () => number,
  write: (offset: number) => void,
  to: number,
  animation: ScrollAnimation,
  done: () => void,
): (() => void) => {
  const from = read()
  const startedAt = clock.now()
  let cancelled = false
  let cancelFrame: (() => void) | undefined

  if (animation.duration <= 0) {
    write(to)
    done()
    return () => {}
  }

  const step = (now: number) => {
    cancelFrame = undefined
    if (cancelled) return
    const progress = (now - startedAt) / animation.duration
    if (progress >= 1) {
      write(to)
      cancelled = true
      done()
      return
    }
    write(from + (to - from) * ease(animation.easing, progress))
    cancelFrame = frames.request(step)
  }
  cancelFrame = frames.request(step)

  return () => {
    cancelled = true
    cancelFrame?.()
    cancelFrame = undefined
  }
}
