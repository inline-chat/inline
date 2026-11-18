/**
 * How emoji are drawn: native glyphs in the platform's emoji font, never
 * images. The stack names each platform's color emoji font, so a glyph
 * resolves there before the text font's own (often monochrome) symbol:
 *
 * - "Apple Color Emoji": macOS and iOS.
 * - "Segoe UI Emoji", "Segoe UI Symbol": Windows (Symbol covers a few
 *   older symbols the Emoji face lacks).
 * - "Noto Color Emoji": Linux, ChromeOS and Android.
 * - "Twemoji Mozilla": the emoji font Firefox ships on Windows and Linux.
 * - "Android Emoji", "EmojiSymbols": older Android and Linux fallbacks.
 * - `emoji`: the CSS generic family (CSS Fonts 4), where supported.
 *
 * Presentation: characters such as ❤ and ☺ default to text style. The data
 * keeps the VS16 (U+FE0F) the Unicode data gives them (❤️), and emoji views
 * also set `font-variant-emoji: emoji` (Chromium 131, Firefox 108, Safari 17.4;
 * ignored elsewhere, where the VS16 alone decides). Sent reactions keep
 * exactly the string chosen; nothing here rewrites a message's text.
 */

export const EMOJI_FONT_STACK =
  '"Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji", "Twemoji Mozilla", "Android Emoji", "EmojiSymbols", emoji, sans-serif'
