import { describe, expect, it } from "vitest"
import {
  DEFAULT_APPEARANCE_SETTINGS,
  lineSpacingTitle,
  nextLargerTextSize,
  nextSmallerTextSize,
  parseAppearanceSettings,
  serializeAppearanceSettings,
} from "./settings"

describe("parseAppearanceSettings", () => {
  it("returns the Mac app's defaults for nothing and for garbage", () => {
    for (const input of [undefined, null, "", "{", "[]", 42, true, [], "null", Symbol.iterator]) {
      expect(parseAppearanceSettings(input)).toEqual(DEFAULT_APPEARANCE_SETTINGS)
    }
    expect(DEFAULT_APPEARANCE_SETTINGS).toMatchObject({
      appearance: "system",
      theme: "system",
      textSize: 13,
      lineSpacing: 1,
      sidebarItemSize: "compact",
      messageStyle: "bubble",
      unreadBadgeStyle: "dot",
      compactToolbar: false,
      centeredChats: true,
    })
  })

  it("round-trips through its serialized form", () => {
    const settings = parseAppearanceSettings({
      version: 1,
      appearance: "dark",
      theme: "neon-noir",
      textSize: 17,
      lineSpacing: 1.3,
      messageFont: "monospace",
      sidebarItemSize: "standard",
      messageStyle: "minimal",
      unreadBadgeStyle: "numbered",
      compactToolbar: true,
      centeredChats: false,
    })
    expect(parseAppearanceSettings(serializeAppearanceSettings(settings))).toEqual(settings)
    expect(parseAppearanceSettings(settings)).toEqual(settings)
  })

  it("keeps valid fields when others are broken", () => {
    expect(parseAppearanceSettings({ version: 1, theme: "pink", appearance: 7, textSize: "huge", centeredChats: "no" })).toEqual({
      ...DEFAULT_APPEARANCE_SETTINGS,
      theme: "pink",
    })
  })

  it("clamps sizes like ChatTypography and keeps off-step values", () => {
    expect(parseAppearanceSettings({ textSize: 100 }).textSize).toBe(32)
    expect(parseAppearanceSettings({ textSize: 4 }).textSize).toBe(10)
    expect(parseAppearanceSettings({ textSize: 13.5 }).textSize).toBe(13.5)
    expect(parseAppearanceSettings({ textSize: 0 }).textSize).toBe(13)
    expect(parseAppearanceSettings({ textSize: -3 }).textSize).toBe(13)
    expect(parseAppearanceSettings({ textSize: Number.POSITIVE_INFINITY }).textSize).toBe(13)
    expect(parseAppearanceSettings({ lineSpacing: 5 }).lineSpacing).toBe(2)
    expect(parseAppearanceSettings({ lineSpacing: 0.8 }).lineSpacing).toBe(1)
    expect(parseAppearanceSettings({ lineSpacing: 1.4 }).lineSpacing).toBe(1.4)
  })

  describe("migration", () => {
    it("reads an unversioned object with legacy spellings", () => {
      expect(
        parseAppearanceSettings({ appearance: "Auto", theme: "CatppuccinMocha", textSize: "15", lineSpacing: "1.15" }),
      ).toEqual({ ...DEFAULT_APPEARANCE_SETTINGS, appearance: "system", theme: "pastel", textSize: 15, lineSpacing: 1.15 })
      expect(parseAppearanceSettings({ theme: "PeonyPink" }).theme).toBe("pastel")
      expect(parseAppearanceSettings({ theme: "Orchid" }).theme).toBe("pastel")
    })

    it("maps a removed or unknown theme to System, like ThemePreference", () => {
      expect(parseAppearanceSettings({ version: 1, theme: "removed-theme" }).theme).toBe("system")
    })

    it("reads a newer version field by field and writes the current version", () => {
      const parsed = parseAppearanceSettings({ version: 7, theme: "ash", accentOverride: "#ff0000", appearance: "light" })
      expect(parsed).toEqual({ ...DEFAULT_APPEARANCE_SETTINGS, theme: "ash", appearance: "light", version: 1 })
      expect(JSON.parse(serializeAppearanceSettings(parsed))).not.toHaveProperty("accentOverride")
    })

    it("returns a fresh object, never the frozen defaults with edits", () => {
      const parsed = parseAppearanceSettings({ theme: "pink" })
      expect(Object.isFrozen(DEFAULT_APPEARANCE_SETTINGS)).toBe(true)
      expect(parsed).not.toBe(DEFAULT_APPEARANCE_SETTINGS)
    })
  })
})

describe("text size steps", () => {
  it("follow ChatTypography.sizeSteps", () => {
    expect(nextLargerTextSize(13)).toBe(14)
    expect(nextLargerTextSize(18)).toBe(20)
    expect(nextLargerTextSize(28)).toBe(32)
    expect(nextLargerTextSize(32)).toBeUndefined()
    expect(nextSmallerTextSize(10)).toBeUndefined()
    expect(nextSmallerTextSize(20)).toBe(18)
    expect(nextSmallerTextSize(13.5)).toBe(13)
  })

  it("name the line spacing steps as the Mac settings do", () => {
    expect([1, 1.15, 1.3, 1.5, 1.8].map(lineSpacingTitle)).toEqual([
      "Standard",
      "Comfortable",
      "Relaxed",
      "Spacious",
      "1.8×",
    ])
  })
})
