/**
 * Contract additions of 17 November (host-data): membership and settings
 * rows, media, attachments, compose activity and local message search.
 *
 * All additive and optional: older consumers ignore the new row kinds,
 * queries, resources and intents. Plain, structured-cloneable data; the one
 * object that is not a plain record is a `Blob` in a `MediaResource`, which
 * structured clone carries as a handle (see `MediaResource.blob`).
 */

import type { ChatID, MessageID, SpaceID, UserID } from "@inline/ids"
import type { Entity, UserRow } from "./index"

// ---------------------------------------------------------------------------
// Membership rows

export type MemberRole = "owner" | "admin" | "member"

/**
 * One member of a space or one direct participant of a chat. Its user row
 * travels with it in the same subscription.
 *
 * `id` is `memberRowId(...)`: `space:${spaceId}:${userId}` or
 * `chat:${chatId}:${userId}`, so a space membership and a chat grant of the
 * same user are different rows.
 */
export type MemberRow = {
  kind: "member"
  id: string
  userId: UserID
  /** Set for a space member. */
  spaceId?: SpaceID
  /** Set for a chat participant. */
  chatId?: ChatID
  /** Space members only. Absent when the server did not say. */
  role?: MemberRole
  /** Space members only: whether they see the space's public chats. */
  canAccessPublicChats?: boolean
  /** Seconds since the epoch: when they joined the space, or were added to the chat. */
  date?: number
}

export const memberRowId = (
  scope: { spaceId: SpaceID } | { chatId: ChatID },
  userId: UserID,
): string => ("spaceId" in scope ? `space:${scope.spaceId}:${userId}` : `chat:${scope.chatId}:${userId}`)

/** A user group of a space, for group mentions and group grants. */
export type UserGroupRow = {
  kind: "userGroup"
  id: string
  spaceId: SpaceID
  name: string
  description?: string
  memberCount: number
  userIds: UserID[]
  currentUserIsMember: boolean
}

/** A personal dialog folder. Order coordinates are fractional strings, like `DialogRow.order`. */
export type FolderRow = {
  kind: "folder"
  id: string
  title?: string
  emoji?: string
  order: string
  /** Present when pinned: its coordinate in the pinned lane. */
  pinnedOrder?: string
}

export type AccountNotificationMode = "all" | "none" | "mentions" | "importantOnly" | "onlyMentions"

/** A privacy rule, as plain data (`PrivacyRule`). */
export type PrivacyRuleValue = {
  audience: "everyone" | "nobody" | "unknown"
  /** User IDs that may see it although the audience is nobody. */
  alwaysShare?: UserID[]
  /** User IDs that may not see it although the audience is everyone. */
  neverShare?: UserID[]
}

/** The account's settings (`UserSettings`); groups the server never sent are absent. */
export type UserSettingsValue = {
  notifications?: {
    mode?: AccountNotificationMode
    silent?: boolean
    zenModeRequiresMention?: boolean
    zenModeUsesDefaultRules?: boolean
    zenModeCustomRules?: string
    disableDmNotifications?: boolean
  }
  privacy?: {
    shareTimeZone?: boolean
    appearInGlobalSearch?: boolean
    timeZone?: PrivacyRuleValue
    focusStatus?: PrivacyRuleValue
  }
  compose?: {
    replacePastedLinksWithTitles?: boolean
  }
  messageGestures?: {
    doubleTapAction?: string
    holdAction?: string
    swipeToReplyDirection?: string
  }
}

/** The one settings row (`id` is always `"account"`). */
export type SettingsRow = { kind: "settings"; id: "account" } & UserSettingsValue

/**
 * A change to the account's settings: each group present is merged into the
 * stored one field by field. Privacy rules are not settable here yet.
 */
export type UserSettingsPatch = {
  notifications?: NonNullable<UserSettingsValue["notifications"]>
  privacy?: Pick<NonNullable<UserSettingsValue["privacy"]>, "shareTimeZone" | "appearInGlobalSearch">
  compose?: NonNullable<UserSettingsValue["compose"]>
  messageGestures?: NonNullable<UserSettingsValue["messageGestures"]>
}

// ---------------------------------------------------------------------------
// Rosters

/**
 * State of a member list (`chatParticipants`, `spaceMembers`).
 * - `complete`: the device holds the whole list as of the last server
 *   snapshot, kept live since. False: it may be partial.
 * - `loading`: a fetch from the server is in flight.
 * - `failed`: the last fetch failed; the list is what the device has.
 */
export type RosterResource = {
  kind: "roster"
  complete: boolean
  loading: boolean
  failed?: boolean
}

// ---------------------------------------------------------------------------
// Media

/**
 * Which bytes a `media` subscription is about.
 *
 * - `message`: the media of a message on the device. `size` is a photo size
 *   type (`b`, `c`, `d`, `f`, ...: `chat-ui` `photoVariantFor`); absent, the
 *   photo's largest size, or the whole file for a video, document or voice.
 *   With `thumbnail`, `size` names a size of a video's or document's
 *   thumbnail photo instead.
 * - `attachment`: a file attached on this device (`attachFile`): its staged
 *   bytes, and its upload's progress.
 */
export type MediaRef =
  | { kind: "message"; chatId: ChatID; messageId: MessageID; size?: string; thumbnail?: boolean }
  | { kind: "attachment"; attachmentId: AttachmentId }

export type MediaState =
  /** Nothing is cached and nothing is fetching (not wanted yet, offline, or over the auto-download limit). */
  | "absent"
  | "queued"
  | "downloading"
  | "ready"
  | "failed"

/**
 * One media subscription's state. When `ready`, `blob` holds the bytes.
 *
 * `blob` is a handle, not a copy: structured clone shares a `Blob`'s bytes
 * between the core's worker and the UI thread without copying them. The UI:
 * - makes one object URL per blob it shows (`URL.createObjectURL`) and
 *   revokes it when the view stops showing it, or when a later resource
 *   carries a different blob;
 * - may rely on the blob only while it holds the subscription: the core pins
 *   the cached file while any subscription needs it, and may evict it (which
 *   invalidates the handle) after the last one is gone. An image already
 *   decoded keeps painting; re-decoding needs a subscription.
 */
export type MediaResource = {
  kind: "media"
  state: MediaState
  /** While downloading. */
  receivedBytes?: number
  totalBytes?: number
  blob?: Blob
  mimeType?: string
  /** Bytes of the ready file; changes when the cached file changed. */
  size?: number
  /** Why it failed, for the UI to word ("network", "expired", "notFound", ...). */
  failure?: string
  /** For an attachment: what it is and how its upload is going. */
  attachment?: AttachmentInfo
  upload?: UploadProgress
}

/** The largest `attachFile.preview` the core keeps; a larger one is ignored. */
export const ATTACHMENT_PREVIEW_MAX_BYTES = 16 * 1024

/** An ID for a file attached on this device, chosen by the UI (`newAttachmentId`). */
export type AttachmentId = string

export type AttachmentKind = "photo" | "video" | "document" | "voice"

/**
 * What the core knows about an attachment, enough to build its optimistic
 * row (`optimisticMediaRow`): its kind, name, type, size, dimensions and a
 * tiny JPEG preview for the first frame.
 */
export type AttachmentInfo = {
  kind: AttachmentKind
  fileName: string
  mimeType: string
  /** Bytes that will be uploaded (after photo compression). */
  size: number
  width?: number
  height?: number
  /** Seconds, for video and voice. */
  duration?: number
  /** A tiny JPEG (a few hundred bytes) for a photo or video's first frame. */
  preview?: Uint8Array
}

export type UploadProgress = {
  state: "staged" | "uploading" | "processing" | "complete" | "failed" | "canceled"
  sentBytes: number
  totalBytes: number
  /** Failed but a `retrySend` may succeed. */
  retryable?: boolean
}

/** A message being sent from this device with an attachment (`MessageRow.upload`). */
export type MessageUpload = {
  attachmentId: AttachmentId
  attachment: AttachmentInfo
}

const ATTACHMENT_ID = /^[a-f0-9]{24}$/

export const isAttachmentId = (value: unknown): value is AttachmentId =>
  typeof value === "string" && ATTACHMENT_ID.test(value)

/** A fresh attachment ID: 96 random bits, lowercase hex. */
export const newAttachmentId = (): AttachmentId => {
  const bytes = new Uint8Array(12)
  crypto.getRandomValues(bytes)
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")
}

// ---------------------------------------------------------------------------
// Compose activity (ephemeral: never stored)

export type ComposeActionKind =
  | "typing"
  | "uploadingPhoto"
  | "uploadingDocument"
  | "uploadingVideo"
  | "recordingVoice"
  | "working"

export type ComposeActivity = {
  chatId: ChatID
  userId: UserID
  action: ComposeActionKind
}

/**
 * Who is composing, for a `composeActions` subscription: one chat, or every
 * chat. Live only: lost on reconnect and never written to the replica.
 * Each entry expires `COMPOSE_ACTION_RULE.expireMs` after its last refresh.
 */
export type ComposeResource = {
  kind: "compose"
  activities: ComposeActivity[]
}

/** The Mac's rules (`ComposeActions.swift`). */
export const COMPOSE_ACTION_RULE = {
  /** A continuing action is sent again this often. */
  refreshMs: 3_000,
  /** An action not refreshed for this long is over. */
  expireMs: 6_000,
} as const

// ---------------------------------------------------------------------------
// Local message search (requests carried as subscriptions)

/** `[start, end)` in UTF-16 units. */
export type SearchRange = readonly [start: number, end: number]

export type SearchMessagesRequest = {
  query: string
  spaceId?: SpaceID
  /** Default 20, at most 100. */
  limit?: number
  /** Default true. */
  includeArchived?: boolean
  sort?: "newest" | "relevance"
  cursor?: string
}

/** Quick Search's `MessageHit` (`view/src/quick-search/sources.ts`). */
export type SearchMessageHit = {
  chatId: ChatID
  messageId: MessageID
  /** The chat's title as the sidebar shows it. */
  chatTitle: string
  peerUserId?: UserID
  spaceId?: SpaceID
  fromId?: UserID
  date: number
  snippet: string
  snippetRanges?: SearchRange[]
}

export type FindInChatRequestValue = {
  chatId: ChatID
  query: string
  cursor?: string
  direction?: "older" | "newer"
  /** Default 100, at most 100. */
  limit?: number
}

export type FindInChatHit = {
  messageId: MessageID
  fromId: UserID
  date: number
  out: boolean
  text: string
  ranges: SearchRange[]
  cursor: string
}

export type CountMessagesRequest = { query: string; chatId?: ChatID }

/**
 * The answer to a search subscription. It is replaced when the request is
 * (subscribe the same `sub` again with the new request), and a request that
 * was replaced or unsubscribed never delivers a result.
 *
 * - `pending`: running.
 * - `done`: `result` holds the answer.
 * - `failed`: storage failed, the cursor was not one the core gave out, or
 *   this core has no index (in-memory storage): `reason` says which.
 */
export type SearchResource =
  | { kind: "search"; status: "pending" }
  | { kind: "search"; status: "failed"; reason: "unavailable" | "invalid" | "storage" }
  | {
      kind: "search"
      status: "done"
      result:
        | {
            kind: "messages"
            hits: SearchMessageHit[]
            nextCursor?: string
            indexComplete: boolean
            truncated: boolean
          }
        | {
            kind: "findInChat"
            hits: FindInChatHit[]
            hasOlder: boolean
            hasNewer: boolean
            olderCursor?: string
            newerCursor?: string
            indexComplete: boolean
            truncated: boolean
          }
        | { kind: "count"; count: number; capped: boolean; indexComplete: boolean }
    }

/** The search index state on the `core` resource. */
export type SearchIndexState =
  | { state: "building"; indexed: number; total: number }
  | { state: "ready" }
  | { state: "failed" }

// ---------------------------------------------------------------------------
// Helpers for media sends

/**
 * The intents for a message with attachments, as the Mac sends it: one
 * message per attachment, the text, entities and reply on the first. With no
 * attachments, nothing (send a `sendText`).
 */
export const mediaSendIntents = (input: {
  chatId: ChatID
  text?: string
  entities?: Entity[]
  replyToMessageId?: MessageID
  date?: number
  /** The composer's draft revision: consumed by the first send's commit (see `sendText.draftRevision`). */
  draftRevision?: number
  attachments: readonly { attachmentId: AttachmentId; clientKey: string }[]
}): Array<{
  kind: "sendMedia"
  chatId: ChatID
  clientKey: string
  attachmentId: AttachmentId
  text?: string
  entities?: Entity[]
  replyToMessageId?: MessageID
  date?: number
  draftRevision?: number
}> =>
  input.attachments.map((attachment, index) => ({
    kind: "sendMedia" as const,
    chatId: input.chatId,
    clientKey: attachment.clientKey,
    attachmentId: attachment.attachmentId,
    ...(index === 0 && input.text ? { text: input.text } : {}),
    ...(index === 0 && input.entities && input.entities.length > 0 ? { entities: input.entities } : {}),
    ...(index === 0 && input.replyToMessageId ? { replyToMessageId: input.replyToMessageId } : {}),
    ...(input.date != null ? { date: input.date } : {}),
    ...(index === 0 && input.draftRevision != null ? { draftRevision: input.draftRevision } : {}),
  }))

// ---------------------------------------------------------------------------
// Contract additions of 17 November (contract-2): shared media of a chat and
// server search. All additive and optional.

/**
 * What a `chatMedia` subscription lists (the Mac's Chat Info tabs and the
 * server's `SearchMessagesFilter`):
 * - `photosVideos`: photos and videos (stickers included, as the server does);
 * - `photos`, `videos`: one of the two;
 * - `files`: documents;
 * - `voice`: voice messages;
 * - `links`: messages with a link (a URL entity, a text link or a link preview).
 */
export type ChatMediaFilter = "photosVideos" | "photos" | "videos" | "files" | "voice" | "links"

/**
 * State of a `chatMedia` list.
 * - `loading`: a server page is being fetched.
 * - `hasMore`: the server may have older items; `ensure older` fetches the
 *   next page. False after a short page; true and unchanged while offline.
 * - `failed`: the last server page failed; the list is what the device has.
 * - `fetched`: at least one server page arrived in this subscription, so the
 *   newest items are known. False: the list is the device's only.
 */
export type ChatMediaResource = {
  kind: "chatMedia"
  loading: boolean
  hasMore: boolean
  fetched: boolean
  failed?: boolean
}

/** A server search in one chat (`SEARCH_MESSAGES`). */
export type ServerMessageSearchRequest = {
  chatId: ChatID
  /** Words, all required (the server ANDs them). At least one letter or digit. */
  query: string
  /** Older than this message (the previous page's `nextOffsetId`). */
  offsetId?: MessageID
  /** Default 50, at most 100. */
  limit?: number
  /** The exact number of matches instead of a page. */
  countOnly?: boolean
}

/** A server people search (`SEARCH_USERS`). */
export type UserSearchRequest = {
  /** At least two characters; a leading `@` is ignored. */
  query: string
  /** Default 20, at most 20. */
  limit?: number
}

/** One server hit: `FindInChatHit` without a local cursor. `ranges` are computed by the core on the text. */
export type ServerMessageHit = Omit<FindInChatHit, "cursor">

/**
 * The answer to a `searchServerMessages` or `searchUsers` subscription, with
 * the same request rules as `SearchResource`: replaced when the request is,
 * and a replaced or released request never delivers.
 *
 * Results are not rows: they are not written to the replica (a hit can be
 * opened with a `chatWindow` around its message ID; people found here may
 * not be on the device). `users` are plain `UserRow` values carried in the
 * resource, not entries of the view store.
 *
 * - `failed`: `offline` (needs a connection; nothing was sent), `invalid`
 *   (malformed request), `server` (the server refused or failed), `unavailable`
 *   (the core is not running).
 */
export type RemoteSearchResource =
  | { kind: "remoteSearch"; status: "pending" }
  | { kind: "remoteSearch"; status: "failed"; reason: "offline" | "invalid" | "server" | "unavailable" }
  | {
      kind: "remoteSearch"
      status: "done"
      result:
        | {
            kind: "messages"
            chatId: ChatID
            hits: ServerMessageHit[]
            /** Pass as `offsetId` for the next page; absent on the last page. */
            nextOffsetId?: MessageID
          }
        | { kind: "count"; chatId: ChatID; count: number }
        | { kind: "users"; users: UserRow[] }
    }
