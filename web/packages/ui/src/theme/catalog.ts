/**
 * The Mac app's theme catalog, as data. Every value here is copied from the
 * Swift sources named next to it; nothing is invented. `palette.ts` derives
 * the web token values from these with the Mac app's own formulas.
 *
 * Sources:
 * - apple/InlineUI/Sources/InlineTheme/ThemeCatalog.swift (`AppThemePreset`, `ThemeCatalog.palette`, `secondaryBubble`)
 * - apple/InlineMacUI/Sources/MacTheme/Theme.swift (window surface, sidebar overlay, reply pane, bubble link)
 */

export const THEME_IDS = ["system", "pink", "sunset", "midnight", "ash", "flexoki", "pastel", "neon-noir"] as const

export type ThemeId = (typeof THEME_IDS)[number]

export type Variant = "light" | "dark"

export const VARIANTS: readonly Variant[] = ["light", "dark"]

/** `AppThemePreset.title`. */
export const THEME_TITLES: Record<ThemeId, string> = {
  system: "System",
  pink: "Pink",
  sunset: "Sunset",
  midnight: "Midnight",
  ash: "Ash",
  flexoki: "Flexoki",
  pastel: "Pastel",
  "neon-noir": "Neon Noir",
}

/**
 * `ThemeCatalog.palette(preset:variant:systemCanvas:)`: the primary (accent,
 * prominent and outgoing bubble) and the canvas seed. System's canvas is the
 * platform window background, so it has none here.
 */
export const THEME_SEEDS: Record<ThemeId, Record<Variant, { primary: string; canvas: string | null }>> = {
  system: { light: { primary: "#00A7F8", canvas: null }, dark: { primary: "#0A84FF", canvas: null } },
  pink: { light: { primary: "#FD4F7E", canvas: "#FFF5F7" }, dark: { primary: "#FD4F7E", canvas: "#241116" } },
  sunset: { light: { primary: "#C94D24", canvas: "#FFF5F0" }, dark: { primary: "#C94D24", canvas: "#2A1A15" } },
  midnight: { light: { primary: "#0969DA", canvas: "#FFFFFF" }, dark: { primary: "#0969DA", canvas: "#0D1117" } },
  ash: { light: { primary: "#44494D", canvas: "#FFFFFF" }, dark: { primary: "#44494D", canvas: "#151516" } },
  flexoki: { light: { primary: "#205EA6", canvas: "#FFFCF0" }, dark: { primary: "#205EA6", canvas: "#100F0F" } },
  pastel: { light: { primary: "#7D57C1", canvas: "#E2DAF1" }, dark: { primary: "#7D57C1", canvas: "#292D3E" } },
  "neon-noir": { light: { primary: "#623BE2", canvas: "#F7F7F7" }, dark: { primary: "#623BE2", canvas: "#080808" } },
}

/** `ThemeCatalog.secondaryBubble`: #ECECEC for System light, else #EAEAEA light and #2E2E2E dark. */
export const secondaryBubbleSeed = (theme: ThemeId, variant: Variant): string =>
  theme === "system" && variant === "light" ? "#ECECEC" : variant === "light" ? "#EAEAEA" : "#2E2E2E"

/** `Theme.resolvedWindowSurfaceColor`: the native window color blended toward the canvas by this fraction. */
export const WINDOW_CANVAS_FRACTION: Record<Variant, number> = { light: 0.056, dark: 0.084 }

/** `Theme.resolvedSidebarOverlayColor`: the accent at this alpha over the sidebar (glass and tint on, the default). */
export const SIDEBAR_TINT_ALPHA: Record<Variant, number> = { light: 0.02625, dark: 0.042 }

/** `Theme.replyThreadPaneBackgroundColor`: the window surface blended 2.5% toward black (light) or white (dark). */
export const REPLY_PANE_TINT_FRACTION = 0.025

/** `Theme.resolvedSecondaryBubbleLinkColor`: light caps brightness; dark keeps 48% saturation and lifts brightness. */
export const BUBBLE_LINK = { lightMaxBrightness: 0.88, darkSaturation: 0.48, darkMinBrightness: 0.9, darkLift: 0.15 }

/**
 * `AppThemePreset(migratingLegacyIOSIdentifier:)`: older iOS theme names map
 * to Pastel, anything else unknown to System.
 */
export const LEGACY_THEME_IDS: Record<string, ThemeId> = {
  CatppuccinMocha: "pastel",
  PeonyPink: "pastel",
  Orchid: "pastel",
}

export const isThemeId = (value: unknown): value is ThemeId =>
  typeof value === "string" && (THEME_IDS as readonly string[]).includes(value)
