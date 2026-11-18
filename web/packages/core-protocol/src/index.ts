/**
 * The contract between a UI context and the account core.
 *
 * Everything here is plain, structured-cloneable data plus a few pure helpers.
 * Both sides import this package; neither imports the other. See
 * web/docs/architecture.md ("Core protocol", "Local echo").
 *
 * v0: the starting shape. The core host work owns this file and may extend it.
 */

import type { ChatID, DialogID, MessageID, SpaceID, UserID } from "@inline/ids"
import type {
  ContentBlock,
  ForwardHeader,
  MediaContent,
  MessageActionRows,
  MessageAttachmentContent,
  RepliesSummary,
  ServiceContent,
  ViaInfo,
} from "./content"

import type {
  AttachmentId,
  AttachmentInfo,
  ChatMediaFilter,
  ChatMediaResource,
  ComposeActionKind,
  ComposeResource,
  CountMessagesRequest,
  FindInChatRequestValue,
  FolderRow,
  MediaRef,
  MediaResource,
  MemberRow,
  MessageUpload,
  RemoteSearchResource,
  RosterResource,
  SearchIndexState,
  SearchMessagesRequest,
  SearchResource,
  ServerMessageSearchRequest,
  UserSearchRequest,
  SettingsRow,
  UserGroupRow,
  UserSettingsPatch,
} from "./data"

export * from "./content"
export * from "./data"

export const CORE_PROTOCOL_VERSION = 0

// ---------------------------------------------------------------------------
// Identity

/** Monotonic revision of the state a UI context has been sent. */
export type Revision = number
/** Subscription ID, chosen by the UI context, unique within that context. */
export type SubId = number
/** Intent transaction ID, chosen by the UI. Stable across retries. */
export type TxId = string

export type RowKind =
  | "user"
  | "chat"
  | "dialog"
  | "space"
  | "message"
  | "draft"
  | "member"
  | "userGroup"
  | "folder"
  | "settings"

/**
 * Stable identity of a message row for the lifetime of a session.
 *
 * A received message is `${chatId}:${messageId}`. A message sent from this
 * device is `${chatId}:r${clientKey}` and keeps that ID after the server
 * assigns a message ID, so the row never changes identity in the UI.
 */
export type MessageRowId = string

export const sentMessageRowId = (chatId: ChatID, clientKey: string): MessageRowId =>
  `${chatId}:r${clientKey}`

export const receivedMessageRowId = (chatId: ChatID, messageId: MessageID): MessageRowId =>
  `${chatId}:${messageId}`

/** Key of a row in the view store: kind plus ID. */
export type RowKey = `${RowKind}:${string}`

export const rowKey = (kind: RowKind, id: string): RowKey => `${kind}:${id}`

// ---------------------------------------------------------------------------
// Rows: view-shaped, immutable snapshots

export type UserRow = {
  kind: "user"
  id: UserID
  firstName?: string
  lastName?: string
  username?: string
  /** Used for the display-name fallback when a user has no name. */
  email?: string
  bot?: boolean
  photoUrl?: string
}

export type SpaceRow = {
  kind: "space"
  id: SpaceID
  name: string
  isPublic?: boolean
  /** The space's public handle. */
  handle?: string
  /** The account created the space. */
  creator?: boolean
  /** Signed and expiring; see `PhotoSizeInfo`. */
  photoUrl?: string
}

export type ChatRow = {
  kind: "chat"
  id: ChatID
  title?: string
  emoji?: string
  spaceId?: SpaceID
  isPublic?: boolean
  /** Set for a direct message chat. */
  peerUserId?: UserID
  parentChatId?: ChatID
  parentMessageId?: MessageID
  lastMessageId?: MessageID
  /**
   * Row ID of the chat's last message, which a send from this device keeps
   * by client key (`lastMessageId` cannot name it before the server assigns
   * one). The `sidebar` query carries that message row when it is on the
   * device.
   */
  lastMessageRowId?: MessageRowId
  /** Seconds since the epoch of the last activity. */
  lastActivityDate?: number
  /** The user who created the chat. */
  createdBy?: UserID
  /**
   * The ID of this chat's dialog (`rowKey("dialog", dialogId)`), so a chat
   * maps to its dialog without a second index. Set on every chat row; the
   * dialog row itself is on the device only when the account has one (the
   * `chat` query carries it then).
   */
  dialogId?: DialogID
}

export type DialogRow = {
  kind: "dialog"
  id: DialogID
  chatId: ChatID
  peerUserId?: UserID
  spaceId?: SpaceID
  pinned: boolean
  archived: boolean
  open: boolean
  /** Fractional index strings; see the sidebar ordering rules. */
  order?: string
  pinnedOrder?: string
  unreadCount: number
  unreadMark: boolean
  readMaxId?: MessageID
  /**
   * The user's follow choice for a thread. Absent: the default relevance
   * mode (mentions and replies surface it). A followed thread's unread is
   * prominent.
   */
  followMode?: "following" | "unfollowed"
  /** The chat's own notification setting. Absent: it follows the account's. */
  notificationMode?: "all" | "mentions" | "none"
  /** Unseen mentions of the user, and unseen reactions to their messages, as the server counts them. Absent: not known. */
  unreadMentionsCount?: number
  unreadReactionsCount?: number
  /** The user's dialog folder; absent shows the dialog unfiled. */
  folderId?: string
}

export type EntityType =
  | "mention"
  | "url"
  | "textUrl"
  | "email"
  | "bold"
  | "italic"
  | "usernameMention"
  | "code"
  | "pre"
  | "phoneNumber"
  | "thread"
  | "threadTitle"
  | "botCommand"
  | "groupMention"
  | "underline"
  | "strikethrough"
  | "highlight"
  | "math"
  | "blockquote"

/** Offsets and lengths are UTF-16 code units into the message text. */
export type Entity = {
  type: EntityType
  offset: number
  length: number
  userId?: UserID
  url?: string
  language?: string
  chatId?: ChatID
  /** Group mention: the user group. */
  groupId?: string
  /** Thread title: the space the thread lives in, and its title. */
  spaceId?: SpaceID
  title?: string
  /** Bot command: the bot it addresses. */
  botUserId?: UserID
  /** Mention of an agent: the agent. */
  agentId?: string
  /** Math: true for a display (block) formula, false or absent for inline. */
  display?: boolean
}

/**
 * - `sending`: accepted locally, not yet acknowledged by the server.
 * - `sent`: acknowledged.
 * - `failed`: the server rejected it.
 * - `uncertain`: the request was in flight when the connection was lost and
 *   the outcome is not known yet. Never shown as failed or as delivered.
 */
export type MessageState = "sending" | "sent" | "failed" | "uncertain"

export type ReactionSummary = {
  emoji: string
  count: number
  mine: boolean
}

export type MessageRow = {
  kind: "message"
  id: MessageRowId
  chatId: ChatID
  /** Absent until the server assigns one. */
  messageId?: MessageID
  /** Present for messages sent from this device. */
  clientKey?: string
  fromId: UserID
  out: boolean
  /** Seconds since the epoch. */
  date: number
  text: string
  entities?: Entity[]
  replyToMessageId?: MessageID
  editDate?: number
  state: MessageState
  reactions?: ReactionSummary[]
  /**
   * True when the message carries something this build does not represent
   * on the row: a media, attachment, service or button kind it does not
   * know, or a part that could not be read. Unknown block kinds are not
   * counted: they are on `blocks` as `{ kind: "unknown" }` and fall back to
   * the text they cover.
   */
  hasUnsupportedContent?: boolean
  /** The server marked the message as mentioning the user (directly or through a group). */
  mentioned?: boolean
  /** The sender chose a silent send: it should not alert. */
  silent?: boolean

  // Content beyond text (all optional; see `content.ts` and the README).

  /** Photo, video, document, voice or nudge. */
  media?: MediaContent
  /** Album identity: consecutive media messages with the same value form one group. */
  groupedId?: string
  /** URL previews and external tasks, in order. */
  attachments?: MessageAttachmentContent[]
  forward?: ForwardHeader
  /** Text quoted from the replied message (`reply_quote`); the caption is `text`. */
  replyQuote?: string
  /** The reply thread or subthread under this message. */
  replies?: RepliesSummary
  /** Who sent it for the sender. Messages group only when `via` matches. */
  via?: ViaInfo
  /** Set for a service message; never grouped. `text` is the fallback. */
  service?: ServiceContent
  /** Bot buttons, row by row. */
  actions?: MessageActionRows
  /**
   * Structural projection of `text` (`BlockContent`). `text` and `entities`
   * stay the source of truth; blocks only point into `text`.
   */
  blocks?: ContentBlock[]
  /**
   * A send from this device with an attachment, until the server has the
   * message. Its bytes are the `media` query of `{ kind: "attachment" }`;
   * `media`, when present, describes the local file (IDs are "0").
   */
  upload?: MessageUpload
  /**
   * A send from this device that the server does not have yet (`sending`,
   * `failed` or `uncertain`): the transaction ID of the intent that created
   * it, kept durably with the outbox entry. After a reload or a leader
   * handoff a UI matches the row to the send it made (its overlay entry, its
   * pending result) by this ID. Absent once the server has the message, and
   * on sends made before this field existed.
   */
  tx?: TxId
}

export type DraftRow = {
  kind: "draft"
  /** The chat this draft belongs to. */
  id: ChatID
  text: string
  entities?: Entity[]
  revision: number
}

export type Row =
  | UserRow
  | SpaceRow
  | ChatRow
  | DialogRow
  | MessageRow
  | DraftRow
  | MemberRow
  | UserGroupRow
  | FolderRow
  | SettingsRow

export type RowOf<K extends RowKind> = Extract<Row, { kind: K }>

// ---------------------------------------------------------------------------
// Queries

export type WindowAnchor = "latest" | "unread" | { around: MessageID }

export type QueryDescriptor =
  /** Core phase and connection state. Resource only; no list. */
  | { kind: "core" }
  /** The signed-in user. List of one user row. */
  | { kind: "me" }
  /** Ordered dialog rows; the chat and peer user rows they need come with them. */
  | { kind: "sidebar"; mode: "inbox" | "all" | "archived"; spaceId?: SpaceID }
  /** A contiguous window of message rows, oldest first, with a window resource. */
  | { kind: "chatWindow"; chatId: ChatID; anchor: WindowAnchor }
  /** The chat row; with it, the chat's dialog row when it is on the device (not in the list). */
  | { kind: "chat"; chatId: ChatID }
  | { kind: "user"; userId: UserID }
  | { kind: "draft"; chatId: ChatID }
  /**
   * Incoming messages that arrived live after the subscription started, for
   * notifications: oldest first, append-only, bounded. Each message row
   * comes with its chat, dialog and sender rows (and its space, parent chat
   * and replied-to message when they are on the device). See
   * `NEW_MESSAGES_RULE` for exactly which messages qualify.
   */
  | { kind: "newMessages" }
  /**
   * A chat's direct participants: its group grants first (`userGroup` rows by
   * name), then its members (`member` rows by display name, then user ID),
   * each with its user row. Fetched from the server on first subscribe unless
   * the device's list is complete; a `roster` resource says which.
   */
  | { kind: "chatParticipants"; chatId: ChatID }
  /** A space's members: the account first, then by join date; each with its user row. `roster` resource. */
  | { kind: "spaceMembers"; spaceId: SpaceID }
  /** A space's user groups on the device, by name (for group mentions). */
  | { kind: "userGroups"; spaceId: SpaceID }
  /** The account's spaces, by name. */
  | { kind: "spaces" }
  /** The account's settings: a list of zero or one `settings` row (fetched once if absent). */
  | { kind: "userSettings" }
  /** The account's dialog folders: pinned first by `pinnedOrder`, then by `order`. */
  | { kind: "dialogFolders" }
  /**
   * Bytes to show (`MediaResource`, no list). A subscription is a claim: it
   * downloads at `visible` priority (within the auto-download limits), or
   * first and without limits with `priority: "opened"` (the user asked).
   */
  | { kind: "media"; media: MediaRef; priority?: "visible" | "opened" }
  /** Who is composing in one chat, or in every chat (`ComposeResource`; the list carries their user rows). */
  | { kind: "composeActions"; chatId?: ChatID }
  /** Local message search, request and answer (`SearchResource`, no list). */
  | { kind: "searchMessages"; request: SearchMessagesRequest }
  | { kind: "findInChat"; request: FindInChatRequestValue }
  | { kind: "countMessages"; request: CountMessagesRequest }
  /**
   * A chat's shared media, files, voice messages or links: message rows,
   * newest first, each with its sender's row, and a `chatMedia` resource.
   * The device's messages first; while connected the server's first page
   * follows (`SEARCH_MESSAGES` with the filter), and `ensure older` on the
   * subscription fetches the next one. Server pages are committed to the
   * replica, so every listed row is on disk.
   */
  | { kind: "chatMedia"; chatId: ChatID; filter: ChatMediaFilter }
  /**
   * Server search in one chat (`SEARCH_MESSAGES`), as request and answer
   * (`remoteSearch` resource, no list): hits or, with `countOnly`, the exact
   * count. Merge with `findInChat` by message ID. Needs a connection.
   */
  | { kind: "searchServerMessages"; request: ServerMessageSearchRequest }
  /** Server people search (`SEARCH_USERS`, the Mac's global search) as request and answer (`remoteSearch` resource, no list). */
  | { kind: "searchUsers"; request: UserSearchRequest }

/**
 * Which messages the `newMessages` query lists (the Mac app's notification
 * gating, `MacNotifications.shouldScheduleMessageNotification`):
 *
 * - delivered by an update (a live push, or a catch-up page after a
 *   reconnect), never by history paging, a snapshot repair or a local read;
 * - inserted for the first time (an edit or a re-delivery is not new);
 * - incoming (not sent by this account) and not silent;
 * - unread when it arrived (above the dialog's read frontier);
 * - at most `maxAgeSeconds` old by its date when it arrived, so a catch-up
 *   after a long offline period lists only what is still fresh.
 *
 * The list keeps at most `limit` messages and releases each one
 * `retainSeconds` after it arrived.
 */
export const NEW_MESSAGES_RULE = {
  maxAgeSeconds: 120,
  limit: 50,
  retainSeconds: 300,
} as const

export type QueryKind = QueryDescriptor["kind"]

// ---------------------------------------------------------------------------
// Resources: per-subscription state that is not a row

export type CorePhase =
  /** Opening storage, restoring state. */
  | "starting"
  | "ready"
  /** No session; the UI shows sign-in. */
  | "signedOut"
  /** The replica was written by a newer build. The UI offers a reload. */
  | "outdated"
  /** A newer build is running in another context. The UI offers a reload. */
  | "superseded"
  | "failed"

export type ConnectionState =
  | "idle"
  | "connecting"
  | "updating"
  | "connected"
  | "waitingForNetwork"
  | "sessionRevoked"

export type StorageState =
  | "persistent"
  /** OPFS is unavailable; data is not kept across reloads. */
  | "memory"
  /** Storage is full; durable intents are refused. */
  | "full"

export type CoreResource = {
  kind: "core"
  phase: CorePhase
  connection: ConnectionState
  storage: StorageState
  buildId: string
  userId?: UserID
  /** Human-readable reason when `phase` is `failed`. Never contains user data. */
  failure?: string
  /**
   * Sync scopes that stopped retrying (absent when none). Their data may be
   * behind until the next connection or a `retrySync` intent. Show a quiet
   * indicator with a retry, not an error.
   */
  stalledSync?: SyncStall[]
  /** Local message search index; absent when this core has none. */
  searchIndex?: SearchIndexState
  /**
   * Set while a sign-out is erasing this device's data (the phase is still
   * the previous one): every intent is refused, nothing more is written.
   * Close the page only after `phase` is `signedOut`.
   */
  signingOut?: true
  /**
   * On `signedOut` after a sign-out or a server revocation: whether this
   * account's data on the device (replica, search index, media) is gone.
   * - `complete`: erased.
   * - `failed`: the erase failed part way. A marker written before the erase
   *   started stays, and the next start of this account (or a host's
   *   `finishPendingErase`) finishes the erase before opening anything.
   */
  erased?: "complete" | "failed"
}

/** One sync scope (bucket) that stopped retrying. */
export type SyncStall = {
  /** The account's own updates, a space's, or one chat's. */
  scope: "account" | "space" | "chat"
  spaceId?: SpaceID
  /** For a chat scope, when the core knows the chat. */
  chatId?: ChatID
  /** For a direct-message chat scope: the peer. */
  peerUserId?: UserID
  /**
   * - `retryLimit`: it failed repeatedly; a retry may help.
   * - `repairUnavailable`: it needs a full refresh this build cannot do;
   *   a retry is unlikely to help.
   */
  reason: "retryLimit" | "repairUnavailable"
}

export type WindowResource = {
  kind: "window"
  hasOlder: boolean
  hasNewer: boolean
  /** True when the window's end is the live end of the chat. */
  atLatest: boolean
  loading: "none" | "initial" | "older" | "newer"
  /** The read boundary captured when the subscription opened. */
  unreadBoundary?: MessageID
  /**
   * The newest message ID up to which this window's history is known to be
   * contiguous. Read state must not advance past it.
   */
  certifiedThrough?: MessageID
}

export type ResourceValue =
  | CoreResource
  | WindowResource
  | RosterResource
  | MediaResource
  | ComposeResource
  | SearchResource
  | ChatMediaResource
  | RemoteSearchResource

// ---------------------------------------------------------------------------
// Intents

export type Intent =
  | {
      kind: "sendText"
      chatId: ChatID
      /** Decimal string of the client random ID. Becomes `MessageRow.clientKey`. */
      clientKey: string
      text: string
      entities?: Entity[]
      replyToMessageId?: MessageID
      /**
       * Seconds since the epoch, taken by the UI when it built its overlay
       * row. The core uses it for the committed row so both sides produce the
       * same row. Defaults to the core's clock.
       */
      date?: number
      /**
       * The draft revision this send consumes. The chat's draft is deleted in
       * the same commit as the send when its stored revision is at most this
       * (a draft typed after the send stays). Absent: the draft is untouched.
       */
      draftRevision?: number
    }
  | { kind: "editText"; chatId: ChatID; messageId: MessageID; text: string; entities?: Entity[] }
  | {
      kind: "deleteMessages"
      chatId: ChatID
      messageIds: MessageID[]
      /**
       * Messages sent from this device, by client key (a send still in
       * flight has no message ID yet). Deleting one cancels its send.
       */
      clientKeys?: string[]
    }
  | { kind: "react"; chatId: ChatID; messageId: MessageID; emoji: string; action: "add" | "remove" }
  | { kind: "markRead"; chatId: ChatID; maxId: MessageID }
  | { kind: "saveDraft"; chatId: ChatID; text: string; entities?: Entity[]; revision: number }
  | { kind: "setDialogOpen"; chatId: ChatID; open: boolean }
  /**
   * Retry every stalled sync scope now (`CoreResource.stalledSync`).
   * `confirmed` once the retries started. An intent rather than a command so
   * carriers that route commands exhaustively need no change.
   */
  | { kind: "retrySync" }
  /**
   * Press a bot button (`actions[].buttons[]` of kind `callback`). Needs a
   * connection; sent once. `confirmed` carries the bot's `answer` when it
   * answered within `ACTION_ANSWER_TIMEOUT_MS`.
   */
  | { kind: "invokeAction"; chatId: ChatID; messageId: MessageID; actionId: string }
  /** Submit a form block (`blocks[].kind === "form"`). Like `invokeAction`. */
  | {
      kind: "submitForm"
      chatId: ChatID
      messageId: MessageID
      formId: string
      values: FormSubmissionValue[]
    }
  /** Merge into the account's settings. Durable; `UPDATE_USER_SETTINGS`. */
  | { kind: "updateUserSettings"; patch: UserSettingsPatch }
  /** A chat's notification mode; `default` follows the account's. Durable. */
  | { kind: "setDialogNotifications"; chatId: ChatID; mode: "all" | "mentions" | "none" | "default" }
  /** A thread's follow mode; `relevance` is the default. Durable. */
  | { kind: "setDialogFollow"; chatId: ChatID; mode: "relevance" | "following" | "unfollowed" }
  /** Durable. */
  | { kind: "setDialogPinned"; chatId: ChatID; pinned: boolean }
  /** Durable. */
  | { kind: "setDialogArchived"; chatId: ChatID; archived: boolean }
  /** Mark a dialog unread. Durable. */
  | { kind: "markUnread"; chatId: ChatID }
  /** "Mark as Read" from a chat list: everything, mentions and reactions too. Durable. */
  | { kind: "readAll"; chatId: ChatID }
  /**
   * Hand the core a file to send later. `confirmed` once its bytes are
   * staged durably (the `media` query of `{ kind: "attachment" }` then has
   * its info, preview and upload progress); its upload starts at once.
   * Dimensions and duration are hints the UI may know; the core measures
   * photos itself where it can. An attachment no send names is discarded an
   * hour after the core restarts.
   */
  | {
      kind: "attachFile"
      attachmentId: AttachmentId
      file: Blob
      fileName: string
      mimeType: string
      /** Default: photo for JPEG, PNG, WebP and HEIC images, video for video, else document. */
      as?: AttachmentInfo["kind"]
      width?: number
      height?: number
      duration?: number
      /**
       * A tiny JPEG of the first frame the UI made (a video's poster frame),
       * at most `ATTACHMENT_PREVIEW_MAX_BYTES`. The core makes photo previews
       * itself; for a photo this is used only when it cannot.
       */
      preview?: Uint8Array
    }
  /** The composer dropped an attachment before sending: cancel its upload and forget it. */
  | { kind: "discardAttachment"; attachmentId: AttachmentId }
  /**
   * Send one attachment as one message (`mediaSendIntents` splits a
   * composer's attachments, the Mac way). Durable: committed with its
   * optimistic row (`optimisticMediaRow`), sent after the upload, exactly
   * once, across restarts. Deleting it by client key cancels its upload.
   */
  | {
      kind: "sendMedia"
      chatId: ChatID
      clientKey: string
      attachmentId: AttachmentId
      text?: string
      entities?: Entity[]
      replyToMessageId?: MessageID
      date?: number
      /** As on `sendText`: the draft revision consumed in the send's commit. */
      draftRevision?: number
    }
  /** Send a failed send from this device again (a media send: its upload too). */
  | { kind: "retrySend"; chatId: ChatID; clientKey: string }
  /**
   * Rows just outside the viewport, to warm when scrolling goes idle. Replaces
   * this context's earlier nearby set. Within auto-download limits.
   */
  | { kind: "mediaHints"; nearby: MediaRef[] }
  /** What the user is doing in a chat's composer; `null` stops it. Ephemeral; `confirmed` at once. */
  | { kind: "composeAction"; chatId: ChatID; action: ComposeActionKind | null }
  /**
   * Add people (and user groups) to a private thread (`ADD_CHAT_PARTICIPANT`,
   * once per user or group). Durable: committed with the new `member` rows
   * of the people already on the device, sent when connected, restored after
   * a restart; the server adds idempotently. `confirmed` when every one was
   * added; `rejected` (`server`) when the server refused any (the others stay
   * added, and the participant list is fetched again).
   */
  | { kind: "addChatParticipants"; chatId: ChatID; userIds: UserID[]; groupIds?: string[] }
  /**
   * Remove one person (`userId`) or one user group (`groupId`) from a thread
   * (`REMOVE_CHAT_PARTICIPANT`). Durable like `addChatParticipants`; the row
   * goes in the accepting commit. A refusal does not put the row back: the
   * participant list is fetched again instead.
   */
  | { kind: "removeChatParticipant"; chatId: ChatID; userId?: UserID; groupId?: string }

export type IntentKind = Intent["kind"]

/**
 * One submitted form value (`MessageFormValue`). Empty answers are left out,
 * except toggles; `chat-ui`'s form model builds these.
 */
export type FormSubmissionValue = {
  readonly fieldId: string
  readonly value:
    | { readonly kind: "text"; readonly text: string }
    | { readonly kind: "selection"; readonly optionIds: readonly string[]; readonly otherText?: string }
    | { readonly kind: "toggle"; readonly value: boolean }
    | { readonly kind: "number"; readonly value: number }
}

/** What a bot answered to a button or form (`MessageActionResponseUi`). */
export type ActionAnswer =
  | { kind: "toast"; text: string }
  | { kind: "alert"; title?: string; text: string }

/** How long `confirmed` of an `invokeAction` or `submitForm` waits for the bot's answer. */
export const ACTION_ANSWER_TIMEOUT_MS = 10_000

/**
 * - `accepted`: committed durably on this device with its optimistic rows.
 * - `confirmed`: acknowledged by the server.
 * - `rejected`: refused, by the core before commit (see `reason`) or by the server.
 * - `uncertain`: the outcome on the server is not known yet.
 */
export type IntentStatus = "accepted" | "confirmed" | "rejected" | "uncertain"

export type IntentRejection =
  | "storageFull"
  | "notSignedIn"
  | "invalid"
  | "server"
  | "unsupported"
  /** The core is not ready to take intents: starting failed, outdated, or stopping. */
  | "unavailable"
  /**
   * The intent needs a connection and the core is offline. Only intents that
   * are not safe to replay (edit, delete, react) are refused this way; the
   * others wait in the outbox.
   */
  | "offline"

export type IntentResult = {
  tx: TxId
  status: IntentStatus
  reason?: IntentRejection
  /** Row keys this intent's optimistic state is now represented by, if any. */
  rows?: RowKey[]
  /** For a `confirmed` `invokeAction` or `submitForm`: the bot's answer, if it gave one in time. */
  answer?: ActionAnswer
}

// ---------------------------------------------------------------------------
// Commands: UI to core

export type SessionInfo = {
  userId: UserID
  token: string
}

/** Facts only a window knows, forwarded so the core can drive its connection. */
export type BrowserSignal =
  | { kind: "online"; online: boolean }
  | { kind: "visibility"; visible: boolean }
  | { kind: "wake" }

export type Command =
  | { kind: "hello"; buildId: string; protocol: number }
  | { kind: "session"; action: "start"; session: SessionInfo }
  | { kind: "session"; action: "signOut" }
  | { kind: "signal"; signal: BrowserSignal }
  | { kind: "subscribe"; sub: SubId; query: QueryDescriptor }
  | { kind: "unsubscribe"; sub: SubId }
  | { kind: "ensure"; sub: SubId; range: "older" | "newer" | "latest" | { around: MessageID } }
  | { kind: "intent"; tx: TxId; intent: Intent }
  /** Ask for a full snapshot of every subscription this context holds. */
  | { kind: "resync" }
  /**
   * Release rows of this subscription's window outside the inclusive range;
   * the core may keep more. A core that does not implement it ignores it.
   */
  | { kind: "trimWindow"; sub: SubId; keep: { from: MessageID; to: MessageID } }

// ---------------------------------------------------------------------------
// Patches: core to UI

export type RowChange =
  | { op: "upsert"; row: Row }
  | { op: "remove"; kind: RowKind; id: string }

export type ListChange =
  | { sub: SubId; op: "replace"; keys: RowKey[] }
  | { sub: SubId; op: "splice"; index: number; remove: number; insert: RowKey[] }

export type ResourceChange = { sub: SubId; value: ResourceValue }

export type Patch = {
  /** The revision this patch applies to. A mismatch means a gap: resync. */
  base: Revision
  revision: Revision
  rows: RowChange[]
  lists: ListChange[]
  resources: ResourceChange[]
  settled: IntentResult[]
}

/** The full state of a context's subscriptions. Replaces the view store. */
export type Snapshot = {
  revision: Revision
  rows: Row[]
  lists: { sub: SubId; keys: RowKey[] }[]
  resources: ResourceChange[]
  /**
   * The latest result of every intent this context issued that the core
   * still tracks: open ones, and recently settled ones (including any that
   * settled while the context was resyncing). Treat a missing field as empty;
   * the core host always sends it.
   */
  settled?: IntentResult[]
}

export type CoreMessage =
  | { kind: "hello"; buildId: string; protocol: number }
  | { kind: "patch"; patch: Patch }
  | { kind: "snapshot"; snapshot: Snapshot }

// ---------------------------------------------------------------------------
// The endpoint a UI context holds, and a core host implements

export type CoreMessageListener = (message: CoreMessage) => void

/**
 * One side of the protocol. The core host implements it directly; `link`
 * provides implementations that carry it across a worker, between tabs and
 * between Electron windows. Delivery is ordered. `post` never throws for a
 * well-formed command; failures arrive as data.
 *
 * The first message a context receives is a `snapshot` (possibly empty),
 * before any patch.
 *
 * `close` may return a promise. For an endpoint that owns the core (the core
 * host itself), it resolves once the core has released its storage and
 * connection, so a successor can open them.
 */
export interface CoreEndpoint {
  post(command: Command): void
  subscribe(listener: CoreMessageListener): () => void
  close(): void | Promise<void>
}

// ---------------------------------------------------------------------------
// Pure helpers shared by both sides

/**
 * The optimistic row for a `sendText` intent. The UI installs it in its
 * overlay in the same task as the keypress; the core commits the same row.
 */
export const optimisticMessageRow = (
  intent: Extract<Intent, { kind: "sendText" }>,
  fromId: UserID,
  /** Seconds since the epoch. */
  date: number,
  /** The intent's transaction ID, when known: the core's row carries it (`MessageRow.tx`). */
  tx?: TxId,
): MessageRow => ({
  kind: "message",
  id: sentMessageRowId(intent.chatId, intent.clientKey),
  chatId: intent.chatId,
  clientKey: intent.clientKey,
  fromId,
  out: true,
  date,
  text: intent.text,
  ...(intent.entities && intent.entities.length > 0 ? { entities: intent.entities } : {}),
  ...(intent.replyToMessageId ? { replyToMessageId: intent.replyToMessageId } : {}),
  state: "sending",
  ...(tx ? { tx } : {}),
})

/**
 * The optimistic row for a `sendMedia` intent, from the attachment's info
 * (the `media` query of the attachment gives it to the UI). The core commits
 * the same row.
 */
export const optimisticMediaRow = (
  intent: Extract<Intent, { kind: "sendMedia" }>,
  attachment: AttachmentInfo,
  fromId: UserID,
  /** Seconds since the epoch. */
  date: number,
  /** The intent's transaction ID, when known (`MessageRow.tx`). */
  tx?: TxId,
): MessageRow => {
  const media = localMedia(attachment)
  return {
    kind: "message",
    id: sentMessageRowId(intent.chatId, intent.clientKey),
    chatId: intent.chatId,
    clientKey: intent.clientKey,
    fromId,
    out: true,
    date,
    text: intent.text ?? "",
    ...(intent.entities && intent.entities.length > 0 ? { entities: intent.entities } : {}),
    ...(intent.replyToMessageId ? { replyToMessageId: intent.replyToMessageId } : {}),
    state: "sending",
    ...(media ? { media } : {}),
    upload: { attachmentId: intent.attachmentId, attachment },
    ...(tx ? { tx } : {}),
  }
}

/** `MessageRow.media` describing a local attachment, so a row has its final size at once. */
export const localMedia = (attachment: AttachmentInfo): MediaContent | undefined => {
  const local = "0" as never
  switch (attachment.kind) {
    case "photo":
      return attachment.width && attachment.height
        ? {
            kind: "photo",
            photo: {
              id: local,
              ...(attachment.mimeType === "image/png" ? { format: "png" as const } : attachment.mimeType === "image/jpeg" ? { format: "jpeg" as const } : {}),
              sizes: [{ type: "f", width: attachment.width, height: attachment.height, size: attachment.size }],
              ...(attachment.preview ? { preview: attachment.preview } : {}),
            },
          }
        : undefined
    case "video":
      return {
        kind: "video",
        video: {
          id: local,
          width: attachment.width ?? 0,
          height: attachment.height ?? 0,
          duration: attachment.duration ?? 0,
          size: attachment.size,
          ...(attachment.preview
            ? {
                // The poster frame only: it has no stored size to download.
                thumbnail: { id: local, sizes: [], preview: attachment.preview },
              }
            : {}),
        },
      }
    case "document":
      return {
        kind: "document",
        document: { id: local, fileName: attachment.fileName, mimeType: attachment.mimeType, size: attachment.size },
      }
    case "voice":
      return {
        kind: "voice",
        voice: { id: local, duration: attachment.duration ?? 0, size: attachment.size, mimeType: attachment.mimeType },
      }
  }
}

/** Whether two build IDs are ordered; the newer one leads. Build IDs sort lexically. */
export const isNewerBuild = (candidate: string, current: string): boolean => candidate > current

/** The view-store key of a row. */
export const rowKeyOf = (row: Row): RowKey => rowKey(row.kind, row.id)

const INT64_MAX = (1n << 63n) - 1n

/**
 * Whether a string is a valid client key: the canonical decimal form of a
 * positive 64-bit integer (no sign, no leading zeros). The core uses it as the
 * message's random ID on the wire.
 */
export const isClientKey = (value: unknown): value is string => {
  if (typeof value !== "string" || !/^[1-9][0-9]{0,18}$/.test(value)) return false
  return BigInt(value) <= INT64_MAX
}

/**
 * A fresh client key from 63 random bits. `random` returns two unsigned
 * 32-bit integers; the default uses `crypto.getRandomValues`.
 */
export const newClientKey = (
  random: () => [number, number] = () => {
    const words = new Uint32Array(2)
    crypto.getRandomValues(words)
    return [words[0] ?? 0, words[1] ?? 0]
  },
): string => {
  for (;;) {
    const [high, low] = random()
    const value = (BigInt(high & 0x7fff_ffff) << 32n) | BigInt(low >>> 0)
    if (value > 0n) return value.toString()
  }
}

// ---------------------------------------------------------------------------
// Reference reducer: how a UI context applies patches and snapshots.
//
// The view store in `reactive` is the production consumer; this is the plain
// version of the same rules, used by tests on both sides and by `link` when
// it needs to track revisions.

export type ProtocolState = {
  revision: Revision
  rows: Map<RowKey, Row>
  lists: Map<SubId, RowKey[]>
  resources: Map<SubId, ResourceValue>
}

export const createProtocolState = (): ProtocolState => ({
  revision: 0,
  rows: new Map(),
  lists: new Map(),
  resources: new Map(),
})

/**
 * - `applied`: the patch's base was the current revision.
 * - `stale`: the patch is at or before the current revision (it was already
 *   covered by a snapshot). Ignore it.
 * - `gap`: a patch was missed. Send `resync` and wait for the snapshot.
 */
export type PatchOutcome = "applied" | "stale" | "gap"

export const classifyPatch = (state: Pick<ProtocolState, "revision">, patch: Patch): PatchOutcome => {
  if (patch.base === state.revision) return "applied"
  if (patch.revision <= state.revision) return "stale"
  return "gap"
}

/** Apply a patch in place when its base matches. Returns what happened. */
export const applyPatch = (state: ProtocolState, patch: Patch): PatchOutcome => {
  const outcome = classifyPatch(state, patch)
  if (outcome !== "applied") return outcome
  for (const change of patch.rows) {
    if (change.op === "upsert") state.rows.set(rowKeyOf(change.row), change.row)
    else state.rows.delete(rowKey(change.kind, change.id))
  }
  for (const change of patch.lists) {
    if (change.op === "replace") {
      state.lists.set(change.sub, change.keys.slice())
    } else {
      const keys = state.lists.get(change.sub)?.slice() ?? []
      keys.splice(change.index, change.remove, ...change.insert)
      state.lists.set(change.sub, keys)
    }
  }
  for (const change of patch.resources) state.resources.set(change.sub, change.value)
  state.revision = patch.revision
  return "applied"
}

/** Replace the whole state with a snapshot. */
export const applySnapshot = (state: ProtocolState, snapshot: Snapshot): void => {
  state.revision = snapshot.revision
  state.rows = new Map(snapshot.rows.map((row) => [rowKeyOf(row), row]))
  state.lists = new Map(snapshot.lists.map((list) => [list.sub, list.keys.slice()]))
  state.resources = new Map(snapshot.resources.map((change) => [change.sub, change.value]))
}

/** Forget a subscription's list and resource after `unsubscribe`. Rows go by patch. */
export const dropSubscription = (state: ProtocolState, sub: SubId): void => {
  state.lists.delete(sub)
  state.resources.delete(sub)
}
