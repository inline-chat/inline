/**
 * The app services the views receive: created once at boot (`boot.ts`) and
 * passed down as one stable prop. Plain data and functions; no view code.
 */

import type { Platform, UpdateState } from "@inline/platform"
import type { ReadSignal } from "@inline/reactive"
import type { Clock as TimelineClock, FrameSource } from "@inline/timeline"
import type { AppearanceController } from "@inline/ui/theme"
import type { Destination } from "@inline/view"
import type { PermissionPrompt } from "../features/notifications"
import type { PreferencesStore } from "../features/settings/preferences"
import type { SignInScreen } from "../features/signin"
import type { AttachmentsChunk } from "../features/chat/attachments-chunk"
import type { ContentChunk } from "../features/chat/content-chunk"
import type { FindChunk } from "../features/chat/find-chunk"
import type { MediaViewerChunk } from "../features/chat/media-viewer-chunk"
import type { MentionsChunk } from "../features/chat/mentions-chunk"
import type { ChatInfoChunk } from "./chat-info-chunk"
import type { EmojiModules } from "./emoji-session"
import type { LayersChunk } from "./layers-chunk"
import type { QuickSearchChunk } from "./quick-search-chunk"
import type { AppRuntime } from "./runtime"
import type { SettingsChunk } from "./settings-chunk"
import type { Shell } from "./Shell"
import type { LazySignIn } from "./signin-loader"
import type { Loadable } from "./views"
import type { Warmup } from "./warmup"

/**
 * The view chunks. `signIn` and `shell` load for the gate's phase; the rest
 * are not needed for the signed-in shell's first paint and load after it
 * (`warmup`) or on first intent: `find` on the first Mod+F, `mentions` on
 * the first `@`, `attachments` on the first file, `chatInfo` when a pane
 * opens chat info, `mediaViewer` on the first photo or video opened.
 */
export type AppViews = {
  readonly signIn: Loadable<typeof SignInScreen>
  readonly shell: Loadable<typeof Shell>
  readonly quickSearch: Loadable<QuickSearchChunk>
  readonly settings: Loadable<SettingsChunk>
  readonly content: Loadable<ContentChunk>
  readonly find: Loadable<FindChunk>
  readonly mentions: Loadable<MentionsChunk>
  readonly attachments: Loadable<AttachmentsChunk>
  readonly chatInfo: Loadable<ChatInfoChunk>
  readonly mediaViewer: Loadable<MediaViewerChunk>
  /** The reaction picker and the confirmation alert (`MessageActions`). Warmed after the first paint. */
  readonly layers: Loadable<LayersChunk>
}

export type AppServices = {
  readonly runtime: AppRuntime<LazySignIn>
  readonly views: AppViews
  /** The document appearance controller (`startDocumentAppearance()`). */
  readonly appearance: AppearanceController
  readonly platform: Platform
  /** Device-wide preferences (send key, spell check, side pane, sounds, badge). */
  readonly preferences: PreferencesStore
  /** Loads queued until after the first paint. */
  readonly warmup: Warmup
  /** This device's name ("Chrome on macOS"), once the sign-in flows have loaded. */
  readonly deviceName: () => Promise<string>
  readonly buildId: string
  /** The platform's update state (the service worker's, on the web). */
  readonly update: ReadSignal<UpdateState>
  /** The "Turn on notifications" affordance while signed in (`attachNotifications(...).prompt`). */
  readonly notificationPrompt: ReadSignal<PermissionPrompt | undefined>
  /** The user chose to update: switch to the waiting build and reload. */
  readonly applyUpdate: () => void
  /** Reload this tab (outdated, superseded, retry after a failure). */
  readonly reload: () => void
  /** Copy the redacted diagnostics to the clipboard. Resolves to whether it worked. */
  readonly copyDiagnostics: () => Promise<boolean>
  /** Open an external link after the link allowlist. */
  readonly openExternal: (url: string) => void
  /** Write plain text to the clipboard. Resolves to whether it worked. */
  readonly copyText: (text: string) => Promise<boolean>
  /** An app link (`inline://`, `https://inline.chat/c/...`) to a destination, if Inline understands it. */
  readonly parseAppLink: (href: string) => Destination | undefined
  /** The link allowlist, as the composer wants it (normalized URL or null). */
  readonly safeUrl: (url: string) => string | null
  /** IANA time zone for day separators and times. */
  readonly timeZone: string
  readonly timelineClock: TimelineClock
  readonly frames: FrameSource
  /** Schedule work for the next frame (focus after a collapsed sidebar is shown). */
  readonly nextFrame: (fn: () => void) => void
  /** The sign-in code length the screen submits at (the server's codes are 6 digits). */
  readonly codeLength: number
  /** The emoji modules (`emoji`, `emojiPickers` in `view-chunks.ts`), for each session's `SessionEmoji`. */
  readonly emoji: EmojiModules
}
