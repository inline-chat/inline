/**
 * Frames and anchors for the pickers' popovers. Framework-free.
 *
 * A popover opened in code at start-up (a lab `?open=`, a restored state)
 * can open before its anchor is in the document or laid out; the kit's
 * positioning then has nothing to measure and the layer lands at the
 * window's corner. `openWhenAnchored` waits for the anchor instead, a frame
 * at a time, and opens on the first frame it can be placed.
 */

import type { Dispose } from "@inline/reactive"
import type { Rect } from "@inline/ui"

/** Runs a callback on the next frame. Injected in tests. */
export type FrameScheduler = (callback: () => void) => void

/** `requestAnimationFrame`, else a 16 ms timeout. Wrapped, never stored as a method. */
export const nextFrame: FrameScheduler = (callback) => {
  if (typeof globalThis.requestAnimationFrame === "function") globalThis.requestAnimationFrame(() => callback())
  else setTimeout(() => callback(), 16)
}

export type AnchorSource = () => Element | Rect | null | undefined

const isElement = (value: Element | Rect): value is Element => typeof (value as Element).getBoundingClientRect === "function"

/** Whether an anchor can place a popover: a point or rectangle, or an element in the document with a layout box. */
export const anchorReady = (anchor: Element | Rect | null | undefined): boolean => {
  if (!anchor) return false
  if (!isElement(anchor)) return true
  if (!anchor.isConnected) return false
  const rect = anchor.getBoundingClientRect()
  return rect.width > 0 || rect.height > 0 || rect.x !== 0 || rect.y !== 0
}

/** About half a second at 60 Hz; after that the popover opens anyway. */
export const MAX_ANCHOR_FRAMES = 30

/**
 * Run `open` now when the anchor can be placed, else on the first frame it
 * can (or after `maxFrames`, placed wherever the kit can). Returns a cancel.
 */
export const openWhenAnchored = (
  anchor: AnchorSource,
  open: () => void,
  frame: FrameScheduler = nextFrame,
  maxFrames: number = MAX_ANCHOR_FRAMES,
): Dispose => {
  let cancelled = false
  let frames = 0
  const attempt = () => {
    if (cancelled) return
    if (anchorReady(anchor()) || frames >= maxFrames) {
      open()
      return
    }
    frames += 1
    frame(attempt)
  }
  attempt()
  return () => {
    cancelled = true
  }
}

/** Focus an element that can take it (an anchor given as an element). */
export const focusable = (value: Element | Rect | null | undefined): HTMLElement | null =>
  value && isElement(value) && typeof (value as HTMLElement).focus === "function" && value.isConnected ? (value as HTMLElement) : null
