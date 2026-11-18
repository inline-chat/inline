/**
 * The first commands: navigation, focus and app-level ones. Shortcuts follow
 * the Mac app (apple/InlineMac/App/AppMenu.swift and GlobalHotkeys.swift)
 * where it has them; the browser variants avoid what the browser owns (see
 * `reserved.ts`).
 */

import type { ReadSignal } from "@inline/reactive"
import type { HistoryBinding } from "../workspace/history-binding"
import type { Workspace } from "../workspace/workspace"
import type { CommandRegistry, CommandSpec } from "./registry"

export const navigationCommandIds = {
  back: "navigation.back",
  forward: "navigation.forward",
  previousChat: "navigation.previousChat",
  nextChat: "navigation.nextChat",
  focusSidebar: "focus.sidebar",
  focusComposer: "focus.composer",
  quickSearch: "app.quickSearch",
  toggleSidebar: "view.toggleSidebar",
  settings: "app.settings",
  closePane: "window.closePane",
} as const

export type FocusRegion = "sidebar" | "composer"

export type NavigationCommandDeps = {
  readonly workspace: Workspace
  /**
   * When the window owns the address bar, the binding's Back and Forward keep
   * browser history in step (policy rule 6 in `history-binding.ts`).
   * Without it, Back and Forward act on the workspace directly.
   */
  readonly history?: HistoryBinding
  /** Select the previous (-1) or next (1) chat in the sidebar's order. */
  readonly selectAdjacentChat: (direction: -1 | 1) => void
  readonly canSelectAdjacentChat?: ReadSignal<boolean>
  readonly focusRegion: (region: FocusRegion) => void
  readonly openQuickSearch: () => void
  readonly toggleSidebar: () => void
  /** Defaults to opening the settings destination in the focused pane. */
  readonly openSettings?: () => void
}

export const navigationCommands = (deps: NavigationCommandDeps): readonly CommandSpec[] => {
  const { workspace } = deps
  return [
    {
      id: navigationCommandIds.back,
      title: "Back",
      category: "navigation",
      // Mac app: Cmd+[. In a browser tab the browser's own Back (Cmd+[, Alt+Left,
      // the button) already moves the focused pane through popstate.
      shortcuts: { mac: "Mod+[", default: "Alt+ArrowLeft", browser: { default: [] } },
      enabled: workspace.canGoBack,
      run: () => {
        if (deps.history) deps.history.back()
        else workspace.back()
      },
    },
    {
      id: navigationCommandIds.forward,
      title: "Forward",
      category: "navigation",
      shortcuts: { mac: "Mod+]", default: "Alt+ArrowRight", browser: { default: [] } },
      enabled: workspace.canGoForward,
      run: () => {
        if (deps.history) deps.history.forward()
        else workspace.forward()
      },
    },
    {
      id: navigationCommandIds.previousChat,
      title: "Previous Chat",
      category: "navigation",
      // Mac app: Option+Up in the Chat menu; Ctrl+K and Ctrl+P in GlobalHotkeys.
      shortcuts: { default: "Alt+ArrowUp", mac: ["Alt+ArrowUp", "Ctrl+K", "Ctrl+P"] },
      enabled: deps.canSelectAdjacentChat,
      repeat: true,
      run: () => deps.selectAdjacentChat(-1),
    },
    {
      id: navigationCommandIds.nextChat,
      title: "Next Chat",
      category: "navigation",
      shortcuts: { default: "Alt+ArrowDown", mac: ["Alt+ArrowDown", "Ctrl+J", "Ctrl+N"] },
      enabled: deps.canSelectAdjacentChat,
      repeat: true,
      run: () => deps.selectAdjacentChat(1),
    },
    {
      id: navigationCommandIds.focusSidebar,
      title: "Focus Sidebar",
      category: "navigation",
      // Not in the Mac app. Firefox owns Ctrl+Shift+E (network monitor) in a
      // browser tab on Windows and Linux, so it is unbound there.
      shortcuts: { default: "Mod+Shift+E", browser: { windows: [], linux: [] } },
      run: () => deps.focusRegion("sidebar"),
    },
    {
      id: navigationCommandIds.focusComposer,
      title: "Focus Composer",
      category: "navigation",
      // Escape from the message list returns to the composer. Typing anywhere
      // outside a text field also focuses it (the dispatcher's type-to-focus).
      scope: "timeline",
      shortcuts: { default: "Escape" },
      run: () => deps.focusRegion("composer"),
    },
    {
      id: navigationCommandIds.quickSearch,
      title: "Quick Search",
      category: "navigation",
      shortcuts: { default: "Mod+K" },
      run: () => deps.openQuickSearch(),
    },
    {
      id: navigationCommandIds.toggleSidebar,
      title: "Toggle Sidebar",
      category: "view",
      // Mac app: Cmd+S. Taken over from "save page" in the browser on purpose.
      shortcuts: { default: "Mod+S" },
      run: () => deps.toggleSidebar(),
    },
    {
      id: navigationCommandIds.settings,
      title: "Settings…",
      category: "app",
      // Mac app: Cmd+,. Safari and Chrome on Mac open their own settings with it.
      shortcuts: { default: "Mod+,", browser: { mac: [] } },
      run: () => {
        if (deps.openSettings) deps.openSettings()
        else workspace.open({ kind: "settings" })
      },
    },
    {
      id: navigationCommandIds.closePane,
      title: "Close Pane",
      category: "window",
      // In the desktop app Cmd/Ctrl+W closes a pane; with one pane the command
      // is disabled and the key falls through to the native Close Window.
      // A browser owns Cmd/Ctrl+W.
      shortcuts: { default: "Mod+W", browser: { default: [] } },
      enabled: workspace.canClosePane,
      run: () => {
        workspace.closePane()
      },
    },
  ]
}

/** Register the navigation commands. Returns a function that unregisters them all. */
export const registerNavigationCommands = (registry: CommandRegistry, deps: NavigationCommandDeps): (() => void) => {
  const disposers = navigationCommands(deps).map((spec) => registry.register(spec))
  return () => {
    for (const dispose of disposers) dispose()
  }
}
