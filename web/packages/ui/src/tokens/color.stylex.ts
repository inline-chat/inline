import * as stylex from "@stylexjs/stylex"

/**
 * Colors, light and dark through `light-dark()`, which follows the used
 * `color-scheme` (the document's, or an element's for a forced theme).
 *
 * Names follow the macOS semantic colors the Mac app draws with (labelColor,
 * separatorColor, selectedContentBackgroundColor, ...) and the Mac app's own
 * Theme (accent, iconGray, titleTextGray, composeOutline, bubbles). Values are
 * the AppKit system values and the "System" preset of apple/InlineUI
 * ThemeCatalog. Themes override a subset with `stylex.createTheme`
 * (src/theme/themes.ts).
 *
 * Platform accents: under `forced-colors: active` the link, focus ring and
 * selection pairs become system colors (the browser keeps author system
 * colors, so selection stays visible); everything else is left to the
 * browser's forcing. Under `prefers-reduced-transparency: reduce` the
 * translucent menu, popover and tooltip surfaces become opaque.
 */
export const color = stylex.defineVars({
  // Text
  label: "light-dark(rgb(0 0 0 / 0.85), rgb(255 255 255 / 0.85))",
  secondaryLabel: {
    default: "light-dark(rgb(0 0 0 / 0.5), rgb(255 255 255 / 0.55))",
    "@media (prefers-contrast: more)": "light-dark(rgb(0 0 0 / 0.7), rgb(255 255 255 / 0.75))",
  },
  tertiaryLabel: "light-dark(rgb(0 0 0 / 0.26), rgb(255 255 255 / 0.25))",
  quaternaryLabel: "light-dark(rgb(0 0 0 / 0.1), rgb(255 255 255 / 0.1))",
  placeholderText: "light-dark(rgb(0 0 0 / 0.25), rgb(255 255 255 / 0.25))",
  disabledText: "light-dark(rgb(0 0 0 / 0.25), rgb(255 255 255 / 0.25))",
  link: { default: "light-dark(#0068da, #419cff)", "@media (forced-colors: active)": "LinkText" },
  titleTextGray: "light-dark(#9e9e9e, #a0a0a0)",
  iconGray: "light-dark(#bcbcbc, #929292)",

  // Surfaces
  windowBackground: "light-dark(#ffffff, #1e1e1e)",
  sidebarBackground: "light-dark(#f4f4f5, #232326)",
  textBackground: "light-dark(#ffffff, rgb(255 255 255 / 0.05))",
  menuBackground: {
    default: "light-dark(rgb(246 246 246 / 0.92), rgb(40 40 42 / 0.92))",
    "@media (prefers-reduced-transparency: reduce)": "light-dark(rgb(246 246 246), rgb(40 40 42))",
  },
  popoverBackground: {
    default: "light-dark(rgb(252 252 252 / 0.97), rgb(48 48 50 / 0.97))",
    "@media (prefers-reduced-transparency: reduce)": "light-dark(rgb(252 252 252), rgb(48 48 50))",
  },
  tooltipBackground: {
    default: "light-dark(rgb(250 250 250 / 0.98), rgb(58 58 60 / 0.98))",
    "@media (prefers-reduced-transparency: reduce)": "light-dark(rgb(250 250 250), rgb(58 58 60))",
  },
  dialogBackground: "light-dark(#f6f6f6, #2c2c2e)",
  backdrop: "light-dark(rgb(0 0 0 / 0.18), rgb(0 0 0 / 0.45))",

  // Lines
  separator: {
    default: "light-dark(rgb(0 0 0 / 0.1), rgb(255 255 255 / 0.1))",
    "@media (prefers-contrast: more)": "light-dark(rgb(0 0 0 / 0.35), rgb(255 255 255 / 0.4))",
  },
  layerBorder: {
    default: "light-dark(rgb(0 0 0 / 0.12), rgb(255 255 255 / 0.12))",
    "@media (prefers-contrast: more)": "light-dark(rgb(0 0 0 / 0.5), rgb(255 255 255 / 0.5))",
  },
  controlBorder: {
    default: "light-dark(rgb(0 0 0 / 0.14), rgb(255 255 255 / 0.12))",
    "@media (prefers-contrast: more)": "light-dark(rgb(0 0 0 / 0.5), rgb(255 255 255 / 0.5))",
  },
  composeOutline: "light-dark(rgb(0 0 0 / 0.09), rgb(255 255 255 / 0.1))",

  // Controls
  control: "light-dark(#ffffff, rgb(255 255 255 / 0.18))",
  controlText: "light-dark(rgb(0 0 0 / 0.85), rgb(255 255 255 / 0.85))",
  controlHover: "light-dark(rgb(0 0 0 / 0.05), rgb(255 255 255 / 0.08))",
  controlPressed: "light-dark(rgb(0 0 0 / 0.1), rgb(255 255 255 / 0.14))",
  controlTrack: "light-dark(rgb(0 0 0 / 0.09), rgb(255 255 255 / 0.14))",

  // Accent ("System" preset: primary 0x00A7F8 light, 0x0A84FF dark)
  accent: "light-dark(#00a7f8, #0a84ff)",
  accentHover: "light-dark(#009be6, #2190ff)",
  accentPressed: "light-dark(#008dd2, #3a9cff)",
  onAccent: "#ffffff",
  prominent: "light-dark(#00a7f8, #0a84ff)",
  focusRing: { default: "light-dark(rgb(0 167 248 / 0.55), rgb(10 132 255 / 0.7))", "@media (forced-colors: active)": "Highlight" },

  // Selection (forced colors: the system highlight pair, which the browser keeps)
  selectedContentBackground: { default: "light-dark(#0064e1, #0058d0)", "@media (forced-colors: active)": "Highlight" },
  unemphasizedSelectedContentBackground: "light-dark(#dcdcdc, #464646)",
  selectedText: { default: "#ffffff", "@media (forced-colors: active)": "HighlightText" },
  selectedMenuItem: { default: "light-dark(#0a82ff, #0a6ce6)", "@media (forced-colors: active)": "Highlight" },
  selectedMenuItemText: { default: "#ffffff", "@media (forced-colors: active)": "HighlightText" },

  // System colors
  red: "light-dark(#ff3b30, #ff453a)",
  orange: "light-dark(#ff9500, #ff9f0a)",
  yellow: "light-dark(#ffcc00, #ffd60a)",
  green: "light-dark(#28cd41, #32d74b)",
  blue: "light-dark(#007aff, #0a84ff)",
  purple: "light-dark(#af52de, #bf5af2)",
  pink: "light-dark(#ff2d55, #ff375f)",
  gray: "light-dark(#8e8e93, #98989d)",
  destructive: "light-dark(#ff3b30, #ff453a)",

  // Chat bubbles (Theme.messageBubble*)
  bubble: "light-dark(#00a7f8, #0a84ff)",
  secondaryBubble: "light-dark(#ececec, #2e2e2e)",
  secondaryBubbleText: "light-dark(rgb(0 0 0 / 0.85), #ffffff)",
})
