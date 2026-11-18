/**
 * Which view a pane shows for its destination. The view file
 * (`PaneContent.tsx`) maps each kind to a component; this file decides the
 * kind, so the mapping is tested without a view framework.
 *
 * Built today: `chat` (chat, message, thread: one chat pane, so switching
 * between them reuses the pane), `chatInfo` (its own chunk), `settings` and
 * `empty`. Every other destination gets
 * the `unbuilt` pane, which names the destination plainly and keeps
 * navigation (Back, the sidebar, the address bar) working.
 */

import { destinationChatId } from "@inline/view/features"
import { encodeDestination, type Destination, type DestinationKind } from "@inline/view"

export type PaneViewKind = "chat" | "chatInfo" | "settings" | "empty" | "unbuilt"

const chatKinds: ReadonlySet<DestinationKind> = new Set(["chat", "message", "thread"])

export const paneViewKind = (destination: Destination): PaneViewKind => {
  if (destination.kind === "empty") return "empty"
  if (destination.kind === "settings") return "settings"
  if (destination.kind === "chatInfo") return "chatInfo"
  if (chatKinds.has(destination.kind) && destinationChatId(destination) !== undefined) return "chat"
  return "unbuilt"
}

const destinationTitles: Record<DestinationKind, string> = {
  empty: "No chat selected",
  chat: "Chat",
  message: "Message",
  thread: "Thread",
  chatInfo: "Chat Info",
  user: "Profile",
  allChats: "All chats",
  archived: "Archived chats",
  newThread: "New thread",
  createSpace: "Create a space",
  space: "Space",
  settings: "Settings",
  search: "Search",
  signIn: "Sign in",
  joinSpace: "Join a space",
  invite: "Invitation",
}

/** A plain title for a destination, for the unbuilt pane and the window title. */
export const destinationTitle = (destination: Destination): string => destinationTitles[destination.kind]

/**
 * What the unbuilt pane shows about its destination. Invite tokens are
 * credentials, so the path of an invitation is not shown.
 */
export const destinationDescription = (destination: Destination): string => {
  if (destination.kind === "invite") return "/invite/…"
  return encodeDestination(destination)
}
