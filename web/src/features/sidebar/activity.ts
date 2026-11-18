/**
 * Compose activity on sidebar rows (Mac `SidebarNativeComposeActivityView`):
 * while someone types, records or sends in a chat, its row's preview line
 * shows the activity in the accent color after an animated indicator; a
 * compact row (no preview line) shows the indicator alone after the title.
 *
 * The source is the caller's: `typingFor(item)` returns a signal of the
 * chat's activity, or undefined. The typing feature's
 * `createComposeActivityIndex(...).forChat(item.chatId)` fits as is.
 */

import type { ReadSignal } from "@inline/reactive"
import type { SidebarItem } from "@inline/view/features"

/** Structurally the typing feature's `ComposeStatus` (short wording). */
export type SidebarActivityStatus = {
  readonly kind: "typing" | "working" | "recording" | "sending"
  readonly text: string
}

/** Structurally the typing feature's `RowActivity`. */
export type SidebarActivity = { readonly status?: SidebarActivityStatus }

/** The activity signal for an item's chat, or undefined for none. Read when a row first shows the item. */
export type SidebarTypingSource = (item: SidebarItem) => ReadSignal<SidebarActivity | undefined> | undefined

export const sameActivityStatus = (a: SidebarActivityStatus | undefined, b: SidebarActivityStatus | undefined): boolean =>
  a === b || (a !== undefined && b !== undefined && a.kind === b.kind && a.text === b.text)
