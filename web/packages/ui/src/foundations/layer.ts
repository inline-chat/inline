/**
 * Layers on the platform's top layer. Anchored layers (menus, popovers,
 * tooltips, listbox popups) are `popover="manual"` elements: the top layer
 * puts them above everything without portals, and `manual` leaves dismissal
 * to the dismiss stack. Modal layers use `<dialog>.showModal()`.
 */

import { type Dispose, directionOf, listen, type Rect, rectOf, viewportRect } from "./dom"
import { computePosition, type PositionInput, type PositionResult } from "./position"

type PopoverElement = HTMLElement & { showPopover?: () => void; hidePopover?: () => void }

/** Marks an element as one of ours, so a focus trap underneath leaves it alone. */
export const LAYER_ATTRIBUTE = "data-ui-layer"

const isPopoverOpen = (element: HTMLElement): boolean => {
  try {
    return element.matches(":popover-open")
  } catch {
    return false
  }
}

/** Put an element in the top layer as a manual popover. Safe to call twice. */
export const showLayer = (element: HTMLElement): void => {
  element.setAttribute(LAYER_ATTRIBUTE, "")
  if (!element.hasAttribute("popover")) element.setAttribute("popover", "manual")
  const popover = element as PopoverElement
  if (typeof popover.showPopover === "function" && element.isConnected && !isPopoverOpen(element)) {
    try {
      popover.showPopover()
    } catch {
      // Already shown, or not connected. The layer still works in place.
    }
  }
}

export const hideLayer = (element: HTMLElement): void => {
  const popover = element as PopoverElement
  if (typeof popover.hidePopover === "function" && isPopoverOpen(element)) {
    try {
      popover.hidePopover()
    } catch {
      // Already hidden.
    }
  }
}

/**
 * Move a layer to the top of the top layer, above layers opened after it
 * (a toast region after a modal dialog opens, for example).
 */
export const raiseLayer = (element: HTMLElement): void => {
  if (!isPopoverOpen(element)) return
  hideLayer(element)
  showLayer(element)
}

export type AnchorSource = Element | Rect | (() => Element | Rect | null)

export type PlaceOptions = Omit<PositionInput, "anchor" | "floating" | "boundary" | "dir"> & {
  anchor: AnchorSource
  boundary?: () => Rect
}

const resolveAnchor = (source: AnchorSource): Rect | null => {
  const value = typeof source === "function" ? source() : source
  if (!value) return null
  return value instanceof Element ? rectOf(value) : value
}

/** Measure, compute and write a layer's position. Returns the result, or null without an anchor. */
export const placeLayer = (floating: HTMLElement, options: PlaceOptions): PositionResult | null => {
  const anchor = resolveAnchor(options.anchor)
  if (!anchor) return null
  const doc = floating.ownerDocument
  const measured = floating.getBoundingClientRect()
  const result = computePosition({
    ...options,
    anchor,
    floating: {
      width: Math.max(measured.width, floating.scrollWidth),
      height: Math.max(measured.height, floating.scrollHeight),
    },
    boundary: options.boundary?.() ?? viewportRect(doc),
    dir: directionOf(floating),
  })
  const style = floating.style
  style.position = "fixed"
  style.inset = "auto"
  style.margin = "0"
  style.left = `${result.x}px`
  style.top = `${result.y}px`
  style.setProperty("--ui-available-width", `${result.maxWidth}px`)
  style.setProperty("--ui-available-height", `${result.maxHeight}px`)
  if (result.arrow?.x !== undefined) style.setProperty("--ui-arrow-x", `${result.arrow.x}px`)
  if (result.arrow?.y !== undefined) style.setProperty("--ui-arrow-y", `${result.arrow.y}px`)
  floating.setAttribute("data-side", result.side)
  floating.setAttribute("data-align", result.align)
  return result
}

/** Keep a layer placed while the page scrolls, resizes, or the layer's content changes. */
export const trackLayer = (floating: HTMLElement, options: PlaceOptions): Dispose => {
  const view = floating.ownerDocument.defaultView
  let frame = 0
  const schedule = () => {
    if (!view || frame) return
    frame = view.requestAnimationFrame(() => {
      frame = 0
      placeLayer(floating, options)
    })
  }
  placeLayer(floating, options)
  const disposers: Dispose[] = []
  if (view) {
    disposers.push(listen(view, "resize", schedule), listen(view, "scroll", schedule, { capture: true, passive: true }))
  }
  if (view && "ResizeObserver" in view) {
    const observer = new view.ResizeObserver(schedule)
    observer.observe(floating)
    const anchor = typeof options.anchor === "function" ? options.anchor() : options.anchor
    if (anchor instanceof Element) observer.observe(anchor)
    disposers.push(() => observer.disconnect())
  }
  return () => {
    if (frame && view) view.cancelAnimationFrame(frame)
    for (const dispose of disposers) dispose()
  }
}
