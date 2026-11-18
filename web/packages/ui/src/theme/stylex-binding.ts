/**
 * The StyleX side of theming: the classes and variable names the appearance
 * controller writes onto a root element. Needs the StyleX compiler (it runs
 * `stylex.create` and reads compiled variable references), so it is exported
 * from `@inline/ui/theme/stylex`, never from the framework-free entries.
 */

import * as stylex from "@stylexjs/stylex"
import { chatText } from "../tokens/chat-text.stylex"
import { color } from "../tokens/color.stylex"
import { density } from "../tokens/density.stylex"
import { font } from "../tokens/font.stylex"
import type { ThemeId } from "./catalog"
import { type AppearanceBinding, AppearanceController, type AppearanceControllerOptions } from "./controller"
import type { Appearance } from "./settings"
import { APPEARANCE_STORAGE_KEY, localAppearanceStorage } from "./storage"
import * as themes from "./themes"

const schemes = stylex.create({
  light: { colorScheme: "light" },
  dark: { colorScheme: "dark" },
  system: { colorScheme: "light dark" },
  root: { backgroundColor: color.windowBackground, color: color.label },
})

const standardDensity = stylex.createTheme(density, {
  sidebarRowHeight: "40px",
  sidebarFolderRowHeight: "32px",
  sidebarRowIconSize: "30px",
})

const monospaceText = stylex.createTheme(chatText, { messageFontFamily: font.familyMono })

const className = (props: { className?: string }) => props.className ?? ""

/** StyleX theme classes per theme: the `color` group and the `themeColor` group together. */
export const themeClasses: Record<ThemeId, string> = {
  system: className(stylex.props(themes.systemColor, themes.systemThemeColor)),
  pink: className(stylex.props(themes.pinkColor, themes.pinkThemeColor)),
  sunset: className(stylex.props(themes.sunsetColor, themes.sunsetThemeColor)),
  midnight: className(stylex.props(themes.midnightColor, themes.midnightThemeColor)),
  ash: className(stylex.props(themes.ashColor, themes.ashThemeColor)),
  flexoki: className(stylex.props(themes.flexokiColor, themes.flexokiThemeColor)),
  pastel: className(stylex.props(themes.pastelColor, themes.pastelThemeColor)),
  "neon-noir": className(stylex.props(themes.neonNoirColor, themes.neonNoirThemeColor)),
}

/** `var(--x1abc)` to `--x1abc`. */
export const customPropertyName = (reference: string): string => {
  const match = /^var\((--[\w-]+)\)$/.exec(reference.trim())
  if (!match?.[1]) throw new Error(`Not a StyleX variable reference: ${reference}`)
  return match[1]
}

export const stylexAppearanceBinding: AppearanceBinding = {
  root: className(stylex.props(schemes.root)),
  appearance: {
    light: className(stylex.props(schemes.light)),
    dark: className(stylex.props(schemes.dark)),
    system: className(stylex.props(schemes.system)),
  },
  theme: themeClasses,
  sidebarItemSize: { compact: "", standard: className(stylex.props(standardDensity)) },
  messageFont: { system: "", monospace: className(stylex.props(monospaceText)) },
  vars: {
    messageFontSize: customPropertyName(chatText.messageFontSize),
    messageLineHeight: customPropertyName(chatText.messageLineHeight),
    emojiLarge: customPropertyName(chatText.emojiLarge),
    emojiMedium: customPropertyName(chatText.emojiMedium),
    emojiSmall: customPropertyName(chatText.emojiSmall),
  },
}

/**
 * The app's controller: local storage, the window's `matchMedia`, the StyleX
 * binding. Call `attach(document.documentElement)` right after, in the same
 * task, before the first render (see README, "Before first paint").
 */
export function createDocumentAppearance(
  options: Partial<AppearanceControllerOptions> = {},
): AppearanceController {
  const matchMedia =
    typeof globalThis.matchMedia === "function" ? (query: string) => globalThis.matchMedia(query) : undefined
  return new AppearanceController({
    storage: localAppearanceStorage(),
    binding: stylexAppearanceBinding,
    matchMedia,
    ...options,
  })
}

/** Classes that give a subtree a fixed appearance and theme (previews, swatches, the lab). */
export const themeScopeClassName = (theme: ThemeId, appearance: Appearance): string =>
  [stylexAppearanceBinding.root, stylexAppearanceBinding.appearance[appearance], stylexAppearanceBinding.theme[theme]]
    .filter(Boolean)
    .join(" ")

/**
 * The app shell's one call, first thing in the entry module, before
 * `createRoot().render`: creates the document controller, applies it to
 * `<html>` in this task, and follows changes other tabs make. Returns the
 * controller for settings views and the command registry.
 */
export function startDocumentAppearance(
  options: Partial<AppearanceControllerOptions> = {},
): AppearanceController {
  const controller = createDocumentAppearance(options)
  if (typeof document !== "undefined") controller.attach(document.documentElement)
  if (typeof window !== "undefined") {
    const key = options.key ?? APPEARANCE_STORAGE_KEY
    window.addEventListener("storage", (event) => {
      if (event.key === key) controller.reload()
    })
  }
  return controller
}
