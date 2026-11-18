/**
 * Where each session status is shown. One status at a time comes from the
 * session (`sessionStatus` in `@inline/view/features`, most important
 * first); this maps it onto a surface:
 *
 * - `screen`: replaces the pane area (the data cannot be used): outdated,
 *   superseded, failed, signed out by the core, and signing out (the core
 *   reports `signingOut` while it erases: nothing in the shell may act).
 * - `banner`: a quiet strip above the panes: storage not kept, storage full.
 * - `header`: the chat header's subtitle (rule 15), never a banner:
 *   connecting, updating, waiting for network.
 * - `starting`: the shell renders as usual; the sidebar says it is starting.
 * - `none`: ready.
 */

import type { SessionStatus } from "@inline/view/features"

export type StatusScreenKind = "outdated" | "superseded" | "failed" | "signedOut" | "signingOut"
export type StatusBannerKind = "storageNotKept" | "storageFull"

export type StatusSurface =
  | { readonly kind: "screen"; readonly screen: StatusScreenKind }
  | { readonly kind: "banner"; readonly banner: StatusBannerKind }
  | { readonly kind: "header" }
  | { readonly kind: "starting" }
  | { readonly kind: "none" }

export const statusSurface = (status: SessionStatus, core?: { readonly signingOut?: true } | undefined): StatusSurface => {
  // The core refuses every intent from here on and is erasing the account: no interactive shell.
  if (core?.signingOut) return { kind: "screen", screen: "signingOut" }
  switch (status) {
    case "outdated":
    case "superseded":
    case "failed":
    case "signedOut":
      return { kind: "screen", screen: status }
    case "storageNotKept":
    case "storageFull":
      return { kind: "banner", banner: status }
    case "connecting":
    case "updating":
    case "waitingForNetwork":
      return { kind: "header" }
    case "starting":
      return { kind: "starting" }
    case "ready":
      return { kind: "none" }
  }
}

/** Words for each full-window status screen. A screen without `action` has no button (it ends by itself). */
export const statusScreenText: Record<StatusScreenKind, { title: string; body: string; action?: string }> = {
  outdated: {
    title: "Inline was updated",
    body: "The data on this device was written by a newer version of Inline. Reload to continue with it.",
    action: "Reload",
  },
  superseded: {
    title: "Inline was updated in another tab",
    body: "A newer version of Inline is running in another tab. Reload this tab to use it.",
    action: "Reload",
  },
  failed: {
    title: "Inline couldn't start",
    body: "Something stopped Inline from opening its data on this device. Try again, and if it keeps happening, copy the diagnostics and send them to us.",
    action: "Try Again",
  },
  signedOut: {
    title: "Signing out",
    body: "This session has ended.",
    action: "Reload",
  },
  signingOut: {
    title: "Signing out…",
    body: "Removing this account's messages and files from this device.",
  },
}

/**
 * Said on the sign-in screen when the last sign-out could not confirm the
 * erase (`AccountSession.end` resolved `eraseFailed` or `timedOut`). The boot
 * sweep and the account's next start remove what is left.
 */
export const eraseIncompleteText = {
  title: "Some data from your last session may still be on this device.",
  body: "It will be removed the next time Inline starts.",
} as const

/** Words for each banner. */
export const statusBannerText: Record<StatusBannerKind, string> = {
  storageNotKept: "Messages aren't being kept on this device. They will load again next time.",
  storageFull: "Storage on this device is full. New messages can't be saved until space is freed.",
}

/** The composer's note while storage is full (the composer keeps any rejected text). */
export const storageFullComposerNote = "Storage is full: messages can't be sent until space is freed."

/** Words for the connection states shown in the chat header (rule 15). */
export const connectionText = {
  connecting: "Connecting…",
  updating: "Updating…",
  waitingForNetwork: "Waiting for network…",
} as const
