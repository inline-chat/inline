/**
 * Every code-split chunk the boot path knows by name, and which ones each
 * phase requests before its first paint.
 *
 * `boot.ts` builds its loaders from `chunkImporters` and loads
 * `firstPaint[phase]` when the gate enters a phase; `afterFirstPaint` is
 * queued on the warmup lane (`boot.ts` for the service worker, the boot
 * sweep and the notifications, `shell-warmup.ts` for the rest), in that
 * order. Chunks a feature loads through its own holder (the menu kit, the
 * composer's autocomplete, paste and attachment strip) are named here with
 * the holder's specifier, so both are one chunk; the holder is what the
 * warm-up and first use call (`shell-warmup.ts`, `chat-attachments.ts`). The bundle measurement
 * (`tooling/measure-initial-js.ts`, `bun run size`) reads this same file to
 * decide what counts as the initial set, so the number follows the code.
 *
 * Keep each importer one literal `name: () => import("...")` on its own
 * line: the measurement parses them to find each chunk in the build.
 */

export const chunkImporters = {
  shell: () => import("./Shell"),
  signIn: () => import("../features/signin"),
  authFlows: () => import("@inline/auth/flows"),
  serviceWorker: () => import("../sw/register"),
  storageSweep: () => import("../core/account-storage-sweep"),
  notifications: () => import("./notifications-chunk"),
  layers: () => import("./layers-chunk"),
  emoji: () => import("../features/emoji"),
  emojiPickers: () => import("../features/emoji/chunk"),
  content: () => import("../features/chat/content-chunk"),
  quickSearch: () => import("./quick-search-chunk"),
  settings: () => import("./settings-chunk"),
  find: () => import("../features/chat/find-chunk"),
  mentions: () => import("../features/chat/mentions-chunk"),
  attachments: () => import("../features/chat/attachments-chunk"),
  chatInfo: () => import("./chat-info-chunk"),
  mediaViewer: () => import("../features/chat/media-viewer-chunk"),
  menus: () => import("@inline/ui/menu-kit"),
  composerPaste: () => import("@inline/composer/paste"),
  composerAutocomplete: () => import("../features/composer/autocomplete-chunk"),
  attachmentStrip: () => import("../features/composer/AttachmentStripView"),
}

export type ChunkName = keyof typeof chunkImporters

/** Requested when the gate enters the phase, before its first paint. */
export const firstPaint = {
  signedIn: ["shell"],
  signedOut: ["signIn", "authFlows"],
} as const satisfies Record<"signedIn" | "signedOut", readonly ChunkName[]>

/**
 * Loaded right after the first paint: `content` at once (a frame and a task
 * after it: the rows on screen wait for it), the rest on the idle lane in
 * this order (`warmup.ts`): `boot.ts` queues the first three
 * (`bootWarmed`), the shell the others (`shell-warmup.ts`, which holds the
 * loader each one is warmed through). The emoji table is warmed last by the
 * shell too, through the emoji services' own `import()` (not a chunk here).
 */
export const afterFirstPaint = [
  "content",
  "serviceWorker",
  "storageSweep",
  "notifications",
  "layers",
  "menus",
  "composerAutocomplete",
  "composerPaste",
  "emoji",
  "emojiPickers",
  "quickSearch",
  "settings",
] as const satisfies readonly ChunkName[]

/** The after-paint names `boot.ts` queues itself (before any shell exists). */
export const bootWarmed = ["serviceWorker", "storageSweep", "notifications"] as const satisfies readonly ChunkName[]
