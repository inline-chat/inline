/**
 * The picker controllers on the real engine and usage store, without a DOM:
 * the full picker (`EmojiPickerPopover2.swift` behavior), the reaction
 * picker (`ReactionOverlayView.swift`), the composer's `:` source and emoji
 * button, and the drawability scan.
 */

import { signal } from "@inline/reactive"
import type { Trigger } from "@inline/composer"
import { describe, expect, it } from "vitest"
import { createAutocompleteCursor } from "../composer/autocomplete-cursor"
import { createComposerModel } from "../composer/model"
import { createEmojiSuggest } from "./composer-source"
import { ComposerEmojiPicker } from "./composer-picker"
import { reactionChipLabel, reactionTooltip } from "./display"
import { createEmojiEngine, type EmojiEngine } from "./engine"
import { GRID_METRICS } from "./grid"
import { EmojiPickerController, FREQUENT_SECTION_ID, type KeyInput } from "./picker"
import { QUICK_REACTIONS } from "./quick"
import { ReactionPickerController } from "./reaction-picker"
import { createEmojiEngineLoader, createEmojiServices, type EmojiServices } from "./services"
import { createEmojiSupport } from "./support"
import { memoryKeyValueStore } from "./usage"

const engine = createEmojiEngine()

/** Real services over memory storage; the engine "loads" when `resolve()` is called (or at once). */
const makeServices = (options: { loaded?: boolean; missing?: readonly string[] } = {}) => {
  let resolve: (() => void) | undefined
  const importEngine = () =>
    options.loaded === false
      ? new Promise<EmojiEngine>((done) => {
          resolve = () => done(engine)
        })
      : Promise.resolve(engine)
  const missing = new Set(options.missing ?? [])
  const slices: (() => boolean)[] = []
  const support = createEmojiSupport({ probe: () => (emoji) => !missing.has(emoji), schedule: (slice) => slices.push(slice) })
  const services = createEmojiServices({ store: memoryKeyValueStore(), now: () => Date.UTC(2026, 10, 17), importEngine, support })
  const runSlices = () => {
    while (slices.length > 0) {
      const slice = slices.shift()
      if (slice?.()) slices.push(slice)
    }
  }
  return { services, resolve: () => resolve?.(), runSlices }
}

const key = (k: string, extra: Partial<KeyInput> = {}): KeyInput => ({ key: k, ...extra })

const picker = (services: EmojiServices, extra: Partial<ConstructorParameters<typeof EmojiPickerController>[0]> = {}) => {
  const chosen: string[] = []
  const controller = new EmojiPickerController({
    engine,
    usage: services.usage,
    support: services.support,
    onChoose: (emoji) => chosen.push(emoji),
    direction: () => "ltr",
    ...extra,
  })
  return { controller, chosen }
}

describe("full picker: browsing", () => {
  it("shows the nine categories, and Frequently Used first once there is usage (browseSections)", () => {
    const { services } = makeServices()
    expect(picker(services).controller.sections.peek().map((section) => section.id)).toEqual([
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
    services.usage.record("🚀")
    services.usage.record("👍🏽")
    const { controller } = picker(services)
    const frequent = controller.sections.peek()[0]
    expect(frequent?.id).toBe(FREQUENT_SECTION_ID)
    expect(frequent?.title).toBe("Frequently Used")
    expect(frequent?.items.map((item) => item.info.emoji)).toEqual(["👍", "🚀"])
    expect(controller.tabs.map((tab) => tab.id)[0]).toBe(FREQUENT_SECTION_ID)
  })

  it("captures sections at open: usage after that does not reshuffle until reset", () => {
    const { services } = makeServices()
    const { controller } = picker(services)
    services.usage.record("🎉")
    expect(controller.sections.peek()[0]?.id).toBe("smileys")
    controller.reset()
    expect(controller.sections.peek()[0]?.id).toBe(FREQUENT_SECTION_ID)
  })

  it("shows every emoji in the preferred tone and follows a tone change live", () => {
    const { services } = makeServices()
    const { controller } = picker(services)
    const wave = () => controller.sections.peek()[1]?.items[0]
    expect(wave()?.emoji).toBe("👋")
    controller.setSkinTone("dark")
    expect(wave()?.emoji).toBe("👋🏿")
    expect(services.usage.skinTone.peek()).toBe("dark")
    expect(controller.toneSamples.map((sample) => sample.emoji)).toEqual(["✋", "✋🏻", "✋🏼", "✋🏽", "✋🏾", "✋🏿"])
  })

  it("hides emoji the platform cannot draw (support seam)", async () => {
    const { services, runSlices } = makeServices({ missing: ["🫨", "🇺🇸"] })
    await services.warm()
    {
      runSlices()
      const { controller } = picker(services)
      const all = controller.sections.peek().flatMap((section) => section.items.map((item) => item.info.emoji))
      expect(all).not.toContain("🫨")
      expect(all).not.toContain("🇺🇸")
      expect(all).toContain("😀")
      controller.setQuery("flag united")
      const results = controller.sections.peek()[0]?.items.map((item) => item.info.emoji) ?? []
      expect(results).toContain("🇬🇧")
      expect(results).not.toContain("🇺🇸")
    }
  })

  it("renders a bounded window of rows however long the list (virtualization)", () => {
    const { services } = makeServices()
    const { controller } = picker(services)
    controller.setViewport(GRID_METRICS.width, 292)
    const total = controller.layout.peek().rows.length
    expect(total).toBeGreaterThan(240)
    const counts = controller.renderedCounts()
    expect(counts.rows).toBeLessThanOrEqual(14)
    expect(counts.cells).toBeLessThanOrEqual(14 * 8)
    controller.setScrollTop(5000)
    expect(controller.renderedCounts().rows).toBeLessThanOrEqual(14)
    expect(controller.window.peek().start).toBeGreaterThan(100)
  })

  it("narrow widths get fewer columns", () => {
    const { services } = makeServices()
    const { controller } = picker(services)
    controller.setViewport(200, 292)
    expect(controller.columns.peek()).toBe(4)
  })

  it("a tab clears the search and scrolls to its section; the active tab follows the scroll", () => {
    const { services } = makeServices()
    const { controller } = picker(services)
    controller.setQuery("heart")
    controller.selectTab(3)
    expect(controller.query.peek()).toBe("")
    const top = controller.layout.peek().sections[3]?.top
    expect(controller.activeTab.peek()).toBe(3)
    expect(top).toBeGreaterThan(0)
    controller.setScrollTop(0)
    expect(controller.activeTab.peek()).toBe(0)
  })
})

describe("full picker: search and keys (EmojiPickerPopover2.swift lines 548-567, 785-821)", () => {
  it("searches with the shared ranking and highlights the first result so Return picks it", () => {
    const { services } = makeServices()
    const { controller, chosen } = picker(services)
    controller.setQuery("tada")
    expect(controller.sections.peek()).toHaveLength(1)
    expect(controller.preview.peek()?.info.shortcode).toBe("tada")
    expect(controller.activeTab.peek()).toBeNull()
    expect(controller.handleKey(key("Enter"), "search")).toBe(true)
    expect(chosen).toEqual(["🎉"])
  })

  it("an initial query (typed in the reaction row) searches from the start", () => {
    const { services } = makeServices()
    const { controller } = picker(services, { initialQuery: "rocket" })
    expect(controller.preview.peek()?.info.emoji).toBe("🚀")
  })

  it("no results: empty, and Return does nothing", () => {
    const { services } = makeServices()
    const { controller, chosen } = picker(services)
    controller.setQuery("zzzzqqq")
    expect(controller.isEmpty.peek()).toBe(true)
    controller.handleKey(key("Enter"), "search")
    expect(chosen).toEqual([])
  })

  it("from the search field: Down enters the grid at the first emoji; Left and Right edit text until then", () => {
    const { services } = makeServices()
    const { controller } = picker(services)
    expect(controller.handleKey(key("ArrowRight"), "search")).toBe(false)
    expect(controller.handleKey(key("ArrowDown"), "search")).toBe(true)
    expect(controller.highlight.peek()).toEqual({ section: 0, item: 0 })
    expect(controller.handleKey(key("ArrowRight"), "search")).toBe(true)
    expect(controller.highlight.peek()).toEqual({ section: 0, item: 1 })
    expect(controller.handleKey(key("ArrowDown"), "search")).toBe(true)
    expect(controller.highlight.peek()).toEqual({ section: 0, item: 9 })
    // Home and End stay with the text field's caret.
    expect(controller.handleKey(key("Home"), "search")).toBe(false)
  })

  it("in the grid: Home, End, Ctrl+End and paging; right-to-left mirrors the arrows", () => {
    const { services } = makeServices()
    let dir: "ltr" | "rtl" = "ltr"
    const { controller } = picker(services, { direction: () => dir })
    controller.handleKey(key("ArrowDown"), "grid")
    controller.handleKey(key("ArrowRight"), "grid")
    controller.handleKey(key("ArrowRight"), "grid")
    expect(controller.highlight.peek()).toEqual({ section: 0, item: 2 })
    controller.handleKey(key("End"), "grid")
    expect(controller.highlight.peek()).toEqual({ section: 0, item: 7 })
    controller.handleKey(key("Home"), "grid")
    expect(controller.highlight.peek()).toEqual({ section: 0, item: 0 })
    dir = "rtl"
    controller.handleKey(key("ArrowLeft"), "grid")
    expect(controller.highlight.peek()).toEqual({ section: 0, item: 1 })
    controller.handleKey(key("PageDown"), "grid")
    expect(controller.highlight.peek()?.item).toBeGreaterThan(40)
    controller.handleKey(key("End", { ctrlKey: true }), "grid")
    const sections = controller.sections.peek()
    expect(controller.highlight.peek()).toEqual({ section: sections.length - 1, item: (sections.at(-1)?.items.length ?? 0) - 1 })
  })

  it("moving the highlight scrolls just enough to keep it in view", () => {
    const { services } = makeServices()
    const { controller } = picker(services)
    controller.setViewport(GRID_METRICS.width, 292)
    controller.handleKey(key("ArrowDown"), "grid")
    for (let i = 0; i < 12; i++) controller.handleKey(key("ArrowDown"), "grid")
    const { start, end } = controller.window.peek()
    const highlight = controller.highlight.peek()
    const rows = controller.layout.peek().rows.slice(start, end)
    expect(rows.some((row) => row.kind === "cells" && row.section === highlight?.section && highlight.item >= row.start && highlight.item < row.start + row.count)).toBe(true)
  })

  it("typing in the grid searches; Backspace edits; Escape clears, then closes", () => {
    const { services } = makeServices()
    let closed = 0
    const { controller } = picker(services, { onRequestClose: () => closed++ })
    controller.handleKey(key("h"), "grid")
    controller.handleKey(key("i"), "grid")
    expect(controller.query.peek()).toBe("hi")
    controller.handleKey(key("Backspace"), "grid")
    expect(controller.query.peek()).toBe("h")
    expect(controller.handleKey(key("Escape"), "search")).toBe(true)
    expect(controller.query.peek()).toBe("")
    expect(closed).toBe(0)
    expect(controller.handleKey(key("Escape"), "search")).toBe(true)
    expect(closed).toBe(1)
  })

  it("Escape with an empty search is left to the popover when no close handler is given", () => {
    const { services } = makeServices()
    const { controller } = picker(services)
    expect(controller.handleKey(key("Escape"), "search")).toBe(false)
  })

  it("ignores keys during IME composition and leaves Tab alone", () => {
    const { services } = makeServices()
    const { controller } = picker(services)
    expect(controller.handleKey(key("Enter", { isComposing: true }), "search")).toBe(false)
    expect(controller.handleKey(key("Tab"), "grid")).toBe(false)
  })

  it("hover highlights and previews; leaving clears a pointer highlight but keeps a keyboard one", () => {
    const { services } = makeServices()
    const { controller, chosen } = picker(services)
    controller.hover({ section: 0, item: 3 })
    expect(controller.preview.peek()?.info.emoji).toBe("😁")
    controller.hover(null)
    expect(controller.highlight.peek()).toBeNull()
    controller.handleKey(key("ArrowDown"), "grid")
    controller.hover(null)
    expect(controller.highlight.peek()).toEqual({ section: 0, item: 0 })
    controller.choose({ section: 0, item: 3 })
    expect(chosen).toEqual(["😁"])
  })

  it("re-renders two rows when the highlight moves (one signal per row)", () => {
    const { services } = makeServices()
    const { controller } = picker(services)
    const row0 = controller.rowHighlight(0, 0, 8)
    const row1 = controller.rowHighlight(0, 8, 8)
    expect(controller.rowHighlight(0, 0, 8)).toBe(row0)
    controller.handleKey(key("ArrowDown"), "grid")
    expect([row0.get(), row1.get()]).toEqual([0, -1])
    controller.handleKey(key("ArrowDown"), "grid")
    expect([row0.get(), row1.get()]).toEqual([-1, 0])
  })

  it("tone menu: arrows move (mirrored in RTL), Return chooses, Escape closes", () => {
    const { services } = makeServices()
    const { controller } = picker(services)
    controller.openToneMenu()
    expect(controller.toneMenuOpen.peek()).toBe(true)
    controller.handleKey(key("ArrowRight"), "search")
    controller.handleKey(key("ArrowRight"), "search")
    expect(controller.toneFocus.peek()).toBe("mediumLight")
    controller.handleKey(key("Enter"), "search")
    expect(services.usage.skinTone.peek()).toBe("mediumLight")
    expect(controller.toneMenuOpen.peek()).toBe(false)
    controller.openToneMenu()
    controller.handleKey(key("Escape"), "search")
    expect(controller.toneMenuOpen.peek()).toBe(false)
    expect(services.usage.skinTone.peek()).toBe("mediumLight")
  })
})

describe("reaction picker (ReactionOverlayView.swift)", () => {
  const setup = (options: { loaded?: boolean } = {}) => {
    const base = makeServices(options)
    const chosen: { emoji: string; mine: boolean }[] = []
    const controller = new ReactionPickerController({
      services: base.services,
      onChoose: (emoji, mine) => chosen.push({ emoji, mine }),
      direction: () => "ltr",
    })
    return { ...base, controller, chosen }
  }

  it("builds the row on open: message emoji, then picks, then defaults, in the preferred tone", () => {
    const { controller, services } = setup()
    services.usage.recordReaction("🚀")
    services.usage.setSkinTone("medium")
    controller.prepare({ messageText: "nice 🔥", mine: ["👍🏽"] })
    const row = controller.quick.peek()
    expect(row.slice(0, 3).map((item) => item.emoji)).toEqual(["🔥", "🚀", "🥹"])
    expect(row.find((item) => item.emoji === "👍🏽")?.mine).toBe(true)
    expect(row).toHaveLength(QUICK_REACTIONS.length)
  })

  it("choosing adds and records, or removes without recording", () => {
    const { controller, chosen, services } = setup()
    controller.prepare({ mine: ["❤️"] })
    controller.choose("🎉")
    controller.choose("❤️")
    expect(chosen).toEqual([
      { emoji: "🎉", mine: false },
      { emoji: "❤️", mine: true },
    ])
    expect(services.usage.reactionCounts().get("🎉")).toBe(1)
    expect(services.usage.reactionCounts().get("❤️")).toBeUndefined()
  })

  it("keys: arrows rove (mirrored in RTL), End reaches the expand button, Return chooses, Down expands", async () => {
    const { controller, chosen } = setup()
    controller.prepare()
    controller.handleQuickKey(key("ArrowRight"))
    controller.handleQuickKey(key("ArrowRight"))
    expect(controller.focusIndex.peek()).toBe(2)
    controller.handleQuickKey(key("ArrowLeft"))
    expect(controller.focusIndex.peek()).toBe(1)
    controller.handleQuickKey(key("Enter"))
    expect(chosen.at(-1)?.emoji).toBe(QUICK_REACTIONS[1])
    controller.prepare()
    controller.handleQuickKey(key("End"))
    expect(controller.focusIndex.peek()).toBe(QUICK_REACTIONS.length)
    controller.handleQuickKey(key("Enter"))
    expect(controller.mode.peek()).toBe("full")
    await Promise.resolve()
    expect(controller.full.peek()).toBeDefined()
  })

  it("typing a letter opens the full picker searching for it, even before the data has loaded", async () => {
    const { controller, resolve } = setup({ loaded: false })
    controller.prepare()
    expect(controller.handleQuickKey(key("t"))).toBe(true)
    expect(controller.mode.peek()).toBe("full")
    expect(controller.loading.peek()).toBe(true)
    resolve()
    await new Promise((done) => setTimeout(done, 0))
    expect(controller.loading.peek()).toBe(false)
    expect(controller.full.peek()?.query.peek()).toBe("t")
    // Choosing in the full picker goes through the reaction path.
    controller.full.peek()?.setQuery("tada")
    controller.full.peek()?.handleKey(key("Enter"), "search")
  })

  it("Delete removes a learned suggestion; defaults and message emoji stay", () => {
    const { controller, services } = setup()
    services.usage.recordReaction("🚀")
    controller.prepare({ messageText: "🔥" })
    // Index 1 is 🚀 (the message's 🔥 is first).
    controller.handleQuickKey(key("ArrowRight"))
    expect(controller.handleQuickKey(key("Delete"))).toBe(true)
    expect(controller.quick.peek().map((item) => item.emoji)).not.toContain("🚀")
    controller.handleQuickKey(key("Home"))
    expect(controller.handleQuickKey(key("Delete"))).toBe(false)
  })

  it("follows a caller's target signal: a new target prepares the row, an update of the same one does not", () => {
    const base = makeServices()
    const target = signal<{ text: string } | undefined>(undefined)
    const order: string[] = []
    const controller = new ReactionPickerController({
      services: base.services,
      target,
      describe: (value) => ({ messageText: (value as { text: string }).text }),
      onChoose: (emoji) => order.push(`choose ${emoji} target=${target.peek()?.text ?? "none"}`),
    })
    const first = { text: "🔥" }
    target.set(first)
    expect(controller.quick.peek()[0]?.emoji).toBe("🔥")
    controller.expand()
    target.set(first)
    expect(controller.mode.peek()).toBe("full")
    target.set({ text: "🎉" })
    expect(controller.mode.peek()).toBe("quick")
    expect(controller.quick.peek()[0]?.emoji).toBe("🎉")
    // The caller's onChoose runs before the picker closes, while its target is still set.
    controller.choose("🎉")
    expect(order).toEqual(["choose 🎉 target=🎉"])
    controller.dispose()
  })

  it("reopening rebuilds the row and returns to quick mode", () => {
    const { controller } = setup()
    controller.prepare({ messageText: "🎉" })
    controller.expand()
    controller.prepare({ messageText: "🔥" })
    expect(controller.mode.peek()).toBe("quick")
    expect(controller.full.peek()).toBeUndefined()
    expect(controller.quick.peek()[0]?.emoji).toBe("🔥")
  })
})

describe("composer `:` source", () => {
  const trigger = (query: string): Trigger => ({ kind: "emoji", query, range: { from: 0, to: query.length + 1 } })

  it("loads the data on the first `:` and fills in when it arrives", async () => {
    const { services, resolve } = makeServices({ loaded: false })
    const deferred: (() => void)[] = []
    const source = createEmojiSuggest({ services, defer: (fn) => deferred.push(fn) })
    expect(source.suggest(trigger("tada"))).toEqual([])
    expect(deferred).toHaveLength(1)
    deferred[0]?.()
    resolve()
    await new Promise((done) => setTimeout(done, 0))
    const rows = source.suggest(trigger("tada"))
    expect(rows[0]).toMatchObject({ title: ":tada:", subtitle: "party popper", glyph: "🎉", item: { kind: "emoji", text: "🎉" } })
  })

  it("matches the Mac provider: 8 rows, ids, preferred tone, nothing for other triggers (providerMapsSuggestionsToComposeItems)", () => {
    const { services } = makeServices()
    const loader = createEmojiEngineLoader(() => Promise.resolve(engine))
    return loader.load().then(() => {
      const source = createEmojiSuggest({ services: { ...services, loader } })
      services.usage.setSkinTone("medium")
      const rows = source.rows("wave")
      expect(rows[0]?.emoji).toBe("👋🏽")
      expect(rows[0]?.title).toBe(":wave:")
      expect(new Set(rows.map((row) => row.id)).size).toBe(rows.length)
      expect(source.rows("face").length).toBe(8)
      expect(source.suggest({ kind: "mention", query: "wave", range: { from: 0, to: 5 } })).toEqual([])
      // One character: exact shortcodes and aliases only.
      expect(source.rows("x").map((row) => row.emoji)).toEqual(["❌"])
      // Rows keep identity while nothing changes.
      expect(source.rows("wave")[0]).toBe(rows[0])
      source.recordAccepted("👋🏽")
      expect(services.usage.frequentlyUsed(1)).toEqual(["👋"])
    })
  })

  it("counts a row accepted in a real composer for recents, and nothing for a dismissed list", async () => {
    const { services } = makeServices()
    const loader = createEmojiEngineLoader(() => Promise.resolve(engine))
    await loader.load()
    const source = createEmojiSuggest({ services: { ...services, loader } })
    const model = createComposerModel({
      safeUrl: () => null,
      send: () => ({ status: "accepted" }),
      platform: "mac",
      suggest: source.suggest,
      autocompleteChunk: { createAutocompleteCursor },
    })
    model.composer.insertText(":tad")
    model.composer.dismissAutocomplete()
    expect(services.usage.frequentlyUsed(3)).toEqual([])
    model.composer.insertText(" :wav")
    const wave = model.autocomplete.suggestions.peek()[0]!
    expect(model.autocomplete.accept(wave.id)).toBe(true)
    expect(model.composer.doc.peek().text).toBe(":tad 👋")
    expect(services.usage.frequentlyUsed(3)).toEqual(["👋"])
    model.dispose()
  })

  it("a minimum query length can be raised", () => {
    const { services } = makeServices()
    const loader = createEmojiEngineLoader(() => Promise.resolve(engine))
    return loader.load().then(() => {
      const source = createEmojiSuggest({ services: { ...services, loader }, minQueryLength: 2 })
      expect(source.rows("x")).toEqual([])
      expect(source.rows("xd").length).toBeGreaterThan(0)
    })
  })
})

describe("composer emoji button", () => {
  it("records the use, closes and inserts", () => {
    const { services } = makeServices()
    const inserted: string[] = []
    const button = new ComposerEmojiPicker({ services, onInsert: (emoji) => inserted.push(emoji) })
    button.choose("🎉")
    expect(inserted).toEqual(["🎉"])
    expect(services.usage.frequentlyUsed(1)).toEqual(["🎉"])
    button.dispose()
  })
})

describe("loader and support", () => {
  it("loads once, reports status, and retries after a failure", async () => {
    let calls = 0
    let fail = true
    const loader = createEmojiEngineLoader(() => {
      calls += 1
      return fail ? Promise.reject(new Error("offline")) : Promise.resolve(engine)
    })
    expect(loader.status.peek()).toBe("idle")
    await expect(loader.load()).rejects.toThrow("offline")
    expect(loader.status.peek()).toBe("error")
    fail = false
    await loader.load()
    await loader.load()
    expect(calls).toBe(2)
    expect(loader.status.peek()).toBe("ready")
    expect(loader.engine.peek()).toBe(engine)
  })

  it("scans in slices, bumps the revision once, and treats unchecked emoji as drawable", () => {
    const slices: (() => boolean)[] = []
    const support = createEmojiSupport({ probe: () => (emoji) => emoji !== "🫨", schedule: (slice) => slices.push(slice), sliceSize: 2 })
    const seen = signal(0)
    expect(support.isSupported("🫨")).toBe(true)
    support.scan(["😀", "🫨", "🎉", "🚀", "🔥"])
    let runs = 0
    while (slices.length > 0) {
      runs += 1
      const slice = slices.shift()
      if (slice?.()) slices.push(slice)
    }
    expect(runs).toBe(3)
    expect(support.isSupported("🫨")).toBe(false)
    expect(support.revision.peek()).toBe(1)
    expect(support.stats()).toEqual({ checked: 5, missing: 1 })
    expect(seen.peek()).toBe(0)
  })

  it("without a probe (no canvas), everything is drawable", () => {
    const slices: (() => boolean)[] = []
    const support = createEmojiSupport({ probe: () => undefined, schedule: (slice) => slices.push(slice) })
    support.scan(["🫨"])
    slices.shift()?.()
    expect(support.isSupported("🫨")).toBe(true)
  })
})

describe("reaction display helpers", () => {
  it("lists who reacted with You for the viewer (ReactionChipButton lines 235-241)", () => {
    expect(
      reactionTooltip(
        [
          { userId: "1", name: "Ada" },
          { userId: "2", name: "Bo" },
          { userId: "3", name: " " },
        ],
        "2",
      ),
    ).toBe("Ada, You")
  })

  it("names a chip by the emoji's CLDR name once loaded", () => {
    expect(reactionChipLabel({ emoji: "👍", count: 3, mine: true }, engine)).toBe("thumbs up, 3, including you")
    expect(reactionChipLabel({ emoji: "👍", count: 1, mine: false }, undefined)).toBe("👍, 1")
  })
})
