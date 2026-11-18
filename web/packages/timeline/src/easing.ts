import type { Easing } from "./host"

/**
 * Cubic Bézier timing functions with the control points of Core Animation's
 * named curves, which the Mac client's jumps use (`CAMediaTimingFunction`):
 * easeIn (0.42, 0, 1, 1), easeOut (0, 0, 0.58, 1), easeInEaseOut
 * (0.42, 0, 0.58, 1). They match CSS `ease-in`, `ease-out`, `ease-in-out`.
 */
const cubicBezier = (x1: number, y1: number, x2: number, y2: number): ((t: number) => number) => {
  const cx = 3 * x1
  const bx = 3 * (x2 - x1) - cx
  const ax = 1 - cx - bx
  const cy = 3 * y1
  const by = 3 * (y2 - y1) - cy
  const ay = 1 - cy - by
  const sampleX = (t: number) => ((ax * t + bx) * t + cx) * t
  const sampleY = (t: number) => ((ay * t + by) * t + cy) * t
  const slopeX = (t: number) => (3 * ax * t + 2 * bx) * t + cx

  const solveX = (x: number): number => {
    // Newton's method, then bisection where the slope is too flat.
    let t = x
    for (let i = 0; i < 8; i++) {
      const error = sampleX(t) - x
      if (Math.abs(error) < 1e-6) return t
      const slope = slopeX(t)
      if (Math.abs(slope) < 1e-6) break
      t -= error / slope
    }
    let lo = 0
    let hi = 1
    t = x
    while (lo < hi) {
      const value = sampleX(t)
      if (Math.abs(value - x) < 1e-6) return t
      if (x > value) lo = t
      else hi = t
      const next = (lo + hi) / 2
      if (next === t) break
      t = next
    }
    return t
  }

  return (progress: number) => {
    if (progress <= 0) return 0
    if (progress >= 1) return 1
    return sampleY(solveX(progress))
  }
}

const curves: Record<Easing, (t: number) => number> = {
  linear: (t) => Math.min(1, Math.max(0, t)),
  easeIn: cubicBezier(0.42, 0, 1, 1),
  easeOut: cubicBezier(0, 0, 0.58, 1),
  easeInOut: cubicBezier(0.42, 0, 0.58, 1),
}

/** Progress 0..1 through time mapped to progress 0..1 through distance. */
export const ease = (easing: Easing, progress: number): number => curves[easing](progress)
