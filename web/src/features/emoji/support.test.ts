/**
 * Drawability: the probe's judgement over measured glyphs (fake measuring
 * seam), the canvas measuring itself over a fake 2D context, the
 * synchronous `check`, and the quick row skipping what cannot draw.
 */

import { describe, expect, it } from "vitest"
import { createEmojiEngine } from "./engine"
import { QUICK_REACTIONS, quickRow } from "./quick"
import { ReactionPickerController } from "./reaction-picker"
import { createEmojiServices } from "./services"
import {
  canvasEmojiProbe,
  canvasGlyphMeasure,
  createEmojiSupport,
  type GlyphMetrics,
  measuredEmojiProbe,
  REFERENCE_EMOJI,
} from "./support"
import { memoryKeyValueStore } from "./usage"

/** 😀 in a color emoji font at 24 px: about one em wide and tall, painted. */
const reference: GlyphMetrics = { advance: 30, inkWidth: 26, inkHeight: 26, inkPixels: 520, paintedPixels: 500 }

const fakeMeasure = (table: Record<string, Partial<GlyphMetrics>>, base: GlyphMetrics = reference) => (emoji: string): GlyphMetrics =>
  emoji === REFERENCE_EMOJI ? base : { ...reference, ...table[emoji] }

describe("measured probe", () => {
  const probe = measuredEmojiProbe(
    fakeMeasure({
      "🫡": {},
      // A ZWJ sequence the font does not join: two glyphs side by side.
      "🏃‍➡️": { advance: 58, inkWidth: 54 },
      // Ink twice as wide though the advance is not (glyphs drawn overlapping).
      "🧑‍🩰": { inkWidth: 50 },
      // A glyph from a fallback face with taller metrics: what draws clipped in a row sized for emoji.
      "🫩": { inkHeight: 38, inkWidth: 24 },
      // A missing glyph: a box in the fill color.
      "🪾": { paintedPixels: 0, inkPixels: 180 },
      // Drawn as nothing at all.
      "🫟": { inkPixels: 0, paintedPixels: 0, inkWidth: 0, inkHeight: 0 },
      // Gray and white emoji are painted (not the fill color), so they draw.
      "🤍": { paintedPixels: 410 },
      // Small ink is fine (▪️ is a small square).
      "▪️": { inkWidth: 8, inkHeight: 8, inkPixels: 64, paintedPixels: 64 },
    }),
  )

  it("passes a real glyph and small or gray ones", () => {
    expect(probe?.("🫡")).toBe(true)
    expect(probe?.("🤍")).toBe(true)
    expect(probe?.("▪️")).toBe(true)
  })

  it("fails a split sequence (advance or ink), a taller fallback glyph, a monochrome box and an empty drawing", () => {
    expect(probe?.("🏃‍➡️")).toBe(false)
    expect(probe?.("🧑‍🩰")).toBe(false)
    expect(probe?.("🫩")).toBe(false)
    expect(probe?.("🪾")).toBe(false)
    expect(probe?.("🫟")).toBe(false)
  })

  it("with a monochrome emoji font only the shape tests apply", () => {
    const mono = measuredEmojiProbe(
      fakeMeasure({ "🙂": { paintedPixels: 0 }, "🏃‍➡️": { advance: 58, paintedPixels: 0 } }, { ...reference, paintedPixels: 0 }),
    )
    expect(mono?.("🙂")).toBe(true)
    expect(mono?.("🏃‍➡️")).toBe(false)
  })

  it("without readable pixels (a blocked canvas) only the advance test applies", () => {
    const blind = measuredEmojiProbe(
      fakeMeasure({ "🙂": { inkPixels: 0, paintedPixels: 0, inkWidth: 0, inkHeight: 0 }, "🏃‍➡️": { advance: 58 } }, {
        advance: 30,
        inkWidth: 0,
        inkHeight: 0,
        inkPixels: 0,
        paintedPixels: 0,
      }),
    )
    expect(blind?.("🙂")).toBe(true)
    expect(blind?.("🏃‍➡️")).toBe(false)
  })

  it("no probe when the reference does not measure", () => {
    expect(measuredEmojiProbe(() => ({ advance: 0, inkWidth: 0, inkHeight: 0, inkPixels: 0, paintedPixels: 0 }))).toBeUndefined()
  })
})

describe("canvas measuring", () => {
  /**
   * A fake document whose 2D context "draws" each text as a block of one
   * color at the fill position: enough to check the pixel scan.
   */
  const fakeDocument = (glyphs: Record<string, { width: number; height: number; rgb: [number, number, number]; advance?: number }>) => {
    let canvasWidth = 0
    let canvasHeight = 0
    let drawn: { text: string; x: number; y: number } | null = null
    const context = {
      font: "",
      textBaseline: "",
      fillStyle: "",
      measureText: (text: string) => ({ width: glyphs[text]?.advance ?? glyphs[text]?.width ?? 0 }),
      clearRect: () => {
        drawn = null
      },
      fillText: (text: string, x: number, y: number) => {
        drawn = { text, x, y }
      },
      getImageData: (_x: number, _y: number, width: number, height: number) => {
        const data = new Uint8ClampedArray(width * height * 4)
        const glyph = drawn ? glyphs[drawn.text] : undefined
        if (drawn && glyph) {
          for (let y = drawn.y; y < Math.min(height, drawn.y + glyph.height); y++) {
            for (let x = drawn.x; x < Math.min(width, drawn.x + glyph.width); x++) {
              const offset = (y * width + x) * 4
              data.set([...glyph.rgb, 255], offset)
            }
          }
        }
        return { data }
      },
    }
    const canvas = {
      set width(value: number) {
        canvasWidth = value
      },
      get width() {
        return canvasWidth
      },
      set height(value: number) {
        canvasHeight = value
      },
      get height() {
        return canvasHeight
      },
      getContext: () => context,
    }
    return { createElement: () => canvas } as unknown as Document
  }

  const doc = fakeDocument({
    [REFERENCE_EMOJI]: { width: 26, height: 26, rgb: [250, 200, 40] },
    "🫡": { width: 26, height: 26, rgb: [240, 190, 50] },
    "💀": { width: 24, height: 26, rgb: [230, 230, 230] },
    "⬛": { width: 24, height: 24, rgb: [20, 20, 20] },
    "🪾": { width: 18, height: 22, rgb: [0, 0, 0] },
    "🫩": { width: 24, height: 40, rgb: [240, 190, 50] },
  })

  it("measures the ink box, coverage and painted pixels from the drawn pixels", () => {
    const measure = canvasGlyphMeasure(doc)
    expect(measure?.("🫩")).toEqual({ advance: 24, inkWidth: 24, inkHeight: 40, inkPixels: 960, paintedPixels: 960 })
    expect(measure?.("🪾")).toMatchObject({ inkPixels: 396, paintedPixels: 0 })
  })

  it("judges against 😀: gray and white emoji draw; a fill-color box and a taller glyph do not", () => {
    const probe = canvasEmojiProbe(doc)
    expect(probe?.("🫡")).toBe(true)
    expect(probe?.("💀")).toBe(true)
    expect(probe?.("⬛")).toBe(true)
    expect(probe?.("🪾")).toBe(false)
    expect(probe?.("🫩")).toBe(false)
  })

  it("no document, no probe", () => {
    expect(canvasEmojiProbe(undefined)).toBeUndefined()
  })
})

describe("check", () => {
  it("probes an unchecked emoji once, keeps the answer, and leaves the revision alone", () => {
    const calls: string[] = []
    const support = createEmojiSupport({
      probe: () => (emoji) => {
        calls.push(emoji)
        return emoji !== "🫡"
      },
      schedule: () => undefined,
    })
    expect(support.check("🫡")).toBe(false)
    expect(support.check("🫡")).toBe(false)
    expect(support.check("🎉")).toBe(true)
    expect(calls).toEqual(["🫡", "🎉"])
    expect(support.isSupported("🫡")).toBe(false)
    expect(support.revision.peek()).toBe(0)
    expect(support.stats()).toEqual({ checked: 2, missing: 1 })
  })

  it("without a probe everything draws and nothing is recorded", () => {
    const support = createEmojiSupport({ probe: () => undefined })
    expect(support.check("🫡")).toBe(true)
    expect(support.stats()).toEqual({ checked: 0, missing: 0 })
  })
})

describe("quick row and drawability", () => {
  const counts = new Map([
    ["🚀", 2],
    ["👀", 1],
  ])
  const message = "Shipped the new build 🚀 thanks everyone 🎉"

  it("skips what the platform cannot draw and fills from the default set, keeping 15", () => {
    const all = quickRow({ counts, messageText: message, tone: "standard" })
    expect(all.map((item) => item.emoji).slice(0, 7)).toEqual(["🚀", "🎉", "👀", "🥹", "❤️", "🫡", "👍"])
    const row = quickRow({ counts, messageText: message, tone: "standard", supported: (emoji) => emoji !== "🫡" })
    expect(row.map((item) => item.emoji)).not.toContain("🫡")
    expect(row).toHaveLength(QUICK_REACTIONS.length)
    expect(row.map((item) => item.emoji).slice(0, 7)).toEqual(["🚀", "🎉", "👀", "🥹", "❤️", "👍", "👎"])
    expect(row.at(-1)?.emoji).toBe("😢") // one further into the default set than without the check
    expect(all.at(-1)?.emoji).toBe("😮")
  })

  it("leaves out a message emoji the platform cannot draw", () => {
    const row = quickRow({ counts: new Map(), messageText: "ok 🫩 🎉", tone: "standard", supported: (emoji) => emoji !== "🫩" })
    expect(row[0]?.emoji).toBe("🎉")
    expect(row.map((item) => item.emoji)).not.toContain("🫩")
  })

  it("draws the same row as the Mac when everything draws (tone collisions still take a place)", () => {
    const toned = new Map([["👍🏽", 3]])
    const plain = quickRow({ counts: toned, tone: "medium" })
    const checked = quickRow({ counts: toned, tone: "medium", supported: () => true })
    expect(checked).toEqual(plain)
  })

  it("the reaction picker consults support for its row", () => {
    const missing = new Set(["🫡"])
    const services = createEmojiServices({
      store: memoryKeyValueStore(),
      importEngine: () => Promise.resolve(createEmojiEngine()),
      support: createEmojiSupport({ probe: () => (emoji) => !missing.has(emoji), schedule: () => undefined }),
    })
    const controller = new ReactionPickerController({ services, onChoose: () => undefined })
    controller.prepare({ messageText: message })
    const row = controller.quick.peek().map((item) => item.emoji)
    expect(row).not.toContain("🫡")
    expect(row).toHaveLength(QUICK_REACTIONS.length)
    expect(services.support.stats().missing).toBe(1)
    controller.dispose()
  })
})
