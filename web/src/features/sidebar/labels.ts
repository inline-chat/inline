/**
 * Strings the sidebar shows or announces. English for now and kept out of
 * the views, so a translation layer can replace this file.
 */

import type { SidebarItem, SidebarMode } from "@inline/view/features"

/** Counts above 99 show as "99+" (Mac `SidebarUnreadBelowButton`, badges). */
export const badgeText = (count: number): string => (count > 99 ? "99+" : String(count))

export const DRAFT_LABEL = "Draft:"

export const modeLabels: Record<SidebarMode, string> = {
  inbox: "Inbox",
  all: "All chats",
  archived: "Archived",
}

/** The modes the switch offers, in order. */
export const switchModes: readonly SidebarMode[] = ["inbox", "all"]

/**
 * The row's accessible name: everything the row shows, in reading order,
 * so a screen reader hears the unread state and the draft without visiting
 * the badge.
 */
export const rowLabel = (item: SidebarItem, activity?: string): string => {
  const parts = [item.title]
  if (item.pinned) parts.push("pinned")
  if (item.unreadCount > 0) parts.push(`${badgeText(item.unreadCount)} unread`)
  else if (item.unreadMark) parts.push("marked unread")
  const preview = item.preview
  // What the preview line shows: someone composing replaces the preview, as on screen.
  if (activity) parts.push(activity)
  else if (preview.kind === "draft") parts.push(`${DRAFT_LABEL} ${preview.text}`)
  else if (preview.kind === "message" && preview.text) parts.push(preview.outgoing ? `You: ${preview.text}` : preview.text)
  return parts.join(", ")
}

export const unreadBelowLabel = "Jump to unread chats below"

export const unreadBelowValue = (count: number): string => `${badgeText(count)} unread ${count === 1 ? "chat" : "chats"} below`

export type EmptyText = { readonly title: string; readonly body: string }

export const emptyText = (mode: SidebarMode): EmptyText => {
  switch (mode) {
    case "inbox":
      return { title: "No open chats", body: "Chats you open or pin stay here." }
    case "archived":
      return { title: "No archived chats", body: "Archived chats appear here." }
    default:
      return { title: "No chats yet", body: "Start a chat and it appears here." }
  }
}

export const LOADING_LABEL = "Loading chats"
export const LIST_LABEL = "Chats"
