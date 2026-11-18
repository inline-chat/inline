/**
 * Which emoji this platform can draw. Emoji are native glyphs in the
 * platform's emoji font (no image sprites), so an emoji newer than the
 * system's font would show as a box or as its parts side by side. The
 * pickers hide those.
 *
 * The check is a seam: `createEmojiSupport({ probe })` takes any function
 * that says whether one emoji draws. The default probe, `canvasEmojiProbe`,
 * draws each emoji on a small canvas in the emoji font stack (behind a
 * second seam, `GlyphMeasure`, that returns the drawn glyph's metrics) and
 * compares it with 😀 drawn the same way (`measuredEmojiProbe`):
 *
 * - a sequence the font does not join renders as several glyphs: its
 *   advance or its ink is much wider than one emoji;
 * - a glyph from another font (a fallback face with other metrics) has ink
 *   much taller than the emoji font's, and draws clipped in a row sized for
 *   emoji;
 * - a missing glyph renders as a box or nothing in the fill color (black),
 *   so when the platform's emoji font paints (😀 has pixels in other colors),
 *   an emoji with no such pixel is missing. Gray and white emoji (💀, 🤍)
 *   still paint in gray or white, which is not the fill color. With a
 *   monochrome emoji font only the shape tests apply.
 *
 * `document.fonts.check()` cannot answer this: it reports whether a font
 * face is loaded, not whether the system fallback has a glyph. Nor can a
 * canvas see a glyph that draws whole but is cut by the layout around it.
 *
 * Results are kept for the page's life. Scanning runs in slices on an idle
 * callback; until an emoji is checked it counts as supported, and the
 * pickers read the results when they open, so nothing disappears under the
 * pointer. `check` answers for a few emoji at once (the quick row's), probing
 * any not checked yet.
 */

import { signal, type Dispose, type ReadSignal } from "@inline/reactive"
import { EMOJI_FONT_STACK } from "./font"

/** Whether one emoji draws. */
export type EmojiProbe = (emoji: string) => boolean

export type EmojiSupport = {
  /** Bumped when a scan finishes with results. */
  readonly revision: ReadSignal<number>
  /** False only for emoji found missing; unchecked emoji count as drawable. */
  isSupported(emoji: string): boolean
  /**
   * Probe now if not checked yet, and answer. For a handful of emoji about
   * to be shown (the quick row); does not bump `revision`, since the caller
   * reads the answer. Without a probe, true.
   */
  check(emoji: string): boolean
  /** Check emoji in slices. Returns a function that stops the scan. */
  scan(emojis: readonly string[]): Dispose
  /** How many emoji were checked and found missing so far. */
  readonly stats: () => { checked: number; missing: number }
}

export type EmojiSupportOptions = {
  /** The check; created on first scan. Undefined (no DOM, no canvas): everything counts as drawable. */
  readonly probe?: () => EmojiProbe | undefined
  /** Runs a slice when the main thread is idle; the slice returns true while there is more. */
  readonly schedule?: (slice: () => boolean) => void
  /** Emoji per slice. Default 48. */
  readonly sliceSize?: number
}

/** The idle lane's fallback: `requestIdleCallback` where it exists, else a timeout. Wrapped, never stored as a method. */
export const idleSchedule = (slice: () => boolean): void => {
  const run = () => {
    if (slice()) idleSchedule(slice)
  }
  if (typeof globalThis.requestIdleCallback === "function") globalThis.requestIdleCallback(() => run(), { timeout: 500 })
  else setTimeout(() => run(), 16)
}

export const createEmojiSupport = (options: EmojiSupportOptions = {}): EmojiSupport => {
  const missing = new Set<string>()
  const checked = new Set<string>()
  const revision = signal(0)
  let probe: EmojiProbe | undefined
  let probeMade = false
  const schedule = options.schedule ?? idleSchedule
  const sliceSize = Math.max(1, options.sliceSize ?? 48)

  const ensureProbe = (): EmojiProbe | undefined => {
    if (!probeMade) {
      probeMade = true
      try {
        probe = options.probe?.()
      } catch {
        probe = undefined
      }
    }
    return probe
  }
  /** Probe one unchecked emoji and record it. Returns whether it draws. */
  const probeOne = (current: EmojiProbe, emoji: string): boolean => {
    checked.add(emoji)
    let ok = true
    try {
      ok = current(emoji)
    } catch {
      ok = true
    }
    if (!ok) missing.add(emoji)
    return ok
  }

  return {
    revision,
    isSupported: (emoji) => !missing.has(emoji),
    check: (emoji) => {
      if (checked.has(emoji)) return !missing.has(emoji)
      const current = ensureProbe()
      return current ? probeOne(current, emoji) : true
    },
    stats: () => ({ checked: checked.size, missing: missing.size }),
    scan: (emojis) => {
      let stopped = false
      let index = 0
      let found = false
      const slice = (): boolean => {
        if (stopped) return false
        const current = ensureProbe()
        if (!current) return false
        const end = Math.min(emojis.length, index + sliceSize)
        for (; index < end; index++) {
          const emoji = emojis[index] as string
          if (checked.has(emoji)) continue
          if (!probeOne(current, emoji)) found = true
        }
        const more = index < emojis.length
        if (!more && found) revision.set(revision.peek() + 1)
        return more
      }
      schedule(slice)
      return () => {
        stopped = true
      }
    },
  }
}

/** What a probe measures of one drawn emoji. */
export type GlyphMetrics = {
  /** Advance width (`measureText`). */
  readonly advance: number
  /** The drawn ink's bounding box, in pixels. */
  readonly inkWidth: number
  readonly inkHeight: number
  /** Pixels with any coverage. */
  readonly inkPixels: number
  /** Pixels in a color other than the fill color (black): what a color font paints. */
  readonly paintedPixels: number
}

/** Draws one emoji and measures it. The seam behind `canvasEmojiProbe`; tests pass fakes. */
export type GlyphMeasure = (emoji: string) => GlyphMetrics

/** The known-good emoji every other is compared with. */
export const REFERENCE_EMOJI = "\u{1F600}"

/** Limits, as multiples of the reference's metrics. */
export const PROBE_LIMITS = {
  /** Advance or ink wider than this: several glyphs side by side. */
  width: 1.4,
  /** Ink taller than this: a glyph from a face with other metrics. */
  height: 1.3,
} as const

/**
 * A probe over measured glyphs (see the module comment). Undefined when the
 * reference does not measure (no font, no text drawing).
 */
export const measuredEmojiProbe = (measure: GlyphMeasure, reference: string = REFERENCE_EMOJI): EmojiProbe | undefined => {
  const base = measure(reference)
  if (!(base.advance > 0)) return undefined
  const colorFont = base.paintedPixels > 0
  // Without readable pixels (a blocked canvas), only the advance test applies.
  const hasInk = base.inkPixels > 0 && base.inkWidth > 0 && base.inkHeight > 0
  return (emoji) => {
    const glyph = measure(emoji)
    if (glyph.advance > base.advance * PROBE_LIMITS.width) return false
    if (hasInk) {
      if (glyph.inkPixels === 0) return false
      if (glyph.inkWidth > base.inkWidth * PROBE_LIMITS.width) return false
      if (glyph.inkHeight > base.inkHeight * PROBE_LIMITS.height) return false
    }
    if (colorFont && glyph.paintedPixels === 0) return false
    return true
  }
}

/**
 * Measure glyphs on a 2D canvas in the emoji font stack: 24 px text drawn
 * in black with room around it (so wide or tall ink is seen whole), then
 * the pixels read back.
 */
export const canvasGlyphMeasure = (doc: Document | undefined = globalThis.document): GlyphMeasure | undefined => {
  if (!doc) return undefined
  const width = 96
  const height = 56
  const canvas = doc.createElement("canvas")
  canvas.width = width
  canvas.height = height
  const context = canvas.getContext("2d", { willReadFrequently: true })
  if (!context) return undefined
  context.font = `24px ${EMOJI_FONT_STACK}`
  context.textBaseline = "top"
  context.fillStyle = "#000"
  return (emoji) => {
    const advance = context.measureText(emoji).width
    context.clearRect(0, 0, width, height)
    context.fillText(emoji, 8, 12)
    const pixels = context.getImageData(0, 0, width, height).data
    let inkPixels = 0
    let paintedPixels = 0
    let minX = width
    let minY = height
    let maxX = -1
    let maxY = -1
    for (let offset = 0, index = 0; offset < pixels.length; offset += 4, index++) {
      if ((pixels[offset + 3] ?? 0) === 0) continue
      inkPixels += 1
      if ((pixels[offset] ?? 0) !== 0 || (pixels[offset + 1] ?? 0) !== 0 || (pixels[offset + 2] ?? 0) !== 0) paintedPixels += 1
      const x = index % width
      const y = (index - x) / width
      if (x < minX) minX = x
      if (x > maxX) maxX = x
      if (y < minY) minY = y
      if (y > maxY) maxY = y
    }
    return {
      advance,
      inkPixels,
      paintedPixels,
      inkWidth: maxX >= minX ? maxX - minX + 1 : 0,
      inkHeight: maxY >= minY ? maxY - minY + 1 : 0,
    }
  }
}

/** The default probe: glyphs measured on a canvas, judged against 😀 (see the module comment). */
export const canvasEmojiProbe = (doc: Document | undefined = globalThis.document): EmojiProbe | undefined => {
  const measure = canvasGlyphMeasure(doc)
  return measure ? measuredEmojiProbe(measure) : undefined
}
