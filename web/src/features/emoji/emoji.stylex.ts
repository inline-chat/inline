import * as stylex from "@stylexjs/stylex"

/**
 * Emoji metrics, from the Mac picker (`EmojiPickerPopover2.swift`
 * `EmojiPicker2Layout`) and reaction overlay (`ReactionOverlayView.swift`).
 * The font stack is documented in `font.ts` (kept as one literal here
 * because StyleX token values must be static).
 */
export const emojiTokens = stylex.defineVars({
  fontFamily: '"Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji", "Twemoji Mozilla", "Android Emoji", "EmojiSymbols", emoji, sans-serif',
  pickerWidth: "320px",
  gridHeight: "292px",
  searchBar: "44px",
  categoryBar: "36px",
  categoryButton: "26px",
  previewBar: "30px",
  cell: "34px",
  cellRadius: "8px",
  cellFont: "25px",
  headerHeight: "28px",
  quickButton: "32px",
  quickFont: "22px",
  quickRowWidth: "280px",
  previewFont: "22px",
  toneSwatch: "24px",
})
