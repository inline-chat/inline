import { describe, expect, it, vi } from "vitest"
import {
  InlineAppearancePreferencesStore,
  defaultInlineAppearancePreferences,
  inlineAppearanceStorageKey,
  parseInlineAppearancePreferences,
} from "./InlineAppearancePreferences"

describe("InlineAppearancePreferences", () => {
  it("accepts only the bounded Mac-shaped appearance choices", () => {
    expect(
      parseInlineAppearancePreferences(
        JSON.stringify({
          appearance: "dark",
          messageStyle: "made-up",
          sidebarItemSize: "compact",
        }),
      ),
    ).toEqual({
      appearance: "dark",
      messageStyle: "bubble",
      sidebarItemSize: "compact",
    })
    expect(parseInlineAppearancePreferences("broken")).toEqual(
      defaultInlineAppearancePreferences,
    )
  })

  it("persists before publishing a new synchronous snapshot", () => {
    const values = new Map<string, string>()
    const storage = {
      getItem: (key: string) => values.get(key) ?? null,
      setItem: vi.fn((key: string, value: string) => values.set(key, value)),
    }
    const store = new InlineAppearancePreferencesStore(storage)
    const listener = vi.fn()
    store.subscribe(listener)

    store.update({ messageStyle: "minimal" })

    expect(storage.setItem).toHaveBeenCalledWith(
      inlineAppearanceStorageKey,
      expect.stringContaining('"messageStyle":"minimal"'),
    )
    expect(store.getSnapshot().messageStyle).toBe("minimal")
    expect(listener).toHaveBeenCalledOnce()
  })
})
