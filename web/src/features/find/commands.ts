/**
 * Find in chat as commands: "Find in Chat" (Mod+F), "Find Next" (Mod+G) and
 * "Find Previous" (Mod+Shift+G), as in the Mac app's Edit > Find menu
 * (`apple/InlineMac/App/AppMenu.swift`, `ChatViewAppKit` validation).
 *
 * The commands are registered once per session and act on the chat pane
 * the app says is the target (the focused pane, when it shows a chat).
 * Without a target they are disabled, and a disabled command does not
 * match, so the key falls through to the browser (its own find).
 *
 * Rule for Mod+F: it opens the bar, or focuses the bar's field when the bar
 * is open and focus is elsewhere. While the field itself has focus, "Find in
 * Chat" is disabled, so a second Mod+F reaches the browser's own find (for
 * text outside the chat, or the visible page). Escape in the field closes
 * the bar.
 *
 * Framework-free.
 */

import { computed, type Dispose, type ReadSignal } from "@inline/reactive"
import type { CommandRegistry, ShortcutSpec } from "@inline/view"

export const findCommandIds = {
  find: "chat.find",
  findNext: "chat.findNext",
  findPrevious: "chat.findPrevious",
} as const

/** Shortcuts, Mac first. Windows and Linux also take F3 and Shift+F3, their usual find next and previous. */
export const findShortcuts = {
  find: { default: "Mod+F" },
  findNext: { mac: "Mod+G", default: ["Mod+G", "F3"] },
  findPrevious: { mac: "Mod+Shift+G", default: ["Mod+Shift+G", "Shift+F3"] },
} as const satisfies Record<keyof typeof findCommandIds, ShortcutSpec>

/** What the commands drive: `FindInChatModel` satisfies it. */
export type FindCommandTarget = {
  readonly isOpen: ReadSignal<boolean>
  readonly fieldFocused: ReadSignal<boolean>
  readonly canGoOlder: ReadSignal<boolean>
  readonly canGoNewer: ReadSignal<boolean>
  open(options?: { readonly seed?: string }): void
  next(): void
  previous(): void
}

export type FindCommandsOptions = {
  /**
   * The chat pane the commands act on: the focused pane's find model when
   * that pane shows a chat, else undefined.
   */
  readonly target: ReadSignal<FindCommandTarget | undefined>
  /**
   * The text to seed a new search with: the page's selection inside the
   * chat (`chatSelectionText`), read when Mod+F runs. Optional.
   */
  readonly readSelection?: () => string | undefined
}

/** Register the three commands. Returns the function that unregisters them. */
export const registerFindCommands = (registry: CommandRegistry, options: FindCommandsOptions): Dispose => {
  const { target } = options
  const disposers = [
    registry.register({
      id: findCommandIds.find,
      title: "Find in Chat",
      category: "edit",
      description: "Search this chat's messages",
      shortcuts: findShortcuts.find,
      enabled: computed(() => {
        const current = target.get()
        return current !== undefined && !(current.isOpen.get() && current.fieldFocused.get())
      }),
      run: () => {
        const current = target.peek()
        if (!current) return
        const seed = options.readSelection?.()
        current.open(seed !== undefined ? { seed } : {})
      },
    }),
    registry.register({
      id: findCommandIds.findNext,
      title: "Find Next",
      category: "edit",
      description: "The next older match; opens find in chat when it is closed",
      shortcuts: findShortcuts.findNext,
      inPalette: false,
      repeat: true,
      enabled: computed(() => {
        const current = target.get()
        if (!current) return false
        return current.isOpen.get() ? current.canGoOlder.get() : true
      }),
      run: () => {
        const current = target.peek()
        if (!current) return
        if (current.isOpen.peek()) current.next()
        else current.open()
      },
    }),
    registry.register({
      id: findCommandIds.findPrevious,
      title: "Find Previous",
      category: "edit",
      description: "The next newer match",
      shortcuts: findShortcuts.findPrevious,
      inPalette: false,
      repeat: true,
      enabled: computed(() => {
        const current = target.get()
        return current !== undefined && current.isOpen.get() && current.canGoNewer.get()
      }),
      run: () => target.peek()?.previous(),
    }),
  ]
  return () => {
    for (const dispose of disposers) dispose()
  }
}
