/**
 * URL codec for destinations.
 *
 * App paths (`app.inline.chat`) are short and stable, and reuse the public
 * `inline.chat` forms where they exist (`/c/<id>`, `/s/<handle>`,
 * `/invite/<token>`), so swapping the host of a shared link opens the same
 * destination in the app. The URL carries only the shareable destination,
 * never pane layout or view state.
 *
 * Decoding never throws. Unknown or malformed input decodes to the empty
 * destination with a reason.
 */

import { parseInlineId, type ChatID, type MessageID, type SpaceID, type UserID } from "@inline/ids"
import {
  emptyDestination,
  isChatInfoTab,
  isSettingsPage,
  isSpacePage,
  isValidInviteToken,
  isValidSpaceHandle,
  type Destination,
  type DestinationOf,
} from "./destination"

// MARK: - Encoding

const seg = encodeURIComponent

/** The canonical app path (with query) for a destination. Always starts with `/`. */
export const encodeDestination = (destination: Destination): string => {
  switch (destination.kind) {
    case "empty":
      return "/"
    case "chat":
      return `/c/${destination.chatId}`
    case "message":
      return `/c/${destination.chatId}/m/${destination.messageId}`
    case "thread":
      return `/c/${destination.parentChatId}/t/${destination.threadId}`
    case "chatInfo":
      return destination.tab ? `/c/${destination.chatId}/info/${destination.tab}` : `/c/${destination.chatId}/info`
    case "user":
      return `/u/${destination.userId}`
    case "allChats":
      return "/chats"
    case "archived":
      return "/archived"
    case "newThread":
      return destination.spaceId ? `/space/${destination.spaceId}/new` : "/new"
    case "createSpace":
      return "/space/new"
    case "space":
      return `/space/${destination.spaceId}/${destination.page}`
    case "settings":
      return destination.page ? `/settings/${destination.page}` : "/settings"
    case "search":
      return destination.query ? `/search?${new URLSearchParams({ q: destination.query }).toString()}` : "/search"
    case "signIn":
      return destination.next && destination.next.kind !== "signIn" && destination.next.kind !== "empty"
        ? `/sign-in?${new URLSearchParams({ next: encodeDestination(destination.next) }).toString()}`
        : "/sign-in"
    case "joinSpace":
      return `/s/${seg(destination.handle)}`
    case "invite":
      return `/invite/${seg(destination.token)}`
  }
}

/** A stable string key for a destination; equal keys mean equal destinations. */
export const destinationKey = (destination: Destination): string => encodeDestination(destination)

export const sameDestination = (a: Destination, b: Destination): boolean =>
  a === b || destinationKey(a) === destinationKey(b)

// MARK: - Decoding app paths

export type DecodeFailure = "unknown" | "malformed"

export type DecodeResult =
  | { readonly ok: true; readonly destination: Destination }
  | { readonly ok: false; readonly destination: DestinationOf<"empty">; readonly reason: DecodeFailure }

const fail = (reason: DecodeFailure): DecodeResult => ({ ok: false, destination: emptyDestination, reason })
const ok = (destination: Destination): DecodeResult => ({ ok: true, destination })

const positiveId = <T>(value: string | undefined): T | undefined =>
  value === undefined ? undefined : (parseInlineId(value, { positive: true }) as T | undefined)

type SplitPath = { segments: string[]; query: URLSearchParams } | undefined

const splitPath = (input: string): SplitPath => {
  if (typeof input !== "string") return undefined
  const hashAt = input.indexOf("#")
  const withoutHash = hashAt >= 0 ? input.slice(0, hashAt) : input
  const queryAt = withoutHash.indexOf("?")
  const path = queryAt >= 0 ? withoutHash.slice(0, queryAt) : withoutHash
  const search = queryAt >= 0 ? withoutHash.slice(queryAt + 1) : ""
  if (!path.startsWith("/") || path.startsWith("//")) return undefined
  try {
    const segments = path
      .split("/")
      .filter((part) => part.length > 0)
      .map((part) => decodeURIComponent(part))
    return { segments, query: new URLSearchParams(search) }
  } catch {
    return undefined
  }
}

const decodeChatPath = (rest: readonly string[]): DecodeResult => {
  const chatId = positiveId<ChatID>(rest[0])
  if (!chatId) return fail("malformed")
  if (rest.length === 1) return ok({ kind: "chat", chatId })
  const sub = rest[1]?.toLowerCase()
  if ((sub === "m" || sub === "message") && rest.length === 3) {
    const messageId = positiveId<MessageID>(rest[2])
    return messageId ? ok({ kind: "message", chatId, messageId }) : fail("malformed")
  }
  if (sub === "t" && rest.length === 3) {
    const threadId = positiveId<ChatID>(rest[2])
    return threadId ? ok({ kind: "thread", parentChatId: chatId, threadId }) : fail("malformed")
  }
  if (sub === "info" && rest.length <= 3) {
    if (rest.length === 2) return ok({ kind: "chatInfo", chatId })
    const tab = rest[2]?.toLowerCase() ?? ""
    return isChatInfoTab(tab) ? ok({ kind: "chatInfo", chatId, tab }) : ok({ kind: "chatInfo", chatId })
  }
  return fail("unknown")
}

const decodeSpacePath = (rest: readonly string[]): DecodeResult => {
  if (rest.length === 1 && rest[0]?.toLowerCase() === "new") return ok({ kind: "createSpace" })
  if (rest.length !== 2) return fail("unknown")
  const spaceId = positiveId<SpaceID>(rest[0])
  if (!spaceId) return fail("malformed")
  const page = rest[1]?.toLowerCase() ?? ""
  if (page === "new") return ok({ kind: "newThread", spaceId })
  return isSpacePage(page) ? ok({ kind: "space", spaceId, page }) : fail("unknown")
}

const decodeNext = (value: string | null): Destination | undefined => {
  if (!value) return undefined
  const result = decodeSegments(splitPath(value))
  if (!result.ok) return undefined
  const next = result.destination
  return next.kind === "signIn" || next.kind === "empty" ? undefined : next
}

const decodeSegments = (split: SplitPath): DecodeResult => {
  if (!split) return fail("malformed")
  const { segments, query } = split
  const [head, ...rest] = segments
  if (head === undefined) return ok(emptyDestination)
  switch (head.toLowerCase()) {
    case "c":
      return decodeChatPath(rest)
    case "u": {
      if (rest.length !== 1) return fail("unknown")
      const userId = positiveId<UserID>(rest[0])
      return userId ? ok({ kind: "user", userId }) : fail("malformed")
    }
    case "chats":
      return rest.length === 0 ? ok({ kind: "allChats" }) : fail("unknown")
    case "archived":
      return rest.length === 0 ? ok({ kind: "archived" }) : fail("unknown")
    case "new":
      return rest.length === 0 ? ok({ kind: "newThread" }) : fail("unknown")
    case "space":
      return decodeSpacePath(rest)
    case "settings": {
      if (rest.length === 0) return ok({ kind: "settings" })
      const page = rest[0]?.toLowerCase() ?? ""
      // An unknown page still lands in settings rather than nowhere.
      return rest.length === 1 && isSettingsPage(page) ? ok({ kind: "settings", page }) : ok({ kind: "settings" })
    }
    case "search": {
      if (rest.length !== 0) return fail("unknown")
      const q = query.get("q")
      return ok(q ? { kind: "search", query: q } : { kind: "search" })
    }
    case "sign-in": {
      if (rest.length !== 0) return fail("unknown")
      const next = decodeNext(query.get("next"))
      return ok(next ? { kind: "signIn", next } : { kind: "signIn" })
    }
    case "s": {
      if (rest.length !== 1) return fail("unknown")
      const raw = rest[0] ?? ""
      const handle = raw.startsWith("@") ? raw.slice(1) : raw
      return isValidSpaceHandle(handle) ? ok({ kind: "joinSpace", handle }) : fail("malformed")
    }
    case "invite": {
      if (rest.length !== 1) return fail("unknown")
      const token = rest[0] ?? ""
      return isValidInviteToken(token) ? ok({ kind: "invite", token }) : fail("malformed")
    }
    default:
      return fail("unknown")
  }
}

/**
 * Decode an app path such as `/c/123/m/456` or `/search?q=hi`. Accepts a
 * trailing slash, a hash (ignored) and the `/c/<id>/message/<id>` alias.
 * Never throws.
 */
export const decodeAppPath = (pathWithQuery: string): DecodeResult => decodeSegments(splitPath(pathWithQuery))

// MARK: - Links from anywhere

/** Schemes the Apple clients read (`InlineDeepLink.productionSchemes`). */
export const deepLinkSchemes: readonly string[] = ["inline", "in"]

export type ParseLinkOptions = {
  /** Origins whose paths are app paths. Defaults to `https://app.inline.chat`. */
  readonly appOrigins?: readonly string[]
  /** Extra `inline://`-style schemes, such as a development build's. */
  readonly extraSchemes?: readonly string[]
}

const defaultAppOrigins = ["https://app.inline.chat"]
const publicHost = "inline.chat"

const queryId = <T>(query: URLSearchParams, names: readonly string[]): T | undefined => {
  const lowered = new Map<string, string>()
  for (const [key, value] of query) {
    const lower = key.toLowerCase()
    if (!lowered.has(lower)) lowered.set(lower, value)
  }
  for (const name of names) {
    const id = positiveId<T>(lowered.get(name.toLowerCase()))
    if (id) return id
  }
  return undefined
}

/** `inline://user/<id>`, `inline://chat/<id>[/message/<id>]`, `inline://join/{public,invite}/<x>`. */
const parseDeepLink = (url: URL): Destination | undefined => {
  const host = url.host.toLowerCase()
  let parts: string[]
  try {
    parts = url.pathname
      .split("/")
      .filter((part) => part.length > 0)
      .map((part) => decodeURIComponent(part))
  } catch {
    return undefined
  }
  const query = url.searchParams
  switch (host) {
    case "user": {
      if (parts.length > 1) return undefined
      const userId = positiveId<UserID>(parts[0]) ?? queryId<UserID>(query, ["id", "user_id", "userId"])
      return userId ? { kind: "user", userId } : undefined
    }
    case "chat":
    case "thread": {
      const chatId =
        positiveId<ChatID>(parts[0]) ?? queryId<ChatID>(query, ["id", "chat_id", "chatId", "thread_id", "threadId"])
      if (!chatId) return undefined
      if (parts.length === 3 && parts[1]?.toLowerCase() === "message") {
        const messageId = positiveId<MessageID>(parts[2])
        return messageId ? { kind: "message", chatId, messageId } : undefined
      }
      if (parts.length > 1) return undefined
      const messageId = queryId<MessageID>(query, ["message_id", "messageId"])
      return messageId ? { kind: "message", chatId, messageId } : { kind: "chat", chatId }
    }
    case "join": {
      if (parts.length !== 2) return undefined
      const value = parts[1] ?? ""
      switch (parts[0]?.toLowerCase()) {
        case "public":
          return isValidSpaceHandle(value) ? { kind: "joinSpace", handle: value } : undefined
        case "invite":
          return isValidInviteToken(value) ? { kind: "invite", token: value } : undefined
        default:
          return undefined
      }
    }
    default:
      return undefined
  }
}

/** The public forms the server and the Apple clients produce on `inline.chat`. */
const parsePublicLink = (url: URL): Destination | undefined => {
  const result = decodeAppPath(url.pathname)
  if (!result.ok) return undefined
  const kind = result.destination.kind
  return kind === "chat" || kind === "joinSpace" || kind === "invite" ? result.destination : undefined
}

/**
 * Parse any link Inline understands into a destination: an app path
 * (`/c/1`), an app URL, a public `https://inline.chat/...` link, or an
 * `inline://` deep link. Returns `undefined` for anything else, including
 * links to other sites. Never throws.
 */
export const parseLink = (href: string, options: ParseLinkOptions = {}): Destination | undefined => {
  if (typeof href !== "string") return undefined
  const trimmed = href.trim()
  if (trimmed.startsWith("/") && !trimmed.startsWith("//")) {
    const result = decodeAppPath(trimmed)
    return result.ok ? result.destination : undefined
  }
  let url: URL
  try {
    url = new URL(trimmed)
  } catch {
    return undefined
  }
  const scheme = url.protocol.slice(0, -1).toLowerCase()
  const schemes = [...deepLinkSchemes, ...(options.extraSchemes ?? [])].map((s) => s.toLowerCase())
  if (schemes.includes(scheme)) return parseDeepLink(url)
  if (scheme !== "https" && scheme !== "http") return undefined
  const appOrigins = options.appOrigins ?? defaultAppOrigins
  if (appOrigins.includes(url.origin)) {
    const result = decodeAppPath(`${url.pathname}${url.search}`)
    return result.ok ? result.destination : undefined
  }
  if (scheme === "https" && url.hostname.toLowerCase() === publicHost && url.port === "") return parsePublicLink(url)
  return undefined
}

/** An `inline://` link for destinations the Apple clients can open, else `undefined`. */
export const toDeepLink = (destination: Destination, scheme = "inline"): string | undefined => {
  switch (destination.kind) {
    case "user":
      return `${scheme}://user/${destination.userId}`
    case "chat":
      return `${scheme}://chat/${destination.chatId}`
    case "thread":
      return `${scheme}://chat/${destination.threadId}`
    case "message":
      return `${scheme}://chat/${destination.chatId}/message/${destination.messageId}`
    case "joinSpace":
      return `${scheme}://join/public/${destination.handle}`
    case "invite":
      return `${scheme}://join/invite/${destination.token}`
    default:
      return undefined
  }
}

/** The public `https://inline.chat/...` link, for the destinations that have one. */
export const toPublicLink = (destination: Destination): string | undefined => {
  switch (destination.kind) {
    case "chat":
      return `https://${publicHost}/c/${destination.chatId}`
    case "thread":
      return `https://${publicHost}/c/${destination.threadId}`
    case "joinSpace":
      return `https://${publicHost}/s/${destination.handle}`
    case "invite":
      return `https://${publicHost}/invite/${destination.token}`
    default:
      return undefined
  }
}

/** The absolute app URL for a destination. */
export const toAppUrl = (destination: Destination, origin = "https://app.inline.chat"): string =>
  `${origin}${encodeDestination(destination)}`
