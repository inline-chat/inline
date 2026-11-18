/**
 * Hover intent for submenus: when the pointer leaves a submenu's trigger
 * toward the open submenu, it may cross sibling items on the way. While the
 * pointer stays inside the "safe triangle" (from the exit point to the
 * submenu's near edge) and keeps moving within the grace period, those
 * crossings do not change the highlight or close the submenu.
 */

import { type Clock, systemClock, Timer } from "./clock"
import type { Rect } from "./dom"

export type Point = { x: number; y: number }

/** Ray-casting point-in-polygon test. Points on an edge may go either way. */
export const isPointInPolygon = (point: Point, polygon: readonly Point[]): boolean => {
  let inside = false
  for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    const a = polygon[i]!
    const b = polygon[j]!
    const crosses = a.y > point.y !== b.y > point.y && point.x < ((b.x - a.x) * (point.y - a.y)) / (b.y - a.y) + a.x
    if (crosses) inside = !inside
  }
  return inside
}

/**
 * The safe area from `exit` to the target rectangle's near edge. It is a
 * quadrilateral so the pointer can travel anywhere along the target's height.
 * `bleed` widens the apex a little so a pointer resting at the exit counts.
 */
export const safePolygon = (exit: Point, target: Rect, bleed = 6): Point[] => {
  const targetIsRight = target.x + target.width / 2 > exit.x
  const nearX = targetIsRight ? target.x : target.x + target.width
  const farX = targetIsRight ? target.x + target.width : target.x
  const apexX = exit.x + (targetIsRight ? -bleed : bleed)
  return [
    { x: apexX, y: exit.y - bleed },
    { x: nearX, y: target.y },
    { x: farX, y: target.y },
    { x: farX, y: target.y + target.height },
    { x: nearX, y: target.y + target.height },
    { x: apexX, y: exit.y + bleed },
  ]
}

export type HoverIntentOptions = {
  clock?: Clock
  /** How long the pointer may linger in the safe area before intent expires. Default 300ms. */
  grace?: number
  /** Called when the grace period runs out without reaching the target. */
  onExpire?: () => void
}

export class HoverIntent {
  #polygon: Point[] | null = null
  readonly #timer: Timer
  readonly #grace: number
  readonly #onExpire: (() => void) | undefined

  constructor(options: HoverIntentOptions = {}) {
    this.#timer = new Timer(options.clock ?? systemClock)
    this.#grace = options.grace ?? 300
    this.#onExpire = options.onExpire
  }

  get active(): boolean {
    return this.#polygon !== null
  }

  /** Start tracking from the point where the pointer left the trigger. */
  begin(exit: Point, target: Rect): void {
    this.#polygon = safePolygon(exit, target)
    this.#arm()
  }

  /**
   * Feed a pointer position. True while the pointer is still on its way to
   * the target; false (and intent ends) once it leaves the safe area.
   */
  isInTransit(point: Point): boolean {
    if (!this.#polygon) return false
    if (isPointInPolygon(point, this.#polygon)) {
      this.#arm()
      return true
    }
    this.end()
    return false
  }

  end(): void {
    this.#polygon = null
    this.#timer.stop()
  }

  #arm(): void {
    this.#timer.start(this.#grace, () => {
      this.#polygon = null
      this.#onExpire?.()
    })
  }
}
