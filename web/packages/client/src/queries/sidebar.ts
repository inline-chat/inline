/**
 * Sidebar membership and order, following the Mac app
 * (apple/InlineMac/Features/Sidebar/SidebarViewModel.swift and
 * InlineKit HomeList/ChatListDatabaseQuery.swift):
 *
 * - Hidden dialogs (`chatListHidden`) never show.
 * - `inbox`: not archived, and open or pinned. `all`: not archived.
 *   `archived`: archived only.
 * - With a space, the dialog's space (or its chat's) must match. Without one,
 *   every dialog shows (the Mac's "include space chats in home").
 * - Pinned first, ordered by `pinnedOrder` (present before absent, then
 *   lexical). Then `inbox` orders by `order` the same way (the Mac's default
 *   "opened order"), and `all` and `archived` by last activity, newest first.
 * - Every tie falls back to dialog ID, descending.
 */
import { compareInlineIds, type SpaceID } from "@inline/ids"
import type { Chat, Dialog } from "../database/models"

export type SidebarMode = "inbox" | "all" | "archived"

export type SidebarEntry = {
  dialog: Dialog
  chat: Chat | undefined
  /** Seconds since the epoch; 0 when unknown. */
  activity: number
}

export const sidebarIncludes = (
  entry: SidebarEntry,
  mode: SidebarMode,
  spaceId: SpaceID | undefined,
): boolean => {
  const { dialog, chat } = entry
  if (dialog.chatListHidden === true) return false
  if (spaceId != null && (dialog.spaceId ?? chat?.spaceId) !== spaceId) return false
  switch (mode) {
    case "inbox":
      return dialog.archived !== true && (dialog.open === true || dialog.pinned === true)
    case "all":
      return dialog.archived !== true
    case "archived":
      return dialog.archived === true
  }
}

const stableOrder = (left: SidebarEntry, right: SidebarEntry) =>
  compareInlineIds(right.dialog.id, left.dialog.id)

/** Present before absent; then lexical; then stable. */
const byOrderKey = (
  left: string | undefined,
  right: string | undefined,
  tie: () => number,
): number => {
  if (left != null && right != null) {
    if (left !== right) return left < right ? -1 : 1
    return tie()
  }
  if (left != null) return -1
  if (right != null) return 1
  return tie()
}

export const compareSidebarEntries =
  (mode: SidebarMode) =>
  (left: SidebarEntry, right: SidebarEntry): number => {
    const leftPinned = left.dialog.pinned === true
    const rightPinned = right.dialog.pinned === true
    if (leftPinned !== rightPinned) return leftPinned ? -1 : 1
    const tie = () => stableOrder(left, right)
    if (leftPinned) {
      return byOrderKey(left.dialog.pinnedOrder, right.dialog.pinnedOrder, tie)
    }
    if (mode === "inbox") {
      return byOrderKey(left.dialog.order, right.dialog.order, tie)
    }
    if (left.activity !== right.activity) return right.activity - left.activity
    return tie()
  }

export const sortSidebar = (
  entries: SidebarEntry[],
  mode: SidebarMode,
  spaceId: SpaceID | undefined,
): SidebarEntry[] =>
  entries
    .filter((entry) => sidebarIncludes(entry, mode, spaceId))
    .sort(compareSidebarEntries(mode))
