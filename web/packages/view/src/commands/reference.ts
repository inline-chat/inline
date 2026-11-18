/**
 * The shortcut reference, generated from the registry as plain data, grouped
 * by platform and category. The settings page, the help overlay and
 * Electron's native menu read this instead of keeping their own lists.
 */

import { allPlatforms, platformKey, platformLabel, type Platform } from "./platform"
import { commandCategories, type CommandCategory, type CommandRegistry } from "./registry"
import { comboId, formatCombo, toAccelerator } from "./shortcut"

export type ShortcutReferenceKey = {
  /** Canonical, for matching: `Ctrl+Alt+Shift+Meta+k`. */
  readonly combo: string
  /** For display on this platform: `⌘K`, `Ctrl+K`. */
  readonly display: string
  /** Electron accelerator syntax. */
  readonly accelerator: string
}

export type ShortcutReferenceCommand = {
  readonly id: string
  readonly title: string
  readonly scope: string
  /** Empty when the command has no shortcut on this platform. */
  readonly keys: readonly ShortcutReferenceKey[]
}

export type ShortcutReferenceCategory = {
  readonly category: CommandCategory
  readonly title: string
  readonly commands: readonly ShortcutReferenceCommand[]
}

export type ShortcutReference = {
  readonly platform: Platform
  /** `mac-desktop`-style key for the platform. */
  readonly key: string
  readonly label: string
  readonly categories: readonly ShortcutReferenceCategory[]
}

const categoryOrder = Object.keys(commandCategories) as CommandCategory[]

export type ShortcutReferenceOptions = {
  /** Leave out commands without a shortcut on the platform. Default false. */
  readonly boundOnly?: boolean
}

export const buildShortcutReference = (
  registry: CommandRegistry,
  platform: Platform,
  options: ShortcutReferenceOptions = {},
): ShortcutReference => {
  const groups = new Map<CommandCategory, ShortcutReferenceCommand[]>()
  for (const command of registry.commands.peek()) {
    const keys = command.shortcutsFor(platform).map((combo) => ({
      combo: comboId(combo),
      display: formatCombo(combo, platform.os),
      accelerator: toAccelerator(combo),
    }))
    if (options.boundOnly && keys.length === 0) continue
    const list = groups.get(command.category) ?? []
    list.push({ id: command.id, title: command.title, scope: command.scope, keys })
    groups.set(command.category, list)
  }
  const categories = categoryOrder
    .filter((category) => groups.has(category))
    .map((category) => ({ category, title: commandCategories[category], commands: groups.get(category) ?? [] }))
  return { platform, key: platformKey(platform), label: platformLabel(platform), categories }
}

/** The reference for every platform, desktop first. */
export const buildShortcutReferences = (
  registry: CommandRegistry,
  platforms: readonly Platform[] = allPlatforms,
  options: ShortcutReferenceOptions = {},
): readonly ShortcutReference[] => platforms.map((platform) => buildShortcutReference(registry, platform, options))
