import * as stylex from "@stylexjs/stylex"
import { font } from "./font.stylex"

/**
 * Message text, which the appearance settings change (apple/InlineMacUI
 * MacTheme/ChatTypography.swift): family, size and line height, and the
 * emoji-only sizes that scale with the text size. The defaults are the
 * system font at the body size and its natural line height; the appearance
 * controller overrides them on the root element (sizes as CSS variables, the
 * monospace family as a theme class). Views that render message text read
 * these, never `font` directly.
 */
export const chatText = stylex.defineVars({
  messageFontFamily: font.familySystem,
  messageFontSize: font.sizeBody,
  /** Natural line height times the line spacing multiple (1, 1.15, 1.3, 1.5; at most 2). */
  messageLineHeight: font.lineHeightTight,
  /** One emoji alone (64pt at 13pt text). */
  emojiLarge: "64px",
  /** Two or three emoji alone (42pt at 13pt text). */
  emojiMedium: "42px",
  /** More emoji alone (18pt at 13pt text). */
  emojiSmall: "18px",
})
