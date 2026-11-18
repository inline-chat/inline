/** The settings view's inputs. The shell builds these once per signed-in session; see README.md. */

import type { UserRow } from "@inline/core-protocol"
import type { Platform } from "@inline/platform"
import type { ReadSignal } from "@inline/reactive"
import type { Clock } from "@inline/ui"
import type { AppearanceController } from "@inline/ui/theme"
import type { SettingsPage, ShortcutReference } from "@inline/view"
import type { PermissionPrompt } from "../notifications"
import type { PreferencesStore } from "./preferences"

/** The signed-in account, as much as the Account page needs. */
export type SettingsAccount = {
  /** `session.me`. Undefined until the core answers. */
  readonly me: ReadSignal<UserRow | undefined>
  /** This device's name, from `createDeviceFacts(...).deviceName` ("Chrome on macOS"). */
  readonly deviceName: string
  /** `app.signOut()`. Called after the user confirms. */
  readonly signOut: () => void | Promise<unknown>
}

export type SettingsViewProps = {
  /** The destination's page: `destination.page` of `{ kind: "settings" }`; undefined for `/settings`. */
  readonly page: SettingsPage | undefined
  /** Show another page in this pane. Keep it stable for the view's life (a new function rebuilds the view's model). */
  readonly onNavigate: (page: SettingsPage) => void
  /** The document's controller from `startDocumentAppearance()`. */
  readonly appearance: AppearanceController
  readonly platform: Platform
  readonly preferences: PreferencesStore
  /** Without it the Account page is not listed. */
  readonly account?: SettingsAccount
  /** Unsent messages the core holds, for the sign-out warning. Default 0. */
  readonly pendingCount?: number
  /** `buildShortcutReference(app.registry, platform)` for this platform. */
  readonly shortcuts: ShortcutReference
  /** The notifications feature's prompt (`notifications.prompt`); without it one is made from `platform.notifications`. */
  readonly notificationPrompt?: PermissionPrompt
  /** The build ID to show on About. */
  readonly buildId: string
  /** Clears the media cache. Without it the button is disabled with the reason. */
  readonly onClearCachedMedia?: () => Promise<void> | void
  /** For the search highlight. Default: the system clock. */
  readonly clock?: Clock
}

export const TERMS_URL = "https://inline.chat/legal/terms"
export const PRIVACY_URL = "https://inline.chat/legal/privacy"
