/**
 * The appearance controller: owns the appearance settings as signals,
 * persists them, follows the system appearance, and applies everything to a
 * root element (the document's `<html>`, or a preview container) as classes,
 * data attributes and CSS variables. Framework-free; the StyleX class names
 * and variable names come in through an `AppearanceBinding`
 * (`stylex-binding.ts` in the app, a fake in tests).
 *
 * Every setter writes the signal, the storage and the root in the same task.
 */

import { computed, effect, type ReadSignal, signal } from "@inline/reactive"
import type { ThemeId, Variant } from "./catalog"
import { canvasColors } from "./palette"
import {
  type Appearance,
  type AppearanceSettings,
  clampLineSpacing,
  clampTextSize,
  DEFAULT_APPEARANCE_SETTINGS,
  DEFAULT_TEXT_SIZE,
  type MessageFont,
  type MessageStyle,
  nextLargerTextSize,
  nextSmallerTextSize,
  parseAppearanceSettings,
  sameAppearanceSettings,
  serializeAppearanceSettings,
  type SidebarItemSize,
  type UnreadBadgeStyle,
} from "./settings"
import {
  APPEARANCE_BOOT_KEY,
  APPEARANCE_STORAGE_KEY,
  type AppearanceStorage,
  BOOT_RECORD_VERSION,
  type BootRecord,
} from "./storage"

export type Dispose = () => void

export type MediaQueryListLike = {
  readonly matches: boolean
  addEventListener(type: "change", listener: () => void): void
  removeEventListener(type: "change", listener: () => void): void
}

export type MatchMedia = (query: string) => MediaQueryListLike

/** The parts of an element the controller touches. `document.documentElement` is one. */
export interface AppearanceRootElement {
  readonly classList: { add(...tokens: string[]): void; remove(...tokens: string[]): void }
  setAttribute(name: string, value: string): void
  removeAttribute(name: string): void
  hasAttribute(name: string): boolean
  readonly style: { setProperty(name: string, value: string): void; removeProperty(name: string): string }
}

/**
 * How settings become CSS. Class strings may hold several space-separated
 * classes; `vars` are custom property names (`--x1abc`).
 */
export interface AppearanceBinding {
  /** Always on the root: canvas background and text color from the tokens. */
  readonly root: string
  /** `color-scheme` per appearance choice ("light dark" for system). */
  readonly appearance: Record<Appearance, string>
  readonly theme: Record<ThemeId, string>
  readonly sidebarItemSize: Record<SidebarItemSize, string>
  readonly messageFont: Record<MessageFont, string>
  readonly vars: {
    readonly messageFontSize: string
    readonly messageLineHeight: string
    readonly emojiLarge: string
    readonly emojiMedium: string
    readonly emojiSmall: string
  }
}

/** Data attributes on the root, for debugging, tests and code outside StyleX (the Electron shell). */
export const ROOT_ATTRIBUTES = {
  appearance: "data-appearance",
  resolvedAppearance: "data-resolved-appearance",
  theme: "data-theme",
  boot: "data-appearance-boot",
} as const

/**
 * The natural line height of the system UI font at line spacing 1. The Mac
 * app multiplies the font's own line height (ascender, descender and leading:
 * about 1.2 for SF at 13pt); CSS cannot read font metrics, so this is the
 * kit's `font.lineHeightTight`.
 */
export const NATURAL_LINE_HEIGHT = 1.2

/** `ChatTypography` emoji sizes at the system size, scaled with the text size. */
export const EMOJI_SIZES = { large: 64, medium: 42, small: 18 } as const

const DARK_QUERY = "(prefers-color-scheme: dark)"

/** The CSS variable values for a text size and line spacing; `undefined` means the token default. */
export function typographyVariables(textSize: number, lineSpacing: number): {
  messageFontSize?: string
  messageLineHeight?: string
  emojiLarge?: string
  emojiMedium?: string
  emojiSmall?: string
} {
  const round = (n: number) => Math.round(n * 1000) / 1000
  const sized = textSize !== DEFAULT_TEXT_SIZE
  const scaleEmoji = (base: number) => (sized ? `${round((base * textSize) / DEFAULT_TEXT_SIZE)}px` : undefined)
  return {
    messageFontSize: sized ? `${textSize}px` : undefined,
    messageLineHeight: lineSpacing !== 1 ? String(round(NATURAL_LINE_HEIGHT * lineSpacing)) : undefined,
    emojiLarge: scaleEmoji(EMOJI_SIZES.large),
    emojiMedium: scaleEmoji(EMOJI_SIZES.medium),
    emojiSmall: scaleEmoji(EMOJI_SIZES.small),
  }
}

const classTokens = (value: string) => value.split(/\s+/).filter(Boolean)

export type AppearanceControllerOptions = {
  readonly storage: AppearanceStorage
  readonly binding: AppearanceBinding
  /** `window.matchMedia` in the app. Without it, "system" resolves to light. */
  readonly matchMedia?: MatchMedia
  /** Storage key; defaults to `inline.appearance`. */
  readonly key?: string
  /** Whether to write the pre-paint boot record (only the document controller should). Default true. */
  readonly writeBootRecord?: boolean
}

export type AppearancePatch = Partial<Omit<AppearanceSettings, "version">>

export class AppearanceController {
  readonly settings: ReadSignal<AppearanceSettings>
  readonly appearance: ReadSignal<Appearance>
  /** The appearance in effect: the choice, or the system's when the choice is "system". */
  readonly resolvedAppearance: ReadSignal<Variant>
  /** Whether the system prefers dark, tracked live. */
  readonly systemPrefersDark: ReadSignal<boolean>
  readonly theme: ReadSignal<ThemeId>
  readonly textSize: ReadSignal<number>
  readonly canIncreaseTextSize: ReadSignal<boolean>
  readonly canDecreaseTextSize: ReadSignal<boolean>
  readonly isDefaultTextSize: ReadSignal<boolean>
  readonly lineSpacing: ReadSignal<number>
  readonly messageFont: ReadSignal<MessageFont>
  readonly sidebarItemSize: ReadSignal<SidebarItemSize>
  readonly messageStyle: ReadSignal<MessageStyle>
  readonly unreadBadgeStyle: ReadSignal<UnreadBadgeStyle>
  readonly compactToolbar: ReadSignal<boolean>
  readonly centeredChats: ReadSignal<boolean>

  private readonly state
  private readonly systemDark
  private readonly options: AppearanceControllerOptions
  private readonly key: string
  private readonly disposers: Dispose[] = []
  private disposed = false

  constructor(options: AppearanceControllerOptions) {
    this.options = options
    this.key = options.key ?? APPEARANCE_STORAGE_KEY
    this.state = signal<AppearanceSettings>(parseAppearanceSettings(this.read(this.key)), {
      equals: sameAppearanceSettings,
    })
    this.settings = this.state

    const query = options.matchMedia?.(DARK_QUERY)
    this.systemDark = signal(query?.matches ?? false)
    this.systemPrefersDark = this.systemDark
    if (query) {
      const onChange = () => this.systemDark.set(query.matches)
      query.addEventListener("change", onChange)
      this.disposers.push(() => query.removeEventListener("change", onChange))
    }

    const field = <K extends keyof AppearanceSettings>(name: K) => computed(() => this.state.get()[name])
    this.appearance = field("appearance")
    this.theme = field("theme")
    this.textSize = field("textSize")
    this.lineSpacing = field("lineSpacing")
    this.messageFont = field("messageFont")
    this.sidebarItemSize = field("sidebarItemSize")
    this.messageStyle = field("messageStyle")
    this.unreadBadgeStyle = field("unreadBadgeStyle")
    this.compactToolbar = field("compactToolbar")
    this.centeredChats = field("centeredChats")
    this.resolvedAppearance = computed<Variant>(() => {
      const choice = this.appearance.get()
      if (choice === "system") return this.systemDark.get() ? "dark" : "light"
      return choice
    })
    this.canIncreaseTextSize = computed(() => nextLargerTextSize(this.textSize.get()) !== undefined)
    this.canDecreaseTextSize = computed(() => nextSmallerTextSize(this.textSize.get()) !== undefined)
    this.isDefaultTextSize = computed(() => this.textSize.get() === DEFAULT_TEXT_SIZE)

    if (options.writeBootRecord !== false) {
      this.disposers.push(
        effect(() => {
          this.writeBootRecord(this.appearance.get(), this.theme.get())
        }),
      )
    }
  }

  /**
   * Apply the settings to `element` and keep them applied until the returned
   * function runs, which removes everything this controller added. Works as a
   * part (`useElement(controller)`). Several elements can be attached.
   */
  attach(element: AppearanceRootElement): Dispose {
    if (this.disposed) return () => {}
    const { binding } = this.options
    let applied: string[] = []
    const vars = Object.values(binding.vars)

    const stop = effect(() => {
      const settings = this.state.get()
      const resolved = this.resolvedAppearance.get()
      const next = [
        binding.root,
        binding.appearance[settings.appearance],
        binding.theme[settings.theme],
        binding.sidebarItemSize[settings.sidebarItemSize],
        binding.messageFont[settings.messageFont],
      ].flatMap(classTokens)
      const nextSet = new Set(next)
      const stale = applied.filter((token) => !nextSet.has(token))
      if (stale.length > 0) element.classList.remove(...stale)
      element.classList.add(...next)
      applied = next

      element.setAttribute(ROOT_ATTRIBUTES.appearance, settings.appearance)
      element.setAttribute(ROOT_ATTRIBUTES.resolvedAppearance, resolved)
      element.setAttribute(ROOT_ATTRIBUTES.theme, settings.theme)

      const values = typographyVariables(settings.textSize, settings.lineSpacing)
      for (const [name, property] of Object.entries(binding.vars) as Array<[keyof typeof values, string]>) {
        const value = values[name]
        if (value === undefined) element.style.removeProperty(property)
        else element.style.setProperty(property, value)
      }

      // The classes now carry what the boot script set inline; drop its stand-ins.
      if (element.hasAttribute(ROOT_ATTRIBUTES.boot)) {
        element.style.removeProperty("color-scheme")
        element.style.removeProperty("background-color")
        element.removeAttribute(ROOT_ATTRIBUTES.boot)
      }
    })

    let detached = false
    const detach = () => {
      if (detached) return
      detached = true
      stop()
      if (applied.length > 0) element.classList.remove(...applied)
      applied = []
      for (const name of Object.values(ROOT_ATTRIBUTES)) {
        if (name !== ROOT_ATTRIBUTES.boot) element.removeAttribute(name)
      }
      for (const property of vars) element.style.removeProperty(property)
      const index = this.disposers.indexOf(detach)
      if (index >= 0) this.disposers.splice(index, 1)
    }
    this.disposers.push(detach)
    return detach
  }

  /** Change several settings at once. Invalid values are ignored field by field. */
  update(patch: AppearancePatch): void {
    if (this.disposed) return
    const current = this.state.peek()
    const candidate = parseAppearanceSettings({ ...current, ...patch })
    const merged: Record<string, unknown> = { ...candidate }
    // A field the parser rejected keeps its current value, not the default.
    for (const key of Object.keys(patch) as Array<keyof AppearancePatch>) {
      if (patch[key] !== undefined && !this.accepts(key, patch[key], candidate)) merged[key] = current[key]
    }
    const next = merged as AppearanceSettings
    if (sameAppearanceSettings(current, next)) return
    this.state.set(next)
    this.write(this.key, serializeAppearanceSettings(next))
  }

  setAppearance(appearance: Appearance): void {
    this.update({ appearance })
  }

  setTheme(theme: ThemeId): void {
    this.update({ theme })
  }

  /** Any size is clamped to 10...32, as the Mac app does; the stepper and commands move between steps. */
  setTextSize(textSize: number): void {
    if (!Number.isFinite(textSize)) return
    this.update({ textSize: clampTextSize(textSize) })
  }

  /** Make Text Bigger. Returns false at the largest size (the Mac app beeps). */
  increaseTextSize(): boolean {
    const next = nextLargerTextSize(this.textSize.peek())
    if (next === undefined) return false
    this.update({ textSize: next })
    return true
  }

  /** Make Text Smaller. Returns false at the smallest size. */
  decreaseTextSize(): boolean {
    const next = nextSmallerTextSize(this.textSize.peek())
    if (next === undefined) return false
    this.update({ textSize: next })
    return true
  }

  /** Make Text Normal Size. */
  resetTextSize(): void {
    this.update({ textSize: DEFAULT_TEXT_SIZE })
  }

  setLineSpacing(lineSpacing: number): void {
    if (!Number.isFinite(lineSpacing)) return
    this.update({ lineSpacing: clampLineSpacing(lineSpacing) })
  }

  setMessageFont(messageFont: MessageFont): void {
    this.update({ messageFont })
  }

  setSidebarItemSize(sidebarItemSize: SidebarItemSize): void {
    this.update({ sidebarItemSize })
  }

  setMessageStyle(messageStyle: MessageStyle): void {
    this.update({ messageStyle })
  }

  setUnreadBadgeStyle(unreadBadgeStyle: UnreadBadgeStyle): void {
    this.update({ unreadBadgeStyle })
  }

  setCompactToolbar(compactToolbar: boolean): void {
    this.update({ compactToolbar })
  }

  setCenteredChats(centeredChats: boolean): void {
    this.update({ centeredChats })
  }

  /** Restore Defaults for the message text (font, size, line spacing), like the Mac settings footer. */
  resetMessageText(): void {
    const d = DEFAULT_APPEARANCE_SETTINGS
    this.update({ messageFont: d.messageFont, textSize: d.textSize, lineSpacing: d.lineSpacing })
  }

  /** Every setting back to its default. */
  reset(): void {
    const { version: _version, ...defaults } = DEFAULT_APPEARANCE_SETTINGS
    this.update(defaults)
  }

  /**
   * Re-read the stored settings (another tab changed them: listen for the
   * `storage` event and call this). Applies without writing back.
   */
  reload(): void {
    if (this.disposed) return
    this.state.set(parseAppearanceSettings(this.read(this.key)))
  }

  dispose(): void {
    if (this.disposed) return
    for (const dispose of [...this.disposers].reverse()) dispose()
    this.disposers.length = 0
    this.disposed = true
  }

  private accepts(key: keyof AppearancePatch, value: unknown, parsed: AppearanceSettings): boolean {
    // The parser normalizes numbers (clamping) and legacy names; accept those.
    if (key === "textSize" || key === "lineSpacing") return typeof value === "number" && Number.isFinite(value)
    return Object.is(parsed[key], value)
  }

  /** Storage is outside our control (a sync backend later); a failure keeps the setting for this session. */
  private read(key: string): string | null {
    try {
      return this.options.storage.read(key)
    } catch {
      return null
    }
  }

  private write(key: string, value: string): void {
    try {
      this.options.storage.write(key, value)
    } catch {
      // Kept in memory for this session.
    }
  }

  private writeBootRecord(appearance: Appearance, theme: ThemeId): void {
    const canvas = canvasColors(theme)
    const record: BootRecord = { v: BOOT_RECORD_VERSION, a: appearance, l: canvas.light, d: canvas.dark }
    const text = JSON.stringify(record)
    if (this.read(APPEARANCE_BOOT_KEY) !== text) this.write(APPEARANCE_BOOT_KEY, text)
  }
}
