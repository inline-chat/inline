/**
 * The settings pane's model: what `SettingsView` needs from the shell, built
 * once per pane so its identities stay stable (a new `onNavigate` would
 * rebuild the view's model and drop the search text).
 *
 * - `openPage(page)`: a history entry per page in this pane, so Back walks
 *   pages as the Mac settings window's Back does.
 * - `account`: the signed-in user, this device's name and Sign Out. The
 *   device name comes with the sign-in flows' chunk, which is not in the
 *   initial bundle; until it is known `account` is undefined, and if that
 *   chunk cannot load the name falls back to "This browser".
 * - `shortcuts`: the registry's reference for this platform, built once.
 *
 * Framework-free; `SettingsPane.tsx` creates it with `useModel`.
 */

import type { UserRow } from "@inline/core-protocol"
import { signal, type ReadSignal } from "@inline/reactive"
import {
  buildShortcutReference,
  type CommandRegistry,
  type PaneId,
  type Platform,
  type SettingsPage,
  type ShortcutReference,
  type Workspace,
} from "@inline/view"

/** The settings view's account input (`SettingsAccount` from the settings feature). */
export type SettingsPaneAccount = {
  readonly me: ReadSignal<UserRow | undefined>
  readonly deviceName: string
  readonly signOut: () => void | Promise<unknown>
}

export type SettingsPaneOptions = {
  readonly workspace: Pick<Workspace, "openInPane">
  readonly paneId: PaneId
  readonly me: ReadSignal<UserRow | undefined>
  readonly signOut: () => Promise<unknown>
  /** This device's name; loads the sign-in flows' chunk. */
  readonly deviceName: () => Promise<string>
  readonly registry: CommandRegistry
  readonly platform: Platform
}

/** What the Account page says when the device's name could not be worked out. */
export const FALLBACK_DEVICE_NAME = "This browser"

export class SettingsPaneModel {
  readonly account: ReadSignal<SettingsPaneAccount | undefined>
  readonly shortcuts: ShortcutReference
  readonly #account = signal<SettingsPaneAccount | undefined>(undefined)
  readonly #options: SettingsPaneOptions
  #disposed = false

  constructor(options: SettingsPaneOptions) {
    this.#options = options
    this.account = { get: () => this.#account.get(), peek: () => this.#account.peek() }
    this.shortcuts = buildShortcutReference(options.registry, options.platform)
    const settle = (deviceName: string) => {
      if (this.#disposed) return
      this.#account.set({ me: options.me, deviceName, signOut: () => options.signOut() })
    }
    options.deviceName().then(settle, () => settle(FALLBACK_DEVICE_NAME))
  }

  /** `SettingsView`'s `onNavigate`: stable for the pane's life. */
  readonly openPage = (page: SettingsPage): void => {
    if (this.#disposed) return
    this.#options.workspace.openInPane(this.#options.paneId, { kind: "settings", page })
  }

  dispose(): void {
    this.#disposed = true
  }
}
