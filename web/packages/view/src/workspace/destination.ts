/**
 * Destinations: everything a pane can show, as plain data.
 *
 * A destination says "where", never "how": which pane, tab or window it opens
 * in is an open intent (see `workspace.ts`). The set follows the Mac app's
 * `Nav3Route` (apple/InlineMac/Features/Navigation/Nav3.swift) plus the
 * destinations only the web needs (sign-in, search, join links).
 */

import type { ChatID, MessageID, SpaceID, UserID } from "@inline/ids"

/** Tabs of the chat info page. Mirrors `Nav3Route.ChatInfoQuery`. */
export const chatInfoTabs = ["files", "media", "voice", "links", "participants"] as const
export type ChatInfoTab = (typeof chatInfoTabs)[number]

/** Space pages. Mirrors `members`, `spaceSettings`, `spaceIntegrations`, `grid`. */
export const spacePages = ["members", "settings", "integrations", "grid"] as const
export type SpacePage = (typeof spacePages)[number]

/**
 * Settings pages. Mirrors `SettingsCategory` in the Mac app, with URL-friendly
 * names (`activeSessions` is `sessions`, `dataStorage` is `data`,
 * `audioAndVideo` is `audio-video`).
 */
export const settingsPages = [
  "account",
  "sessions",
  "audio-video",
  "bots",
  "connectors",
  "data",
  "general",
  "hotkeys",
  "updates",
  "appearance",
  "notifications",
  "privacy",
  "experimental",
  "debug",
] as const
export type SettingsPage = (typeof settingsPages)[number]

export type Destination =
  /** Nothing selected: the home state of a pane. */
  | { readonly kind: "empty" }
  | { readonly kind: "chat"; readonly chatId: ChatID }
  /** A chat opened at one message (a link to a message, a search hit). */
  | { readonly kind: "message"; readonly chatId: ChatID; readonly messageId: MessageID }
  /**
   * A reply thread of a parent chat. A reply thread is itself a chat; this
   * destination also names the parent so a view can show it beside the
   * thread or offer a way back to it. Opened alone, `chat` with the thread's
   * ID is equally valid.
   */
  | { readonly kind: "thread"; readonly parentChatId: ChatID; readonly threadId: ChatID }
  | { readonly kind: "chatInfo"; readonly chatId: ChatID; readonly tab?: ChatInfoTab }
  | { readonly kind: "user"; readonly userId: UserID }
  | { readonly kind: "allChats" }
  | { readonly kind: "archived" }
  /** The new-thread composer, optionally inside a space. */
  | { readonly kind: "newThread"; readonly spaceId?: SpaceID }
  | { readonly kind: "createSpace" }
  | { readonly kind: "space"; readonly spaceId: SpaceID; readonly page: SpacePage }
  | { readonly kind: "settings"; readonly page?: SettingsPage }
  | { readonly kind: "search"; readonly query?: string }
  /** Sign-in; `next` is where to go afterwards. Never another sign-in. */
  | { readonly kind: "signIn"; readonly next?: Destination }
  /** Join a public space by handle (`/s/<handle>`). Transient. */
  | { readonly kind: "joinSpace"; readonly handle: string }
  /** Accept a space invitation (`/invite/<token>`). Transient; the token is a credential. */
  | { readonly kind: "invite"; readonly token: string }

export type DestinationKind = Destination["kind"]

export type DestinationOf<K extends DestinationKind> = Extract<Destination, { kind: K }>

export const emptyDestination: DestinationOf<"empty"> = Object.freeze({ kind: "empty" })

/**
 * Destinations that are flows rather than places. They are not written into a
 * persisted workspace (a reload does not resume an invite), matching the Mac
 * app, which drops invite flows from its saved route state.
 */
export const isTransientDestination = (destination: Destination): boolean =>
  destination.kind === "joinSpace" || destination.kind === "invite" || destination.kind === "signIn"

/** The chat a destination shows, if any. A thread shows the thread chat. */
export const destinationChatId = (destination: Destination): ChatID | undefined => {
  switch (destination.kind) {
    case "chat":
    case "message":
    case "chatInfo":
      return destination.chatId
    case "thread":
      return destination.threadId
    default:
      return undefined
  }
}

/** The space a destination belongs to, if it names one. */
export const destinationSpaceId = (destination: Destination): SpaceID | undefined => {
  switch (destination.kind) {
    case "space":
      return destination.spaceId
    case "newThread":
      return destination.spaceId
    default:
      return undefined
  }
}

// Validation shared with the Apple parser (InlineDeepLink.swift).

const handlePattern = /^[A-Za-z0-9][A-Za-z0-9_-]{1,63}$/
const inviteTokenPattern = /^iv1_[A-Za-z0-9_-]{43}$/

/** 2 to 64 ASCII letters, digits, `_` or `-`, starting with a letter or digit. */
export const isValidSpaceHandle = (value: string): boolean => handlePattern.test(value)

/** `iv1_` followed by 43 URL-safe characters; 47 in all. Opaque otherwise. */
export const isValidInviteToken = (value: string): boolean => inviteTokenPattern.test(value)

export const isChatInfoTab = (value: string): value is ChatInfoTab =>
  (chatInfoTabs as readonly string[]).includes(value)

export const isSpacePage = (value: string): value is SpacePage =>
  (spacePages as readonly string[]).includes(value)

export const isSettingsPage = (value: string): value is SettingsPage =>
  (settingsPages as readonly string[]).includes(value)
