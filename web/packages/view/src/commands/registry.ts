/**
 * The command registry. Every user action is a command with a stable ID, a
 * title, a category, shortcuts per platform, an enabled state and a handler.
 * Menus, context menus, the command bar, the shortcut reference and
 * Electron's native menu all read from here; the keyboard dispatcher resolves
 * keys to commands through it.
 */

import { computed, signal, type ReadSignal } from "@inline/reactive"
import type { KeyEventLike } from "./shortcut"
import { comboId, parseShortcut, resolveShortcut, type KeyCombo, type ParsedShortcut } from "./shortcut"
import type { OS, Platform } from "./platform"

/**
 * A focus region whose commands apply while it is focused. `global` is
 * always active. Feature code may add its own scope names.
 */
export type ScopeId = "global" | "sidebar" | "timeline" | "composer" | "menu" | "dialog" | (string & {})

export const commandCategories = {
  app: "Inline",
  navigation: "Navigation",
  view: "View",
  window: "Window",
  edit: "Edit",
  format: "Format",
  chat: "Chat",
  message: "Message",
} as const

export type CommandCategory = keyof typeof commandCategories

/** One or more shortcuts; an empty list means none. */
export type ShortcutList = string | readonly string[]

export type ShortcutVariant = {
  /** Used for any OS not listed. */
  readonly default?: ShortcutList
  readonly mac?: ShortcutList
  readonly windows?: ShortcutList
  readonly linux?: ShortcutList
}

/**
 * Shortcuts per platform. The top level is the desktop app. `browser`
 * overrides it in a browser tab, where the browser owns new tab, new window,
 * close, tab switching and history keys; any OS it leaves out inherits the
 * desktop shortcut. `browser: { default: [] }` unbinds in every browser.
 */
export type ShortcutSpec = ShortcutVariant & { readonly browser?: ShortcutVariant }

/**
 * Whether a shortcut fires while a text field has focus.
 * - `auto`: only if it cannot be typing (it has Cmd or Ctrl, or is Alt with
 *   a non-character key, or is a function key). The default.
 * - `always`: also plain keys, such as Escape to leave the field.
 * - `never`: never in a text field.
 */
export type WhileTyping = "auto" | "always" | "never"

export type CommandSource = "keyboard" | "menu" | "contextMenu" | "palette" | "api"

export type CommandContext = {
  readonly source: CommandSource
  /** The key event, when the source is the keyboard. */
  readonly event?: KeyEventLike
}

export type CommandSpec = {
  /** Stable, dotted: `navigation.back`. Persisted in settings and telemetry; never rename. */
  readonly id: string
  readonly title: string
  readonly category: CommandCategory
  readonly description?: string
  /** Defaults to `global`. */
  readonly scope?: ScopeId
  readonly shortcuts?: ShortcutSpec
  /** Defaults to always enabled. */
  readonly enabled?: ReadSignal<boolean>
  /** Whether holding the key runs the command again. Defaults to false. */
  readonly repeat?: boolean
  readonly whileTyping?: WhileTyping
  /** Show in the command bar. Defaults to true. */
  readonly inPalette?: boolean
  readonly run: (context: CommandContext) => void
}

export type Command = CommandSpec & {
  readonly scope: ScopeId
  readonly enabled: ReadSignal<boolean>
  readonly repeat: boolean
  readonly whileTyping: WhileTyping
  /** The parsed shortcuts for a platform. */
  shortcutsFor(platform: Platform): readonly KeyCombo[]
}

export type Binding = {
  readonly command: Command
  readonly combo: KeyCombo
  readonly comboId: string
}

const alwaysEnabled: ReadSignal<boolean> = { get: () => true, peek: () => true }

const asList = (value: ShortcutList | undefined): readonly string[] | undefined =>
  value === undefined ? undefined : typeof value === "string" ? [value] : value

const pick = (variant: ShortcutVariant | undefined, os: OS): readonly string[] | undefined =>
  variant ? (asList(variant[os]) ?? asList(variant.default)) : undefined

/** The shortcut texts that apply on a platform, before parsing. */
export const shortcutTextsFor = (spec: ShortcutSpec | undefined, platform: Platform): readonly string[] => {
  if (!spec) return []
  if (platform.surface === "browser") {
    const browser = pick(spec.browser, platform.os)
    if (browser) return browser
  }
  return pick(spec, platform.os) ?? []
}

const allTexts = (spec: ShortcutSpec | undefined): string[] => {
  if (!spec) return []
  const variants = [spec, spec.browser].filter((v): v is ShortcutVariant => v !== undefined)
  return variants.flatMap((v) => [v.default, v.mac, v.windows, v.linux].flatMap((list) => asList(list) ?? []))
}

const createCommand = (spec: CommandSpec): Command => {
  const parsed = new Map<string, ParsedShortcut>()
  // Parse every text now so a bad shortcut fails at registration, not on a key press.
  for (const text of allTexts(spec.shortcuts)) parsed.set(text, parseShortcut(text))
  const cache = new Map<string, readonly KeyCombo[]>()
  return {
    ...spec,
    scope: spec.scope ?? "global",
    enabled: spec.enabled ?? alwaysEnabled,
    repeat: spec.repeat ?? false,
    whileTyping: spec.whileTyping ?? "auto",
    shortcutsFor: (platform) => {
      const key = `${platform.surface}-${platform.os}`
      const cached = cache.get(key)
      if (cached) return cached
      const combos = shortcutTextsFor(spec.shortcuts, platform).map((text) =>
        resolveShortcut(parsed.get(text) ?? parseShortcut(text), platform.os),
      )
      cache.set(key, combos)
      return combos
    },
  }
}

export class CommandRegistry {
  readonly #commands = signal<readonly Command[]>([])
  readonly #bindingCache = new Map<string, Map<string, Binding[]>>()

  /** Every registered command, in registration order. */
  readonly commands: ReadSignal<readonly Command[]> = computed(() => this.#commands.get())

  /** Register a command. Throws on a duplicate ID or a malformed shortcut. Returns an unregister function. */
  register(spec: CommandSpec): () => void {
    if (this.get(spec.id)) throw new Error(`Command "${spec.id}" is already registered`)
    const command = createCommand(spec)
    this.#commands.set([...this.#commands.peek(), command])
    this.#bindingCache.clear()
    return () => {
      const current = this.#commands.peek()
      if (!current.includes(command)) return
      this.#commands.set(current.filter((c) => c !== command))
      this.#bindingCache.clear()
    }
  }

  get(id: string): Command | undefined {
    return this.#commands.peek().find((command) => command.id === id)
  }

  isEnabled(id: string): boolean {
    return this.get(id)?.enabled.peek() ?? false
  }

  /** Run a command by ID if it exists and is enabled. Returns whether it ran. */
  run(id: string, context: CommandContext = { source: "api" }): boolean {
    const command = this.get(id)
    if (!command || !command.enabled.peek()) return false
    command.run(context)
    return true
  }

  /** Bindings on a platform, keyed by `comboId`, in registration order. */
  bindings(platform: Platform): ReadonlyMap<string, readonly Binding[]> {
    const key = `${platform.surface}-${platform.os}`
    const cached = this.#bindingCache.get(key)
    if (cached) return cached
    const map = new Map<string, Binding[]>()
    for (const command of this.#commands.peek()) {
      for (const combo of command.shortcutsFor(platform)) {
        const id = comboId(combo)
        const list = map.get(id) ?? []
        list.push({ command, combo, comboId: id })
        map.set(id, list)
      }
    }
    this.#bindingCache.set(key, map)
    return map
  }

  /** Combos bound more than once in the same scope on a platform. Should be empty. */
  conflicts(platform: Platform): readonly { comboId: string; scope: ScopeId; commandIds: string[] }[] {
    const result: { comboId: string; scope: ScopeId; commandIds: string[] }[] = []
    for (const [id, bindings] of this.bindings(platform)) {
      const byScope = new Map<ScopeId, string[]>()
      for (const binding of bindings) {
        const ids = byScope.get(binding.command.scope) ?? []
        ids.push(binding.command.id)
        byScope.set(binding.command.scope, ids)
      }
      for (const [scope, commandIds] of byScope) if (commandIds.length > 1) result.push({ comboId: id, scope, commandIds })
    }
    return result
  }
}
