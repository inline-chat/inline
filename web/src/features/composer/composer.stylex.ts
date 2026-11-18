import * as stylex from "@stylexjs/stylex"

/**
 * Composer metrics from the Mac app's glass composer
 * (`apple/InlineMac/Views/Compose/ComposeControlMode.swift`, `GlassComposeAppKit.swift`):
 * a 34 pt text row with a pill radius of half that, a 28 pt send button,
 * and a text area that grows to 300 pt and then scrolls.
 */
export const composerSize = stylex.defineVars({
  minHeight: "34px",
  maxHeight: "300px",
  lineHeight: "20px",
  /** (minHeight - lineHeight) / 2 */
  textPaddingBlock: "7px",
  textPaddingInline: "12px",
  pillRadius: "17px",
  sendButton: "28px",
  /** (minHeight - sendButton) / 2 */
  sendInset: "3px",
  suggestionRow: "32px",
  /** Five rows and the list's padding. */
  suggestionsMaxHeight: "170px",
  suggestionsWidth: "320px",
})
