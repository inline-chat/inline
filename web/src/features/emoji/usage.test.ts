/**
 * The usage store and the quick reaction rules, against the Mac's tests
 * (`apple/InlineUI/Tests/InlineUITests/EmojiAutocompleteTests.swift`,
 * `apple/InlineUI/Tests/ReactionPickerEmojisTests/ReactionPickerEmojisTests.swift`).
 */

import { describe, expect, it } from "vitest"
import { createEmojiEngine } from "./engine"
import { isMessageEmoji, prioritizingMessageEmojis, QUICK_REACTIONS, quickRow, suggestedReactions } from "./quick"
import { usageKey } from "./tone"
import { EmojiUsage, frecencyScore, localStorageKeyValueStore, MAX_USAGE_ENTRIES, memoryKeyValueStore, normalizedEmoji, USAGE_KEYS } from "./usage"

const DAY = 86_400_000
const NOW = Date.UTC(2026, 10, 17)

const setup = (initial: Record<string, string> = {}) => {
  const store = memoryKeyValueStore(initial)
  let now = NOW
  const usage = new EmojiUsage({ store, now: () => now })
  return { store, usage, setNow: (ms: number) => (now = ms) }
}

describe("frecency (EmojiUsageStore.swift)", () => {
  it("ranks recent use over an old burst and ignores skin tone (usageStoreRanksFrecency)", () => {
    const { usage } = setup()
    const engine = createEmojiEngine()
    usage.record("🚀", NOW - 60 * DAY)
    usage.record("🚀", NOW - 60 * DAY)
    usage.record("👋🏽", NOW)
    usage.record("❤", NOW)
    usage.record("❤️", NOW)
    expect(usage.frequentlyUsed(3, (key) => engine.lookup(key)?.emoji)).toEqual(["❤️", "👋", "🚀"])
    expect(usage.scores().score(usageKey("👋🏿"))).toBeGreaterThan(0)
  })

  it("scores count decayed by a 10-day half-life plus a small floor (Entry.score)", () => {
    expect(frecencyScore({ count: 4, lastUsed: 0 }, 10 * 86_400)).toBeCloseTo(2 + 0.2)
    expect(frecencyScore({ count: 40, lastUsed: 0 }, 0)).toBeCloseTo(40 + 1)
  })

  it("keeps the 160 strongest entries", () => {
    const { usage, store } = setup()
    for (let i = 0; i < MAX_USAGE_ENTRIES + 5; i++) usage.record(String.fromCodePoint(0x1f600 + (i % 80)) + String(i), NOW - i * DAY)
    const saved = JSON.parse(store.get(USAGE_KEYS.frecency) ?? "{}") as Record<string, unknown>
    expect(Object.keys(saved)).toHaveLength(MAX_USAGE_ENTRIES)
    // The oldest were dropped.
    expect(Object.keys(saved).some((key) => key.endsWith(String(MAX_USAGE_ENTRIES + 4)))).toBe(false)
  })

  it("ignores blank input, removes, and survives corrupt storage", () => {
    const { usage } = setup({ [USAGE_KEYS.frecency]: "not json" })
    expect(usage.frequentlyUsed(5)).toEqual([])
    usage.record("   ")
    expect(usage.frequentlyUsed(5)).toEqual([])
    usage.record("🎉")
    usage.remove("🎉")
    expect(usage.frequentlyUsed(5)).toEqual([])
    expect(usage.frequentlyUsed(0)).toEqual([])
  })

  it("stores the Mac's shape: usage key to [count, last used in seconds]", () => {
    const { usage, store } = setup()
    usage.record("👍🏽")
    expect(JSON.parse(store.get(USAGE_KEYS.frecency) ?? "")).toEqual({ "👍": [1, NOW / 1000] })
  })

  it("bumps the revision on every write", () => {
    const { usage } = setup()
    const before = usage.revision.peek()
    usage.record("🎉")
    usage.recordReaction("🚀")
    expect(usage.revision.peek()).toBeGreaterThan(before + 1)
  })
})

describe("skin tone preference (EmojiSkinTonePreferenceStore)", () => {
  it("defaults to standard and persists (preferredSkinToneStoreDefaultsAndPersists)", () => {
    const { usage, store } = setup()
    expect(usage.skinTone.peek()).toBe("standard")
    usage.setSkinTone("mediumDark")
    expect(store.get(USAGE_KEYS.skinTone)).toBe("mediumDark")
    expect(new EmojiUsage({ store }).skinTone.peek()).toBe("mediumDark")
  })

  it("reads an unknown stored value as standard", () => {
    expect(setup({ [USAGE_KEYS.skinTone]: "purple" }).usage.skinTone.peek()).toBe("standard")
  })
})

describe("guarded localStorage", () => {
  it("reads empty and drops writes when storage throws", () => {
    const throwing = {
      getItem: () => {
        throw new Error("denied")
      },
      setItem: () => {
        throw new Error("quota")
      },
      removeItem: () => {
        throw new Error("denied")
      },
    } as unknown as Storage
    const store = localStorageKeyValueStore(() => throwing)
    expect(store.get("x")).toBeNull()
    expect(() => store.set("x", "1")).not.toThrow()
    expect(() => store.remove("x")).not.toThrow()
    expect(localStorageKeyValueStore(() => undefined).get("x")).toBeNull()
  })
})

describe("reaction picks (ReactionPickerEmojiUsageStore)", () => {
  it("records, ranks and removes picks (usageStoreRecordsRanksAndRemovesPicks)", () => {
    const { usage } = setup()
    usage.recordReaction("🚀")
    usage.recordReaction("🎉")
    usage.recordReaction("🚀")
    expect(usage.reactionCounts().get("🚀")).toBe(2)
    expect(suggestedReactions(usage.reactionCounts(), 3)).toEqual(["🚀", "🎉", "🥹"])
    usage.removeReactionSuggestion("🚀")
    expect(usage.reactionCounts().get("🚀")).toBeUndefined()
    expect(suggestedReactions(usage.reactionCounts(), 3)).toEqual(["🎉", "🥹", "❤️"])
    // A reaction also feeds frecency.
    expect(usage.frequentlyUsed(2)).toContain("🚀")
  })

  it("normalizes stored keys to their first grapheme and merges them", () => {
    const { usage } = setup({ [USAGE_KEYS.reactionCounts]: JSON.stringify({ " 🚀🔥 ": 2, "🚀": 1, "🎉": 0, "x": "nope" }) })
    expect([...usage.reactionCounts()]).toEqual([["🚀", 3]])
  })
})

describe("quick reactions (ReactionPickerEmojis.swift)", () => {
  it("unranked suggestions use the default set (unrankedSuggestionsUseDefaultReactions)", () => {
    expect(suggestedReactions(new Map())).toEqual([...QUICK_REACTIONS])
  })

  it("counted emoji replace defaults from the beginning (countedEmojisReplaceDefaultsFromBeginning)", () => {
    const result = suggestedReactions(new Map([["🚀", 3], ["🧠", 2]]))
    expect(result.slice(0, 4)).toEqual(["🚀", "🧠", "🥹", "❤️"])
    expect(result).toHaveLength(QUICK_REACTIONS.length)
  })

  it("never offers the legacy acknowledgement checks (legacyAcknowledgementChecksAreExcluded)", () => {
    expect(suggestedReactions(new Map([["✔️", 100], ["✓", 99], ["🚀", 1]]), 3)).toEqual(["🚀", "🥹", "❤️"])
  })

  it("ranks defaults by usage counts (defaultEmojisAreRankedByUsageCounts)", () => {
    expect(suggestedReactions(new Map([["🎉", 5], ["🚀", 4], ["👍", 3]]), 5)).toEqual(["🎉", "🚀", "👍", "🥹", "❤️"])
  })

  it("ties: default order first, then code point order", () => {
    expect(suggestedReactions(new Map([["🧠", 1], ["🎉", 1], ["🚀", 1], ["❤️", 1]]), 4)).toEqual(["❤️", "🎉", "🚀", "🧠"])
  })

  it("normalization keeps the first emoji cluster (normalizationKeepsFirstEmojiCluster)", () => {
    expect(normalizedEmoji(" 🚀🔥 ")).toBe("🚀")
    expect(normalizedEmoji("👨‍👩‍👧‍👦x")).toBe("👨‍👩‍👧‍👦")
    expect(normalizedEmoji(" \n ")).toBeUndefined()
  })

  it("message emoji come first (messageEmojisComeFirst)", () => {
    const usual = suggestedReactions(new Map([["🧠", 20]]))
    const result = prioritizingMessageEmojis("great work 🎉", usual)
    expect(result.slice(0, 4)).toEqual(["🎉", "🧠", "🥹", "❤️"])
    expect(result).toHaveLength(QUICK_REACTIONS.length)
    expect(result.filter((emoji) => emoji === "🎉")).toHaveLength(1)
  })

  it("keeps first appearance order without duplicates (multipleMessageEmojis)", () => {
    expect(prioritizingMessageEmojis("🔥 nice 🎉🔥\n❤️🎉", ["❤️", "👍", "🔥"])).toEqual(["🔥", "🎉", "❤️", "👍"])
  })

  it("keeps tones, flags, joined emoji and keycaps intact (complexMessageEmojis)", () => {
    expect(prioritizingMessageEmojis("👍🏽 👨‍👩‍👧‍👦 🇮🇷 👩🏾‍💻 1️⃣ #️⃣ *️⃣ 🏳️‍🌈", ["👍🏻", "👍🏽", "🥹"])).toEqual([
      "👍🏽",
      "👨‍👩‍👧‍👦",
      "🇮🇷",
      "👩🏾‍💻",
      "1️⃣",
      "#️⃣",
      "*️⃣",
      "🏳️‍🌈",
      "👍🏻",
      "🥹",
    ])
  })

  it("ignores text, numbers and text-presentation symbols (nonEmojiTextIsIgnored)", () => {
    const usual = ["🎉", "🥹", "❤️"]
    for (const text of [null, "", "hello سلام 123 #tag * © ™", "text ❤︎ ☀︎", "️ \u{1F3FD}"]) {
      expect(prioritizingMessageEmojis(text, usual)).toEqual(usual)
    }
  })

  it("recognizes emoji presentation symbols and bare hearts (emojiSymbols)", () => {
    expect(prioritizingMessageEmojis("©️ ™️ ❤ ❤️ ☀️", [])).toEqual(["©️", "™️", "❤", "❤️", "☀️"])
    expect(isMessageEmoji("❤")).toBe(true)
    expect(isMessageEmoji("1")).toBe(false)
  })

  it("obeys the limit (messageSuggestionLimits)", () => {
    expect(prioritizingMessageEmojis("🎉🔥❤️", ["🥹"], 2)).toEqual(["🎉", "🔥"])
    expect(prioritizingMessageEmojis("🎉", ["🥹"], 0)).toEqual([])
    expect(prioritizingMessageEmojis("🎉", ["🥹"], -1)).toEqual([])
  })

  it("stays bounded on long messages (longMessages)", () => {
    const text = "سلام hello 123 ".repeat(10_000) + "🎉".repeat(10_000) + "🔥"
    expect(prioritizingMessageEmojis(text, ["🥹"], 3)).toEqual(["🎉", "🔥", "🥹"])
    const many = "😀😃😄😁😆😅😂🤣🥲🥹😊😇🙂🙃😉😌"
    expect(prioritizingMessageEmojis(many, ["🔥"])).toEqual(Array.from(many).slice(0, 15))
  })

  it("preserves first occurrence for every ordering (orderingCombinations)", () => {
    const emojis = ["🎉", "🔥", "❤️", "👍🏽", "👩🏾‍💻", "🇮🇷", "1️⃣"]
    for (const a of emojis) {
      for (const b of emojis) {
        const expected = [a]
        if (a !== b) expected.push(b)
        for (const emoji of emojis) if (!expected.includes(emoji)) expected.push(emoji)
        for (const limit of [1, 3, 7, 15]) {
          expect(prioritizingMessageEmojis(`${a} text ${b} ${a}`, emojis, limit)).toEqual(expected.slice(0, limit))
        }
      }
    }
  })
})

describe("the quick row (ReactionOverlayView.reloadSuggestedReactions)", () => {
  it("applies the preferred tone, keeps message emoji exact, and marks removable and mine", () => {
    const row = quickRow({
      counts: new Map([["👍", 3]]),
      messageText: "ship it 🚀",
      tone: "medium",
      mine: new Set(["👍🏽"]),
    })
    expect(row.slice(0, 3).map((item) => item.emoji)).toEqual(["🚀", "👍🏽", "🥹"])
    expect(row[0]).toMatchObject({ fromMessage: true, removable: false, mine: false })
    expect(row[1]).toMatchObject({ source: "👍", fromMessage: false, removable: true, mine: true })
    expect(row[2]).toMatchObject({ removable: false })
    expect(row.find((item) => item.source === "👏")?.emoji).toBe("👏🏽")
    expect(row).toHaveLength(QUICK_REACTIONS.length)
  })

  it("uses a given tone template for recents outside the quick set", () => {
    const engine = createEmojiEngine()
    const row = quickRow({ counts: new Map([["👋", 1]]), tone: "dark", toneTemplate: (emoji) => engine.lookup(emoji)?.tone })
    expect(row[0]?.emoji).toBe("👋🏿")
  })
})
