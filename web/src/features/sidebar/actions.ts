/**
 * Row actions for the context menu, as data. The caller supplies them (later
 * from the command registry); the sidebar only shows them. `basicActions`
 * builds the basic set of the feature map from handlers, shaped like the Mac
 * menu in `Collection/SidebarNativeRowView.swift`.
 */

import type { MenuEntry } from "@inline/ui"
import type { SidebarItem } from "@inline/view/features"

export type SidebarAction =
  | {
      readonly kind?: "action"
      /** Stable within one menu. */
      readonly id: string
      readonly label: string
      /** Hint shown at the trailing edge, e.g. "⌘⇧P". Matching keys is the registry's job. */
      readonly shortcut?: string
      /** `aria-keyshortcuts` for the hint ("Shift+Meta+P"); derived from `shortcut` when omitted. */
      readonly keyshortcuts?: string
      /** Default true. A disabled action shows dimmed and cannot be chosen. */
      readonly enabled?: boolean
      readonly destructive?: boolean
      readonly run: () => void
    }
  /** One choice of a set (the notification modes): drawn with a dot when `checked`. */
  | {
      readonly kind: "radio"
      readonly id: string
      readonly label: string
      readonly checked: boolean
      readonly enabled?: boolean
      readonly run: () => void
    }
  /** A submenu of actions (Notifications ▸ Default, All, Mentions, None). */
  | {
      readonly kind: "submenu"
      readonly id: string
      readonly label: string
      readonly enabled?: boolean
      readonly actions: readonly SidebarAction[]
    }
  | { readonly kind: "separator"; readonly id: string }

/** The actions for one item, read when its menu opens (and again if the item changes while open). */
export type SidebarActions = (item: SidebarItem) => readonly SidebarAction[]

/** Map actions to the kit's menu entries. Leading, trailing and doubled separators are dropped. */
export const toMenuEntries = (actions: readonly SidebarAction[]): MenuEntry[] => {
  const entries: MenuEntry[] = []
  for (const action of actions) {
    if (action.kind === "separator") {
      const previous = entries[entries.length - 1]
      if (previous && previous.type !== "separator") entries.push({ type: "separator", id: action.id })
      continue
    }
    if (action.kind === "radio") {
      entries.push({
        type: "radio",
        id: action.id,
        label: action.label,
        checked: action.checked,
        ...(action.enabled === false ? { disabled: true } : {}),
        onSelect: action.run,
      })
      continue
    }
    if (action.kind === "submenu") {
      const items = toMenuEntries(action.actions)
      if (items.length === 0) continue
      entries.push({
        type: "submenu",
        id: action.id,
        label: action.label,
        ...(action.enabled === false ? { disabled: true } : {}),
        items,
      })
      continue
    }
    entries.push({
      type: "item",
      id: action.id,
      label: action.label,
      ...(action.shortcut ? { shortcut: action.shortcut } : {}),
      ...(action.keyshortcuts ? { keyshortcuts: action.keyshortcuts } : {}),
      ...(action.enabled === false ? { disabled: true } : {}),
      ...(action.destructive ? { destructive: true } : {}),
      onSelect: action.run,
    })
  }
  while (entries[entries.length - 1]?.type === "separator") entries.pop()
  return entries
}

/** A chat's notification setting, as the contract's `setDialogNotifications` takes it. */
export type NotificationChoice = "default" | "all" | "mentions" | "none"
/** A thread's follow setting, as `setDialogFollow` takes it. */
export type FollowChoice = "relevance" | "following" | "unfollowed"

/** The Mac's notification options, in its order (`DialogNotificationSettingSelection`). */
export const NOTIFICATION_CHOICES: readonly { readonly mode: NotificationChoice; readonly label: string }[] = [
  { mode: "default", label: "Default" },
  { mode: "all", label: "All" },
  { mode: "mentions", label: "Mentions" },
  { mode: "none", label: "None" },
]

/** The item's notification choice: its own mode, else "default" (parent or account settings). */
export const notificationChoiceOf = (item: SidebarItem): NotificationChoice => item.notificationMode ?? "default"

/** Threads can be followed; direct messages cannot (the Mac shows Follow for threads only). */
export const canFollow = (item: SidebarItem): boolean => item.peerUserId === undefined

/**
 * The notification submenu and the follow toggle for one item (Mac: the
 * chat toolbar's Notifications popover, Default / All / Mentions / None, and
 * Follow Thread or Unfollow Thread for a thread). Each handler is optional;
 * nothing is listed without it.
 */
export const dialogSettingActions = (
  item: SidebarItem,
  handlers: {
    readonly setNotifications?: (item: SidebarItem, mode: NotificationChoice) => void
    readonly setFollow?: (item: SidebarItem, mode: FollowChoice) => void
  },
): SidebarAction[] => {
  const actions: SidebarAction[] = []
  const { setNotifications, setFollow } = handlers
  if (setNotifications) {
    const current = notificationChoiceOf(item)
    actions.push({
      kind: "submenu",
      id: "notifications",
      label: "Notifications",
      actions: NOTIFICATION_CHOICES.map((choice) => ({
        kind: "radio" as const,
        id: `notifications-${choice.mode}`,
        label: choice.label,
        checked: current === choice.mode,
        run: () => setNotifications(item, choice.mode),
      })),
    })
  }
  if (setFollow && canFollow(item)) {
    const following = item.followMode === "following"
    actions.push({
      id: "follow",
      label: following ? "Unfollow Thread" : "Follow Thread",
      run: () => setFollow(item, following ? "unfollowed" : "following"),
    })
  }
  return actions
}

/**
 * Handlers for the basic set. An action appears only when its handler is
 * given. `isTemporary` and `isArchived` stand in for facts `SidebarItem`
 * does not carry yet (the dialog's `open` and `archived`).
 */
export type BasicActionHandlers = {
  readonly togglePin?: (item: SidebarItem) => void
  readonly markRead?: (item: SidebarItem) => void
  readonly markUnread?: (item: SidebarItem) => void
  readonly toggleArchive?: (item: SidebarItem) => void
  /** Close from Sidebar. */
  readonly close?: (item: SidebarItem) => void
  /** Keep in Sidebar, for a temporary row. */
  readonly keep?: (item: SidebarItem) => void
  readonly copyLink?: (item: SidebarItem) => void
  /** The row is shown only because it is selected (rule 7). TODO(contract): `SidebarItem.open`. */
  readonly isTemporary?: (item: SidebarItem) => boolean
  /** TODO(contract): `SidebarItem.archived`. */
  readonly isArchived?: (item: SidebarItem) => boolean
  /** `setDialogNotifications`: the Notifications submenu. */
  readonly setNotifications?: (item: SidebarItem, mode: NotificationChoice) => void
  /** `setDialogFollow`: Follow Thread or Unfollow Thread (threads only). */
  readonly setFollow?: (item: SidebarItem, mode: FollowChoice) => void
}

const separator = (id: string): SidebarAction => ({ kind: "separator", id })

/**
 * Pin, mark read or unread, close or keep in sidebar, archive; then
 * Notifications and Follow Thread; then copy link: the Mac's basic menu,
 * with the chat toolbar's notification and follow settings after it.
 */
export const basicActions = (item: SidebarItem, handlers: BasicActionHandlers): SidebarAction[] => {
  const actions: SidebarAction[] = []
  const temporary = handlers.isTemporary?.(item) ?? false
  if (temporary) {
    if (handlers.close) actions.push({ id: "close", label: "Close from Sidebar", run: () => handlers.close?.(item) })
    actions.push(separator("temporary"))
    if (handlers.keep) actions.push({ id: "keep", label: "Keep in Sidebar", run: () => handlers.keep?.(item) })
  } else {
    if (handlers.togglePin) {
      actions.push({ id: "pin", label: item.pinned ? "Unpin" : "Pin", run: () => handlers.togglePin?.(item) })
    }
    if (item.hasUnread && handlers.markRead) {
      actions.push({ id: "read", label: "Mark Read", run: () => handlers.markRead?.(item) })
    } else if (!item.hasUnread && handlers.markUnread) {
      actions.push({ id: "read", label: "Mark Unread", run: () => handlers.markUnread?.(item) })
    }
    if (handlers.close) actions.push({ id: "close", label: "Close from Sidebar", run: () => handlers.close?.(item) })
    if (handlers.toggleArchive) {
      const archived = handlers.isArchived?.(item) ?? false
      actions.push({ id: "archive", label: archived ? "Unarchive" : "Archive", run: () => handlers.toggleArchive?.(item) })
    }
  }
  const settings = temporary ? [] : dialogSettingActions(item, handlers)
  if (settings.length > 0) {
    actions.push(separator("settings"))
    actions.push(...settings)
  }
  if (handlers.copyLink) {
    actions.push(separator("link"))
    actions.push({ id: "copyLink", label: "Copy Link", run: () => handlers.copyLink?.(item) })
  }
  return actions
}
