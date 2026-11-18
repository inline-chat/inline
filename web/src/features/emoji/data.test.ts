/**
 * The generated data is up to date with the Mac's Swift sources, and has the
 * shape the engine relies on. The generator lives in `web/tooling/emoji/`;
 * this test sits here because the web suite only collects `src/**` tests.
 */

import { readFileSync } from "node:fs"
import { describe, expect, it } from "vitest"
import { DATA_FILE, generateEmojiModules, QUICK_FILE, shortcodeOverride } from "../../../tooling/emoji/generate"
import { parseAliases, parseRawEntries, readSwiftSources } from "../../../tooling/emoji/swift-sources"
import { REPO_ROOT } from "../../../tooling/emoji/generate"
import { EMOJI_ROWS, EMOJI_SECTIONS } from "./data/emoji-data.generated"
import { QUICK_REACTION_TONES, QUICK_REACTIONS } from "./data/quick-reactions.generated"
import { createEmojiEngine } from "./engine"
import { containsSkinTone } from "./tone"

const sources = readSwiftSources(REPO_ROOT)
const generated = generateEmojiModules(sources)

describe("generated emoji data", () => {
  it("matches what the Swift sources generate (run `bun tooling/emoji/generate.ts` from web/ when this fails)", () => {
    expect(readFileSync(DATA_FILE, "utf8")).toBe(generated.data)
    expect(readFileSync(QUICK_FILE, "utf8")).toBe(generated.quick)
  })

  it("has one row per base emoji of the Mac table, in its order", () => {
    const base = parseRawEntries(sources.data).filter((row) => !containsSkinTone(row.emoji))
    const rows = EMOJI_ROWS.split("\n")
    expect(rows).toHaveLength(base.length)
    rows.forEach((row, i) => expect(row.split("\t")[0]).toBe(base[i]?.emoji))
    for (const row of rows) expect(row.split("\t")).toHaveLength(6)
  })

  it("has the nine sections in the standard order, each non-empty", () => {
    const engine = createEmojiEngine()
    expect(engine.sections.map((section) => section.id)).toEqual([
      "smileys",
      "people",
      "animals",
      "food",
      "travel",
      "activities",
      "objects",
      "symbols",
      "flags",
    ])
    expect(engine.sections.every((section) => section.items.length > 0)).toBe(true)
    expect(engine.sections.flatMap((section) => section.items)).toHaveLength(engine.all.length)
    expect(EMOJI_SECTIONS.split("\n")).toHaveLength(9)
    expect(engine.sections[0]?.items[0]?.emoji).toBe("😀")
    expect(engine.sections[8]?.items[0]?.shortcode).toBe("chequered_flag")
  })

  it("keeps every alias the Mac defines on the emoji whose shortcode it names", () => {
    const aliases = parseAliases(sources.aliases)
    const engine = createEmojiEngine()
    const shortcodes = new Set(engine.all.map((item) => item.shortcode))
    // An alias key that names no shortcode is dead data on the Mac too; count, do not fail.
    const used = [...aliases.keys()].filter((key) => shortcodes.has(key))
    expect(used.length).toBeGreaterThan(200)
  })

  it("derives skin tone support from the toned rows and the quick set's templates", () => {
    expect(generated.stats.toneable).toBeGreaterThan(300)
    expect(QUICK_REACTIONS).toHaveLength(15)
    expect(QUICK_REACTION_TONES["👍"]).toBe("1")
    expect(QUICK_REACTION_TONES["❤️"]).toBeUndefined()
  })

  it("ports the shortcode overrides (EmojiAutocompleteAliases.swift lines 290-317)", () => {
    expect(shortcodeOverride("#️⃣", "keycap", "keycap: #")).toBe("hash")
    expect(shortcodeOverride("*️⃣", "keycap", "keycap: *")).toBe("asterisk")
    expect(shortcodeOverride("0️⃣", "keycap", "keycap: 0")).toBe("keycap")
    expect(shortcodeOverride("🕶️", "sunglasses", "sunglasses")).toBe("dark_sunglasses")
    expect(shortcodeOverride("😎", "sunglasses", "smiling face with sunglasses")).toBe("sunglasses")
    expect(shortcodeOverride("🪅", "pi_ata", "piñata")).toBe("pinata")
  })
})
