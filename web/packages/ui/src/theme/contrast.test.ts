import { describe, expect, it } from "vitest"
import { THEME_IDS } from "./catalog"
import { CONTRAST_PAIRS, contrastRows } from "./contrast"

/**
 * Pairs that fail WCAG AA with the Mac app's own values, kept as they are
 * (the Mac app ships them) and reported in src/theme/README.md. The ratio is
 * pinned, so a change to a value shows up here. A new failure, or a listed
 * one that starts passing, fails the test.
 */
const KNOWN_FAILURES: Record<string, number> = {
  // White on the outgoing bubble and accent buttons: the catalog's primary is too light for white text.
  "system light own-bubble-text": 2.66,
  "system light accent-button-text": 2.66,
  "system dark own-bubble-text": 3.64,
  "system dark accent-button-text": 3.64,
  "pink light own-bubble-text": 3.18,
  "pink light accent-button-text": 3.18,
  "pink dark own-bubble-text": 3.18,
  "pink dark accent-button-text": 3.18,
  // Link in others' bubbles (resolvedSecondaryBubbleLinkColor) on #ECECEC / #EAEAEA.
  "system light others-bubble-link": 2.73,
  "pink light others-bubble-link": 3.3,
  "sunset light others-bubble-link": 3.81,
  "midnight light others-bubble-link": 4.31,
  "pastel light others-bubble-link": 4.35,
  // AppKit's secondaryLabelColor (black at 50%) in light; it passes under Increase Contrast (70%).
  "system light secondary-text": 3.97,
  "pink light secondary-text": 3.97,
  "sunset light secondary-text": 3.97,
  "midnight light secondary-text": 3.97,
  "ash light secondary-text": 3.97,
  "flexoki light secondary-text": 3.97,
  "pastel light secondary-text": 3.96,
  "neon-noir light secondary-text": 3.97,
  // The accent as an icon or indicator (3:1): System cyan on white, and dark primaries on dark windows.
  "system light accent-on-window": 2.66,
  "ash dark accent-on-window": 1.85,
  "flexoki dark accent-on-window": 2.57,
  "neon-noir dark accent-on-window": 2.63,
}

const key = (row: { theme: string; variant: string; pair: { id: string } }) => `${row.theme} ${row.variant} ${row.pair.id}`

describe("contrast", () => {
  const rows = contrastRows()

  it("covers every pair for every theme in light and dark", () => {
    expect(rows).toHaveLength(THEME_IDS.length * 2 * CONTRAST_PAIRS.length)
  })

  for (const theme of THEME_IDS) {
    it(`${theme}: text meets WCAG AA on its background, except the listed Mac values`, () => {
      const failures = Object.fromEntries(
        rows.filter((row) => row.theme === theme && !row.passes).map((row) => [key(row), row.ratio]),
      )
      const expected = Object.fromEntries(Object.entries(KNOWN_FAILURES).filter(([k]) => k.startsWith(`${theme} `)))
      expect(failures).toEqual(expected)
    })
  }

  it("body text on every surface passes in every theme", () => {
    for (const row of rows) {
      if (["window-text", "sidebar-text", "reply-pane-text", "others-bubble-text", "selected-row-text"].includes(row.pair.id)) {
        expect(row.passes, key(row)).toBe(true)
      }
    }
  })
})
