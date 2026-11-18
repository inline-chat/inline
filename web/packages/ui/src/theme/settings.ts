/**
 * Appearance settings: one plain, versioned object. `parseAppearanceSettings`
 * accepts anything (a stored string, a synced object, garbage) and returns a
 * valid value, keeping every field it can read. Choices and defaults follow
 * the Mac app (apple/InlineMac/Views/Settings/AppSettings.swift,
 * apple/InlineMacUI/Sources/MacTheme/ChatTypography.swift).
 */

import { isThemeId, LEGACY_THEME_IDS, type ThemeId } from "./catalog"

export const APPEARANCE_SETTINGS_VERSION = 1

/** `AppAppearance`: Auto (follow the system), Light, Dark. */
export type Appearance = "system" | "light" | "dark"
export const APPEARANCES: readonly Appearance[] = ["light", "dark", "system"]

/** `SidebarItemSize`. Compact is the default for a new install. */
export type SidebarItemSize = "compact" | "standard"
export const SIDEBAR_ITEM_SIZES: readonly SidebarItemSize[] = ["compact", "standard"]

/** `MessageRenderStyle`. */
export type MessageStyle = "bubble" | "minimal"
export const MESSAGE_STYLES: readonly MessageStyle[] = ["bubble", "minimal"]

/** `UnreadBadgeStyle`. */
export type UnreadBadgeStyle = "dot" | "numbered"
export const UNREAD_BADGE_STYLES: readonly UnreadBadgeStyle[] = ["dot", "numbered"]

/**
 * Message font. The Mac app offers any installed family; the web offers the
 * system UI font and the system monospace font only, so it never loads a web
 * font (the content policy allows only same-origin fonts, and a font file
 * would sit on the first-paint path).
 */
export type MessageFont = "system" | "monospace"
export const MESSAGE_FONTS: readonly MessageFont[] = ["system", "monospace"]

/** `ChatTypography.sizeSteps`: 1pt steps around body sizes, 2pt above 18. Default is the system size, 13. */
export const TEXT_SIZE_STEPS: readonly number[] = [10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 26, 28, 32]
export const DEFAULT_TEXT_SIZE = 13
export const MIN_TEXT_SIZE = 10
export const MAX_TEXT_SIZE = 32

/** `ChatTypography.lineHeightSteps`, titled as in MessageTextSettingsSection. Maximum 2. */
export const LINE_SPACING_STEPS: readonly number[] = [1, 1.15, 1.3, 1.5]
export const MAX_LINE_SPACING = 2
export const LINE_SPACING_TITLES: Record<string, string> = {
  "1": "Standard",
  "1.15": "Comfortable",
  "1.3": "Relaxed",
  "1.5": "Spacious",
}

export type AppearanceSettings = {
  readonly version: typeof APPEARANCE_SETTINGS_VERSION
  readonly appearance: Appearance
  readonly theme: ThemeId
  /** Message text size in CSS pixels (the Mac app's points). */
  readonly textSize: number
  /** Line height multiple for message text; 1 is the font's natural line height. */
  readonly lineSpacing: number
  readonly messageFont: MessageFont
  readonly sidebarItemSize: SidebarItemSize
  readonly messageStyle: MessageStyle
  readonly unreadBadgeStyle: UnreadBadgeStyle
  readonly compactToolbar: boolean
  readonly centeredChats: boolean
}

/** The Mac app's defaults for a new install. */
export const DEFAULT_APPEARANCE_SETTINGS: AppearanceSettings = Object.freeze({
  version: APPEARANCE_SETTINGS_VERSION,
  appearance: "system",
  theme: "system",
  textSize: DEFAULT_TEXT_SIZE,
  lineSpacing: 1,
  messageFont: "system",
  sidebarItemSize: "compact",
  messageStyle: "bubble",
  unreadBadgeStyle: "dot",
  compactToolbar: false,
  centeredChats: true,
})

const oneOf =
  <T extends string>(options: readonly T[]) =>
  (value: unknown): T | undefined =>
    typeof value === "string" && (options as readonly string[]).includes(value) ? (value as T) : undefined

const numberFrom = (value: unknown): number | undefined => {
  const n = typeof value === "string" && value.trim() !== "" ? Number(value) : value
  return typeof n === "number" && Number.isFinite(n) ? n : undefined
}

const booleanFrom = (value: unknown): boolean | undefined => (typeof value === "boolean" ? value : undefined)

/** Like `ChatTypography.resolvedPointSize` plus the setter's clamp: any positive number, clamped to 10...32. */
export const clampTextSize = (size: number): number =>
  Math.round(Math.min(MAX_TEXT_SIZE, Math.max(MIN_TEXT_SIZE, size)) * 100) / 100

/** Like `ChatTypography.resolvedLineHeightMultiple`: at most 2, and 1 for anything not above 1. */
export const clampLineSpacing = (multiple: number): number =>
  multiple <= 1 ? 1 : Math.round(Math.min(MAX_LINE_SPACING, multiple) * 100) / 100

const appearanceFrom = (value: unknown): Appearance | undefined => {
  const direct = oneOf<Appearance>(["system", "light", "dark"])(value)
  if (direct) return direct
  // The Mac picker titles System "Auto".
  return typeof value === "string" && value.toLowerCase() === "auto" ? "system" : undefined
}

const themeFrom = (value: unknown): ThemeId | undefined => {
  if (isThemeId(value)) return value
  if (typeof value !== "string") return undefined
  // Unknown and removed themes fall back to System, like `ThemePreference.selectedPreset`.
  return LEGACY_THEME_IDS[value] ?? "system"
}

const textSizeFrom = (value: unknown): number | undefined => {
  const n = numberFrom(value)
  return n !== undefined && n > 0 ? clampTextSize(n) : undefined
}

const lineSpacingFrom = (value: unknown): number | undefined => {
  const n = numberFrom(value)
  return n === undefined ? undefined : clampLineSpacing(n)
}

const asRecord = (input: unknown): Record<string, unknown> | undefined => {
  let value = input
  if (typeof value === "string") {
    try {
      value = JSON.parse(value)
    } catch {
      return undefined
    }
  }
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined
}

/**
 * Reads appearance settings from anything: a JSON string, an object, or
 * nothing. Unknown or invalid fields take their defaults; known fields are
 * kept even when others are broken.
 *
 * Migrations: an object without `version` (or version 0) is read with the
 * current field names and legacy spellings: the Mac's `"auto"` appearance,
 * its legacy iOS theme names, sizes stored as strings. A newer version is
 * read field by field (forward compatible): what this build understands is
 * kept, the rest is dropped on the next write.
 */
export function parseAppearanceSettings(input: unknown): AppearanceSettings {
  const record = asRecord(input)
  if (!record) return DEFAULT_APPEARANCE_SETTINGS
  const d = DEFAULT_APPEARANCE_SETTINGS
  return {
    version: APPEARANCE_SETTINGS_VERSION,
    appearance: appearanceFrom(record.appearance) ?? d.appearance,
    theme: themeFrom(record.theme) ?? d.theme,
    textSize: textSizeFrom(record.textSize) ?? d.textSize,
    lineSpacing: lineSpacingFrom(record.lineSpacing) ?? d.lineSpacing,
    messageFont: oneOf(MESSAGE_FONTS)(record.messageFont) ?? d.messageFont,
    sidebarItemSize: oneOf(SIDEBAR_ITEM_SIZES)(record.sidebarItemSize) ?? d.sidebarItemSize,
    messageStyle: oneOf(MESSAGE_STYLES)(record.messageStyle) ?? d.messageStyle,
    unreadBadgeStyle: oneOf(UNREAD_BADGE_STYLES)(record.unreadBadgeStyle) ?? d.unreadBadgeStyle,
    compactToolbar: booleanFrom(record.compactToolbar) ?? d.compactToolbar,
    centeredChats: booleanFrom(record.centeredChats) ?? d.centeredChats,
  }
}

export const serializeAppearanceSettings = (settings: AppearanceSettings): string => JSON.stringify(settings)

export const sameAppearanceSettings = (a: AppearanceSettings, b: AppearanceSettings): boolean =>
  (Object.keys(a) as Array<keyof AppearanceSettings>).every((key) => Object.is(a[key], b[key]))

/** `ChatTypography.nextLargerSize(than:)`: the next step above, or undefined at the maximum. */
export const nextLargerTextSize = (size: number): number | undefined => TEXT_SIZE_STEPS.find((s) => s > size + 0.01)

/** `ChatTypography.nextSmallerSize(than:)`: the next step below, or undefined at the minimum. */
export const nextSmallerTextSize = (size: number): number | undefined =>
  [...TEXT_SIZE_STEPS].reverse().find((s) => s < size - 0.01)

/** Settings title for a line spacing multiple, as in the Mac app: a name for the steps, "1.4×" otherwise. */
export const lineSpacingTitle = (multiple: number): string => LINE_SPACING_TITLES[String(multiple)] ?? `${multiple}×`
