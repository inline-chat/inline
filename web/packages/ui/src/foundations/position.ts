/**
 * Anchored layer positioning as a pure function of rectangles: placement,
 * flip, shift, size and arrow. CSS anchor positioning is newer than our
 * browser floor, so this is ours. All coordinates are viewport (fixed) pixels.
 *
 * Placements are logical: `inline-start` and `inline-end` sides, and `start`
 * and `end` alignment on the top and bottom sides, follow the writing direction.
 */

import type { Direction, Rect } from "./dom"

export type LogicalSide = "top" | "bottom" | "inline-start" | "inline-end"
export type Side = LogicalSide | "left" | "right"
export type Align = "start" | "center" | "end"
export type Placement = Side | `${Side}-${Align}`
export type PhysicalSide = "top" | "bottom" | "left" | "right"

export type PositionInput = {
  /** The anchor's rectangle; a zero-size rectangle anchors to a point. */
  anchor: Rect
  /** The floating element's natural size. */
  floating: { width: number; height: number }
  /** The area the layer must stay in, usually the viewport. */
  boundary: Rect
  placement?: Placement
  dir?: Direction
  /** Gap between anchor and layer on the main axis. */
  offset?: number
  /** Shift along the cross axis, toward the end of the alignment edge. */
  alignOffset?: number
  /** Minimum distance kept from the boundary. */
  padding?: number
  /** Move to the opposite side when the preferred one overflows. Default true. */
  flip?: boolean
  /** Use the opposite alignment before shifting when the cross axis overflows. Default false. */
  flipAlign?: boolean
  /** Keep the layer inside the boundary on the cross axis. Default true. */
  shift?: boolean
  /** Limit the layer to the space available on its side (sets maxWidth and maxHeight). Default true. */
  size?: boolean
  /** Point an arrow of this size at the anchor's center. */
  arrow?: { size: number; padding?: number }
}

export type PositionResult = {
  x: number
  y: number
  side: PhysicalSide
  align: Align
  /** Physical placement after flipping, for styling (`data-side`). */
  placement: `${PhysicalSide}-${Align}`
  /** Space on the chosen side, after padding and offset. */
  availableWidth: number
  availableHeight: number
  /** Upper bounds the layer should apply when `size` is on. */
  maxWidth: number
  maxHeight: number
  /** Arrow offset from the layer's left (top/bottom sides) or top (left/right sides). */
  arrow: { x?: number; y?: number } | null
}

const parsePlacement = (placement: Placement): { side: Side; align: Align } => {
  const match = /^(top|bottom|left|right|inline-start|inline-end)(?:-(start|center|end))?$/.exec(placement)
  if (!match) return { side: "bottom", align: "center" }
  return { side: match[1] as Side, align: (match[2] as Align | undefined) ?? "center" }
}

const physicalSide = (side: Side, dir: Direction): PhysicalSide => {
  if (side === "inline-start") return dir === "rtl" ? "right" : "left"
  if (side === "inline-end") return dir === "rtl" ? "left" : "right"
  return side
}

const opposite: Record<PhysicalSide, PhysicalSide> = { top: "bottom", bottom: "top", left: "right", right: "left" }

const isVertical = (side: PhysicalSide) => side === "top" || side === "bottom"

const clamp = (value: number, min: number, max: number) => (max < min ? min : Math.min(Math.max(value, min), max))

/** Physical alignment: start means left (vertical sides) or top (horizontal sides). */
const physicalAlign = (align: Align, side: PhysicalSide, dir: Direction): Align => {
  if (align === "center" || !isVertical(side) || dir === "ltr") return align
  return align === "start" ? "end" : "start"
}

const flipAlign = (align: Align): Align => (align === "start" ? "end" : align === "end" ? "start" : "center")

export const computePosition = (input: PositionInput): PositionResult => {
  const dir = input.dir ?? "ltr"
  const offset = input.offset ?? 0
  const alignOffset = input.alignOffset ?? 0
  const padding = input.padding ?? 0
  const useSize = input.size ?? true
  const { anchor, boundary, floating } = input
  const parsed = parsePlacement(input.placement ?? "bottom")
  let side = physicalSide(parsed.side, dir)
  let align = physicalAlign(parsed.align, side, dir)

  const bounds = {
    left: boundary.x + padding,
    top: boundary.y + padding,
    right: boundary.x + boundary.width - padding,
    bottom: boundary.y + boundary.height - padding,
  }

  const space = (candidate: PhysicalSide): number => {
    switch (candidate) {
      case "bottom":
        return bounds.bottom - (anchor.y + anchor.height + offset)
      case "top":
        return anchor.y - offset - bounds.top
      case "right":
        return bounds.right - (anchor.x + anchor.width + offset)
      case "left":
        return anchor.x - offset - bounds.left
    }
  }
  const need = (candidate: PhysicalSide) => (isVertical(candidate) ? floating.height : floating.width)

  if (input.flip ?? true) {
    if (space(side) < need(side)) {
      const other = opposite[side]
      if (space(other) >= need(other) || space(other) > space(side)) side = other
    }
  }

  const vertical = isVertical(side)
  const available = Math.max(0, space(side))
  const crossAvailable = Math.max(0, vertical ? bounds.right - bounds.left : bounds.bottom - bounds.top)
  const mainSize = useSize ? Math.min(need(side), available) : need(side)
  const crossNatural = vertical ? floating.width : floating.height
  const crossSize = useSize ? Math.min(crossNatural, crossAvailable) : crossNatural

  // Main axis.
  let x = 0
  let y = 0
  if (side === "bottom") y = anchor.y + anchor.height + offset
  else if (side === "top") y = anchor.y - offset - mainSize
  else if (side === "right") x = anchor.x + anchor.width + offset
  else x = anchor.x - offset - mainSize

  // Cross axis.
  const anchorStart = vertical ? anchor.x : anchor.y
  const anchorSize = vertical ? anchor.width : anchor.height
  const crossLow = vertical ? bounds.left : bounds.top
  const crossHigh = vertical ? bounds.right : bounds.bottom
  const crossFor = (candidate: Align): number => {
    if (candidate === "start") return anchorStart + alignOffset
    if (candidate === "end") return anchorStart + anchorSize - crossSize - alignOffset
    return anchorStart + (anchorSize - crossSize) / 2
  }
  let cross = crossFor(align)
  const overflows = (value: number) => value < crossLow || value + crossSize > crossHigh
  if (input.flipAlign && align !== "center" && overflows(cross)) {
    const flipped = crossFor(flipAlign(align))
    if (!overflows(flipped)) {
      align = flipAlign(align)
      cross = flipped
    }
  }
  if (input.shift ?? true) cross = clamp(cross, crossLow, crossHigh - crossSize)
  if (vertical) x = cross
  else y = cross

  let arrow: PositionResult["arrow"] = null
  if (input.arrow) {
    const arrowPadding = input.arrow.padding ?? 8
    const center = anchorStart + anchorSize / 2
    const position = clamp(
      center - cross - input.arrow.size / 2,
      arrowPadding,
      crossSize - arrowPadding - input.arrow.size,
    )
    arrow = vertical ? { x: position } : { y: position }
  }

  return {
    x: Math.round(x),
    y: Math.round(y),
    side,
    align,
    placement: `${side}-${align}`,
    availableWidth: vertical ? crossAvailable : available,
    availableHeight: vertical ? available : crossAvailable,
    maxWidth: vertical ? crossAvailable : available,
    maxHeight: vertical ? available : crossAvailable,
    arrow,
  }
}
