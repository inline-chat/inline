/**
 * Small, pure sRGB color math: parse the forms our tokens use, blend and
 * composite the way AppKit does, and measure WCAG contrast. No DOM.
 */

/** sRGB components 0..255 (not rounded) and alpha 0..1. */
export type Rgba = { r: number; g: number; b: number; a: number }

const clamp = (value: number, min: number, max: number) => Math.min(max, Math.max(min, value))

/** `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb(r g b)`, `rgb(r g b / a)`, `rgb(r, g, b)`, `rgba(r, g, b, a)`. */
export function parseColor(input: string): Rgba {
  const text = input.trim().toLowerCase()
  if (text.startsWith("#")) {
    let hex = text.slice(1)
    if (hex.length === 3) hex = [...hex].map((c) => c + c).join("")
    if ((hex.length !== 6 && hex.length !== 8) || !/^[0-9a-f]+$/.test(hex)) throw new Error(`Not a color: ${input}`)
    const at = (i: number) => parseInt(hex.slice(i, i + 2), 16)
    return { r: at(0), g: at(2), b: at(4), a: hex.length === 8 ? at(6) / 255 : 1 }
  }
  const match = /^rgba?\(([^)]*)\)$/.exec(text)
  if (match?.[1] !== undefined) {
    const parts = match[1].split(/[\s,/]+/).filter(Boolean)
    if (parts.length < 3 || parts.length > 4) throw new Error(`Not a color: ${input}`)
    const num = (part: string, scale: number) =>
      part.endsWith("%") ? (parseFloat(part) / 100) * scale : parseFloat(part)
    const [r, g, b, a] = parts
    const color = {
      r: num(r ?? "", 255),
      g: num(g ?? "", 255),
      b: num(b ?? "", 255),
      a: a === undefined ? 1 : num(a, 1),
    }
    if (Object.values(color).some((v) => !Number.isFinite(v))) throw new Error(`Not a color: ${input}`)
    return color
  }
  if (text === "white") return { r: 255, g: 255, b: 255, a: 1 }
  if (text === "black") return { r: 0, g: 0, b: 0, a: 1 }
  throw new Error(`Not a color: ${input}`)
}

/** Splits `light-dark(a, b)` into its two sides; a plain color is the same on both. */
export function splitLightDark(input: string): { light: string; dark: string } {
  const text = input.trim()
  if (!text.startsWith("light-dark(") || !text.endsWith(")")) return { light: text, dark: text }
  const body = text.slice("light-dark(".length, -1)
  let depth = 0
  for (let i = 0; i < body.length; i++) {
    const c = body[i]
    if (c === "(") depth++
    else if (c === ")") depth--
    else if (c === "," && depth === 0) return { light: body.slice(0, i).trim(), dark: body.slice(i + 1).trim() }
  }
  throw new Error(`Malformed light-dark(): ${input}`)
}

export const toHex = (color: Rgba): string => {
  const channel = (v: number) => Math.round(clamp(v, 0, 255)).toString(16).padStart(2, "0")
  const alpha = color.a >= 1 ? "" : channel(color.a * 255)
  return `#${channel(color.r)}${channel(color.g)}${channel(color.b)}${alpha}`
}

/** `rgb(r g b / a)` with rounded channels, the form the tokens use for translucent colors. */
export const toRgbString = (color: Rgba): string => {
  const c = (v: number) => Math.round(clamp(v, 0, 255))
  const alpha = Math.round(color.a * 1000) / 1000
  return alpha >= 1 ? `rgb(${c(color.r)} ${c(color.g)} ${c(color.b)})` : `rgb(${c(color.r)} ${c(color.g)} ${c(color.b)} / ${alpha})`
}

/** Rounds channels to whole 8-bit values, as a stored color would be. */
export const quantize = (color: Rgba): Rgba => ({
  r: Math.round(clamp(color.r, 0, 255)),
  g: Math.round(clamp(color.g, 0, 255)),
  b: Math.round(clamp(color.b, 0, 255)),
  a: color.a,
})

/**
 * Component-wise linear blend, like `NSColor.blended(withFraction:of:)`:
 * `fraction` 0 is `from`, 1 is `to`.
 */
export const blend = (from: Rgba, to: Rgba, fraction: number): Rgba => ({
  r: from.r + (to.r - from.r) * fraction,
  g: from.g + (to.g - from.g) * fraction,
  b: from.b + (to.b - from.b) * fraction,
  a: from.a + (to.a - from.a) * fraction,
})

/** Source-over compositing of `top` onto `bottom`; the result is opaque when `bottom` is. */
export const composite = (top: Rgba, bottom: Rgba): Rgba => {
  const a = top.a + bottom.a * (1 - top.a)
  if (a === 0) return { r: 0, g: 0, b: 0, a: 0 }
  const mix = (t: number, b: number) => (t * top.a + b * bottom.a * (1 - top.a)) / a
  return { r: mix(top.r, bottom.r), g: mix(top.g, bottom.g), b: mix(top.b, bottom.b), a }
}

export const withAlpha = (color: Rgba, a: number): Rgba => ({ ...color, a })

/** Multiplies the channels: `scale(c, 0.93)` is 7% darker. */
export const scale = (color: Rgba, factor: number): Rgba => ({
  r: color.r * factor,
  g: color.g * factor,
  b: color.b * factor,
  a: color.a,
})

export type Hsb = { h: number; s: number; b: number }

/** Hue 0..1, saturation 0..1, brightness 0..1 (AppKit's HSB). */
export const toHsb = (color: Rgba): Hsb => {
  const r = color.r / 255
  const g = color.g / 255
  const b = color.b / 255
  const max = Math.max(r, g, b)
  const min = Math.min(r, g, b)
  const delta = max - min
  let h = 0
  if (delta > 0) {
    if (max === r) h = ((g - b) / delta) % 6
    else if (max === g) h = (b - r) / delta + 2
    else h = (r - g) / delta + 4
    h /= 6
    if (h < 0) h += 1
  }
  return { h, s: max === 0 ? 0 : delta / max, b: max }
}

export const fromHsb = ({ h, s, b }: Hsb, a = 1): Rgba => {
  const i = Math.floor(h * 6)
  const f = h * 6 - i
  const p = b * (1 - s)
  const q = b * (1 - f * s)
  const t = b * (1 - (1 - f) * s)
  const table: Array<[number, number, number]> = [
    [b, t, p],
    [q, b, p],
    [p, b, t],
    [p, q, b],
    [t, p, b],
    [b, p, q],
  ]
  const [r, g, bl] = table[((i % 6) + 6) % 6] ?? [b, t, p]
  return { r: r * 255, g: g * 255, b: bl * 255, a }
}

/** WCAG 2 relative luminance of an opaque color. */
export const relativeLuminance = (color: Rgba): number => {
  const lin = (v: number) => {
    const c = v / 255
    return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
  }
  return 0.2126 * lin(color.r) + 0.7152 * lin(color.g) + 0.0722 * lin(color.b)
}

/**
 * WCAG 2 contrast ratio of `foreground` on `background`. A translucent
 * foreground is composited onto the background first; a translucent
 * background is composited onto `canvas` (white by default).
 */
export const contrastRatio = (foreground: Rgba, background: Rgba, canvas: Rgba = parseColor("#ffffff")): number => {
  const bg = background.a < 1 ? composite(background, canvas) : background
  const fg = foreground.a < 1 ? composite(foreground, bg) : foreground
  const l1 = relativeLuminance(fg)
  const l2 = relativeLuminance(bg)
  const [hi, lo] = l1 > l2 ? [l1, l2] : [l2, l1]
  return (hi + 0.05) / (lo + 0.05)
}

/** WCAG 2.x AA thresholds. */
export const WCAG_AA_BODY_TEXT = 4.5
export const WCAG_AA_LARGE_TEXT = 3
export const WCAG_AA_NON_TEXT = 3
