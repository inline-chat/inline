/**
 * Token values for every theme, derived from the Mac catalog (`catalog.ts`)
 * with the Mac app's formulas. Pure: `generate.ts` turns this into the
 * StyleX themes in `themes.ts` and `../tokens/theme-color.stylex.ts`, and the
 * tests check the checked-in files match it.
 */

import {
  BUBBLE_LINK,
  REPLY_PANE_TINT_FRACTION,
  secondaryBubbleSeed,
  SIDEBAR_TINT_ALPHA,
  THEME_IDS,
  THEME_SEEDS,
  type ThemeId,
  type Variant,
  VARIANTS,
  WINDOW_CANVAS_FRACTION,
} from "./catalog"
import {
  blend,
  composite,
  fromHsb,
  parseColor,
  quantize,
  type Rgba,
  scale,
  splitLightDark,
  toHex,
  toHsb,
  toRgbString,
  withAlpha,
} from "./color-math"

/**
 * The `color` token values (`../tokens/color.stylex.ts`) that theming reads.
 * A mirror, because the StyleX file cannot run outside the compiler; a test
 * reads the token file and fails if the two disagree.
 */
export const BASE_COLORS = {
  label: "light-dark(rgb(0 0 0 / 0.85), rgb(255 255 255 / 0.85))",
  secondaryLabel: "light-dark(rgb(0 0 0 / 0.5), rgb(255 255 255 / 0.55))",
  windowBackground: "light-dark(#ffffff, #1e1e1e)",
  sidebarBackground: "light-dark(#f4f4f5, #232326)",
  accent: "light-dark(#00a7f8, #0a84ff)",
  accentHover: "light-dark(#009be6, #2190ff)",
  accentPressed: "light-dark(#008dd2, #3a9cff)",
  onAccent: "#ffffff",
  prominent: "light-dark(#00a7f8, #0a84ff)",
  focusRing: "light-dark(rgb(0 167 248 / 0.55), rgb(10 132 255 / 0.7))",
  selectedContentBackground: "light-dark(#0064e1, #0058d0)",
  selectedText: "#ffffff",
  bubble: "light-dark(#00a7f8, #0a84ff)",
  secondaryBubble: "light-dark(#ececec, #2e2e2e)",
  secondaryBubbleText: "light-dark(rgb(0 0 0 / 0.85), #ffffff)",
} as const

export type BaseColorToken = keyof typeof BASE_COLORS

/**
 * `color` tokens a theme sets. Every theme class defines all of these, the
 * System theme included. Every other `color` token is shared by all themes
 * (listed in `SHARED_COLOR_TOKENS`); the two lists partition the group, which
 * a test checks against the token file.
 */
export const THEMED_COLOR_TOKENS = [
  "accent",
  "accentHover",
  "accentPressed",
  "prominent",
  "focusRing",
  "bubble",
  "windowBackground",
  "sidebarBackground",
  "secondaryBubble",
] as const satisfies readonly BaseColorToken[]

export type ThemedColorToken = (typeof THEMED_COLOR_TOKENS)[number]

/** `color` tokens no theme changes: AppKit system values that the Mac app does not theme either. */
export const SHARED_COLOR_TOKENS = [
  "label",
  "secondaryLabel",
  "tertiaryLabel",
  "quaternaryLabel",
  "placeholderText",
  "disabledText",
  "link",
  "titleTextGray",
  "iconGray",
  "textBackground",
  "menuBackground",
  "popoverBackground",
  "tooltipBackground",
  "dialogBackground",
  "backdrop",
  "separator",
  "layerBorder",
  "controlBorder",
  "composeOutline",
  "control",
  "controlText",
  "controlHover",
  "controlPressed",
  "controlTrack",
  "onAccent",
  "selectedContentBackground",
  "unemphasizedSelectedContentBackground",
  "selectedText",
  "selectedMenuItem",
  "selectedMenuItemText",
  "red",
  "orange",
  "yellow",
  "green",
  "blue",
  "purple",
  "pink",
  "gray",
  "destructive",
  "secondaryBubbleText",
] as const

/** The `themeColor` group (`../tokens/theme-color.stylex.ts`): theme-only colors the kit had no token for. */
export const THEME_COLOR_TOKENS = ["secondaryBubbleLink", "replyPaneBackground"] as const

export type ThemeColorToken = (typeof THEME_COLOR_TOKENS)[number]

/**
 * System colors that stand in under `forced-colors: active`. Only tokens
 * that always pair with each other are mapped (a selection background with
 * its text, a link on any surface), so a mapped foreground never lands on an
 * unmapped background. Everything else is left to the browser, which forces
 * it to Canvas and CanvasText. Mirrored in `color.stylex.ts` for the `color`
 * group; the generated themes carry it for the `themeColor` group.
 */
export const FORCED_COLORS = {
  link: "LinkText",
  focusRing: "Highlight",
  selectedContentBackground: "Highlight",
  selectedText: "HighlightText",
  selectedMenuItem: "Highlight",
  selectedMenuItemText: "HighlightText",
  secondaryBubbleLink: "LinkText",
} as const

export type ResolvedVariant = Record<BaseColorToken | ThemeColorToken, Rgba>

export type ResolvedTheme = Record<Variant, ResolvedVariant>

const WHITE = parseColor("#ffffff")
const BLACK = parseColor("#000000")

const baseColor = (token: BaseColorToken, variant: Variant): Rgba =>
  parseColor(splitLightDark(BASE_COLORS[token])[variant])

/**
 * Hover and pressed accents. The Mac app has none (AppKit draws pressed
 * states); this is the rule the kit's System values follow, applied to each
 * theme's primary: 0.928 and 0.846 of the color in light, 9.5% and 19.5%
 * toward white in dark. A test checks it reproduces the System values exactly.
 */
export const accentStates = (primary: Rgba, variant: Variant): { hover: Rgba; pressed: Rgba } =>
  variant === "light"
    ? { hover: scale(primary, 0.928), pressed: scale(primary, 0.846) }
    : { hover: blend(primary, WHITE, 0.095), pressed: blend(primary, WHITE, 0.195) }

/** The kit's focus ring is the primary at 55% (light) and 70% (dark), as its System value is. */
export const FOCUS_RING_ALPHA: Record<Variant, number> = { light: 0.55, dark: 0.7 }

/** `Theme.resolvedSecondaryBubbleLinkColor`. */
export const secondaryBubbleLink = (primary: Rgba, variant: Variant): Rgba => {
  const hsb = toHsb(primary)
  if (variant === "light") return fromHsb({ ...hsb, b: Math.min(hsb.b, BUBBLE_LINK.lightMaxBrightness) })
  return fromHsb({
    h: hsb.h,
    s: hsb.s * BUBBLE_LINK.darkSaturation,
    b: Math.max(BUBBLE_LINK.darkMinBrightness, Math.min(1, hsb.b + BUBBLE_LINK.darkLift)),
  })
}

/** Every color theming reads, for one theme in one variant, as 8-bit sRGB. */
export function resolveVariant(theme: ThemeId, variant: Variant): ResolvedVariant {
  const seeds = THEME_SEEDS[theme][variant]
  const primary = parseColor(seeds.primary)
  const system = theme === "system"
  const base = Object.fromEntries(
    (Object.keys(BASE_COLORS) as BaseColorToken[]).map((token) => [token, baseColor(token, variant)]),
  ) as Record<BaseColorToken, Rgba>

  const nativeWindow = base.windowBackground
  const windowBackground =
    system || seeds.canvas === null
      ? nativeWindow
      : quantize(blend(nativeWindow, parseColor(seeds.canvas), WINDOW_CANVAS_FRACTION[variant]))
  const sidebarBackground = system
    ? base.sidebarBackground
    : quantize(composite(withAlpha(primary, SIDEBAR_TINT_ALPHA[variant]), base.sidebarBackground))
  const replyPaneBackground = system
    ? windowBackground
    : quantize(blend(windowBackground, variant === "dark" ? WHITE : BLACK, REPLY_PANE_TINT_FRACTION))
  const states = accentStates(primary, variant)

  return {
    ...base,
    accent: primary,
    prominent: primary,
    bubble: primary,
    accentHover: quantize(states.hover),
    accentPressed: quantize(states.pressed),
    focusRing: withAlpha(primary, FOCUS_RING_ALPHA[variant]),
    windowBackground,
    sidebarBackground,
    secondaryBubble: parseColor(secondaryBubbleSeed(theme, variant)),
    secondaryBubbleLink: quantize(secondaryBubbleLink(primary, variant)),
    replyPaneBackground,
  }
}

export function resolveTheme(theme: ThemeId): ResolvedTheme {
  return { light: resolveVariant(theme, "light"), dark: resolveVariant(theme, "dark") }
}

const cssColor = (color: Rgba) => (color.a < 1 ? toRgbString(color) : toHex(color))

/** A `light-dark()` value, or a single color when both sides are equal. */
export const lightDark = (light: Rgba, dark: Rgba): string => {
  const l = cssColor(light)
  const d = cssColor(dark)
  return l === d ? l : `light-dark(${l}, ${d})`
}

export type TokenValue = string | { default: string; [condition: `@media ${string}`]: string }

const withForced = (token: string, value: string): TokenValue => {
  const forced = (FORCED_COLORS as Record<string, string>)[token]
  return forced === undefined ? value : { default: value, "@media (forced-colors: active)": forced }
}

/** The values a theme's StyleX classes set, per token group. */
export function themeValues(theme: ThemeId): {
  color: Record<ThemedColorToken, TokenValue>
  themeColor: Record<ThemeColorToken, TokenValue>
} {
  const { light, dark } = resolveTheme(theme)
  const value = (token: ThemedColorToken | ThemeColorToken) => withForced(token, lightDark(light[token], dark[token]))
  return {
    color: Object.fromEntries(THEMED_COLOR_TOKENS.map((t) => [t, value(t)])) as Record<ThemedColorToken, TokenValue>,
    themeColor: Object.fromEntries(THEME_COLOR_TOKENS.map((t) => [t, value(t)])) as Record<ThemeColorToken, TokenValue>,
  }
}

/** The opaque window color the pre-paint boot script paints, per variant. */
export function canvasColors(theme: ThemeId): Record<Variant, string> {
  const resolved = resolveTheme(theme)
  return { light: toHex(resolved.light.windowBackground), dark: toHex(resolved.dark.windowBackground) }
}

export { THEME_IDS, VARIANTS }
