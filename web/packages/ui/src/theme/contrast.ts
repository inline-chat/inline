/**
 * Contrast of text on its background for every theme, by WCAG 2. Pure: the
 * lab renders the table and the tests hold the thresholds.
 */

import { THEME_IDS, type ThemeId, type Variant, VARIANTS } from "./catalog"
import { contrastRatio, toHex, WCAG_AA_BODY_TEXT, WCAG_AA_NON_TEXT } from "./color-math"
import { resolveTheme, type ResolvedVariant } from "./palette"

export type ContrastPair = {
  readonly id: string
  readonly title: string
  readonly foreground: keyof ResolvedVariant
  readonly background: keyof ResolvedVariant
  /** The WCAG AA minimum for what the pair is used for. */
  readonly minimum: number
}

/** Text and its surface, as the kit and the Mac app pair them. */
export const CONTRAST_PAIRS: readonly ContrastPair[] = [
  { id: "window-text", title: "Text on window", foreground: "label", background: "windowBackground", minimum: WCAG_AA_BODY_TEXT },
  { id: "sidebar-text", title: "Text on sidebar", foreground: "label", background: "sidebarBackground", minimum: WCAG_AA_BODY_TEXT },
  { id: "reply-pane-text", title: "Text on reply pane", foreground: "label", background: "replyPaneBackground", minimum: WCAG_AA_BODY_TEXT },
  { id: "own-bubble-text", title: "Own bubble text", foreground: "onAccent", background: "bubble", minimum: WCAG_AA_BODY_TEXT },
  { id: "others-bubble-text", title: "Others' bubble text", foreground: "secondaryBubbleText", background: "secondaryBubble", minimum: WCAG_AA_BODY_TEXT },
  { id: "others-bubble-link", title: "Link in others' bubble", foreground: "secondaryBubbleLink", background: "secondaryBubble", minimum: WCAG_AA_BODY_TEXT },
  { id: "accent-button-text", title: "Accent button text", foreground: "onAccent", background: "accent", minimum: WCAG_AA_BODY_TEXT },
  { id: "selected-row-text", title: "Selected row text", foreground: "selectedText", background: "selectedContentBackground", minimum: WCAG_AA_BODY_TEXT },
  { id: "secondary-text", title: "Secondary text on window", foreground: "secondaryLabel", background: "windowBackground", minimum: WCAG_AA_BODY_TEXT },
  { id: "accent-on-window", title: "Accent (icons, indicators) on window", foreground: "accent", background: "windowBackground", minimum: WCAG_AA_NON_TEXT },
]

export type ContrastRow = {
  readonly theme: ThemeId
  readonly variant: Variant
  readonly pair: ContrastPair
  readonly foreground: string
  readonly background: string
  /** Rounded to two decimals. */
  readonly ratio: number
  readonly passes: boolean
}

export function contrastRows(themes: readonly ThemeId[] = THEME_IDS): ContrastRow[] {
  const rows: ContrastRow[] = []
  for (const theme of themes) {
    const resolved = resolveTheme(theme)
    for (const variant of VARIANTS) {
      const colors = resolved[variant]
      for (const pair of CONTRAST_PAIRS) {
        const fg = colors[pair.foreground]
        const bg = colors[pair.background]
        const ratio = Math.floor(contrastRatio(fg, bg) * 100) / 100
        rows.push({
          theme,
          variant,
          pair,
          foreground: toHex(fg),
          background: toHex(bg),
          ratio,
          passes: ratio >= pair.minimum,
        })
      }
    }
  }
  return rows
}
