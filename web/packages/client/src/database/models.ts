/**
 * Models
 *
 * We use plain typescript objects for now. Later we can upgrade to Effect Schema or Zod.
 *
 */

export type DbModel =
  | User
  | Dialog
  | Chat
  | Message
  | Space
  | SyncGlobalState
  | SyncBucketState
  | DeferredUpdate
  | PendingTransaction
  | ReservedChatID
  | MessageDraft
  | HistoryCoverage
  | SpaceMember
  | ChatParticipant
  | ChatParticipantGroup
  | UserGroup
  | DialogFolder
  | UserSettings

export enum DbObjectKind {
  Dialog = "D",
  Chat = "C",
  User = "U",
  Message = "M",
  Space = "S",
  SyncGlobalState = "SG",
  SyncBucketState = "SB",
  DeferredUpdate = "DU",
  PendingTransaction = "TX",
  ReservedChatID = "RCI",
  MessageDraft = "MD",
  HistoryCoverage = "HC",
  SpaceMember = "SM",
  ChatParticipant = "CP",
  ChatParticipantGroup = "CPG",
  UserGroup = "UG",
  DialogFolder = "DF",
  UserSettings = "US",
}

export type DbModels = {
  [DbObjectKind.User]: User
  [DbObjectKind.Dialog]: Dialog
  [DbObjectKind.Chat]: Chat
  [DbObjectKind.Message]: Message
  [DbObjectKind.Space]: Space
  [DbObjectKind.SyncGlobalState]: SyncGlobalState
  [DbObjectKind.SyncBucketState]: SyncBucketState
  [DbObjectKind.DeferredUpdate]: DeferredUpdate
  [DbObjectKind.PendingTransaction]: PendingTransaction
  [DbObjectKind.ReservedChatID]: ReservedChatID
  [DbObjectKind.MessageDraft]: MessageDraft
  [DbObjectKind.HistoryCoverage]: HistoryCoverage
  [DbObjectKind.SpaceMember]: SpaceMember
  [DbObjectKind.ChatParticipant]: ChatParticipant
  [DbObjectKind.ChatParticipantGroup]: ChatParticipantGroup
  [DbObjectKind.UserGroup]: UserGroup
  [DbObjectKind.DialogFolder]: DialogFolder
  [DbObjectKind.UserSettings]: UserSettings
}

/**
 * Invariant 5. The ranges of one chat's history the server has certified as
 * complete, kept apart from cached message rows (a stored row never certifies
 * anything). Each range is inclusive, by message ID, sorted and merged; the
 * top of an open range is `HISTORY_TOP` (see `history-coverage.ts`). A chat
 * with no record has no certified history.
 */
export interface HistoryCoverage
  extends DbModelBase<DbObjectKind.HistoryCoverage, ChatID> {
  kind: DbObjectKind.HistoryCoverage
  id: ChatID
  ranges: Array<[MessageID, MessageID]>
}

export interface DbModelBase<K extends DbObjectKind, Id = string> {
  kind: K
  id: Id
}

export interface User extends DbModelBase<DbObjectKind.User> {
  kind: DbObjectKind.User
  id: UserID
  firstName?: string
  lastName?: string
  username?: string
  email?: string
  min?: boolean
  pendingSetup?: boolean
  bot?: boolean

  profilePhoto?: {
    fileUniqueId?: string
    /** not filled out */
    photoId?: PhotoID
    cdnUrl?: string
    strippedThumb?: Uint8Array
  }
}

export interface Dialog extends DbModelBase<DbObjectKind.Dialog> {
  kind: DbObjectKind.Dialog
  // driven from associated chat ID
  id: DialogID
  chatId: ChatID
  peerUserId?: UserID
  peerThreadId?: ChatID
  spaceId?: SpaceID
  archived?: boolean
  pinned?: boolean
  readMaxId?: MessageID
  unreadCount?: number
  unreadMark?: boolean
  open?: boolean
  order?: string
  pinnedOrder?: string
  chatListHidden?: boolean
  followMode?: number
  collapsedMaxId?: MessageID
  /**
   * Per-chat notification mode (`dialogNotificationSettings`). Absent: the
   * chat follows the account's global notification settings.
   */
  notificationMode?: DialogNotificationMode
  /** Personal dialog folder; absent renders the dialog flat. */
  folderId?: DialogFolderID
  /** Personal translation preference (`dialogTranslation`). */
  translationEnabled?: boolean
  /**
   * Unseen mentions of the viewer (directly, through a group, or as replies
   * to their messages) and unseen reactions to their messages, as the server
   * counts them (`unreadActivity`, dialog snapshots). Absent: not known yet.
   */
  unreadMentionsCount?: number
  unreadReactionsCount?: number
  /** Message IDs behind those counts, as far as this replica has seen them. */
  unreadMentionIds?: MessageID[]
  unreadReactionIds?: MessageID[]
}

export type DialogNotificationMode = "all" | "mentions" | "none"

export type MessageDraftKey =
  | `user:${UserID}`
  | `chat:${ChatID}`

export type MessageDraftPeer =
  | { peerKind: "user"; peerUserId: UserID }
  | { peerKind: "chat"; peerThreadId: ChatID }

export const messageDraftKey = (
  peer: MessageDraftPeer,
): MessageDraftKey =>
  peer.peerKind === "user"
    ? `user:${peer.peerUserId}`
    : `chat:${peer.peerThreadId}`

/** Local-only compose state, modeled after InlineKit Drafts2. */
export interface MessageDraft
  extends DbModelBase<DbObjectKind.MessageDraft, MessageDraftKey> {
  kind: DbObjectKind.MessageDraft
  id: MessageDraftKey
  peerKind: MessageDraftPeer["peerKind"]
  peerUserId?: UserID
  peerThreadId?: ChatID
  text: string
  entities?: MessageEntities
  revision: number
  updatedAt: number
}

export interface Chat extends DbModelBase<DbObjectKind.Chat> {
  kind: DbObjectKind.Chat
  id: ChatID
  title?: string
  spaceId?: SpaceID
  description?: string
  emoji?: string
  isPublic?: boolean
  lastMsgId?: MessageID
  date?: number
  createdBy?: UserID
  peerUserId?: UserID
  parentChatId?: ChatID
  parentMessageId?: MessageID
  untitled?: boolean
  number?: number
  canUpdateInfo?: boolean
  pinnedMessageIds?: MessageID[]
  /**
   * False when a participant grant could not be stored (its user or group is
   * not local), so the roster must be refetched before it is trusted. True
   * after a `getChatParticipants` snapshot. Absent: never fetched.
   */
  participantRosterComplete?: boolean
  /** Owner-local state for a reserved-ID create that has not completed. */
  createState?: "pending" | "failed"
}

export type MessageKey = `${ChatID}:${MessageID}`

export const messageKey = (chatId: ChatID, messageId: MessageID): MessageKey =>
  `${chatId}:${messageId}` as MessageKey

export interface Message extends DbModelBase<DbObjectKind.Message, MessageKey> {
  kind: DbObjectKind.Message
  /** Protocol message ID. Message IDs are unique only within a chat. */
  messageId: MessageID
  randomId?: bigint
  fromId: UserID
  peerUserId?: UserID
  chatId: ChatID
  message?: string
  out?: boolean
  date?: number
  mentioned?: boolean
  replyToMsgId?: MessageID
  groupedId?: bigint
  editDate?: number
  isSticker?: boolean
  hasLink?: boolean
  rev?: bigint
  media?: MessageMedia
  attachments?: MessageAttachments
  reactions?: MessageReactions
  /**
   * Owner-local optimistic overlays. They project to renderers but are
   * deliberately stripped by persistent storage because reaction RPCs are
   * not replay-safe on the current server.
   */
  reactionIntents?: ReactionMutationIntent[]
  entities?: MessageEntities
  sendMode?: MessageSendMode
  fwdFrom?: MessageFwdHeader
  replies?: MessageReplies
  actions?: MessageActions
  serviceMessage?: MessageService
  /**
   * Rich content: structural blocks over UTF-16 ranges of `message`. An edit
   * replaces it (absent clears it); other snapshots keep the stored one when
   * they leave it out (InlineKit `preserveExistingBlockContentWhenMissing`).
   */
  blockContent?: BlockContent
  /** The quoted text of the replied-to message, set at send. */
  replyQuote?: string
  /** How the message was sent (a bot or integration), set once at send. */
  via?: MessageVia
  /** The reply thread or subthread this message heads; kept when omitted. */
  subthread?: MessageSubthread
  status?: MessageSendingStatus
}

export type ReactionMutationIntent = {
  id: string
  emoji: string
  userId: UserID
  action: "add" | "delete"
}

export enum MessageSendingStatus {
  Sending = "sending",
  Sent = "sent",
  Failed = "failed",
}

// export interface Photo extends DbModelBase<DbObjectKind.Photo> {
//   kind: DbObjectKind.Photo
//   id: number
//   chatId: number
//   messageId: number
//   photoId: number
//   photo: Photo
// }

export interface Space extends DbModelBase<DbObjectKind.Space> {
  kind: DbObjectKind.Space

  id: SpaceID

  // Name of the space
  name: string

  // Whether the current user is the creator of the space
  creator: boolean

  // Date of creation
  date: number

  isPublic?: boolean
  handle?: string
  /**
   * The space bucket's sequence this snapshot or profile change reflects.
   * A profile change at or below it is already included.
   */
  seq?: number
  photoFileUniqueId?: string
  photoUrl?: string
  isPro?: boolean
  /** Space settings (`spaceSettings`, `getSpace`). */
  gridEnabled?: boolean
  /**
   * Space-bucket sequence covered by the last `getSpaceMembers` roster: a
   * member event at or below it is already in the roster.
   */
  memberRosterSeq?: number
  /** True after a roster snapshot; false after a repair that did not fetch it. */
  memberRosterComplete?: boolean
}

export interface SyncGlobalState
  extends DbModelBase<DbObjectKind.SyncGlobalState, 0> {
  kind: DbObjectKind.SyncGlobalState
  id: 0
  lastSyncDate: number
}

export interface SyncBucketState
  extends DbModelBase<DbObjectKind.SyncBucketState, string> {
  kind: DbObjectKind.SyncBucketState
  id: string
  seq: number
  date: number
}

/**
 * Lossless protocol payload retained when the lean client does not yet own a
 * materialized model for that durable update kind. Future model migrations
 * can replay these records instead of requiring a destructive cache reset.
 */
export interface DeferredUpdate
  extends DbModelBase<DbObjectKind.DeferredUpdate, string> {
  kind: DbObjectKind.DeferredUpdate
  id: string
  bucketId: string
  seq?: number
  date?: number
  payloadType: "Update" | "UserGroup"
  updateType: string
  /**
   * Denormalized resident-object key used for selective replay. A deferred
   * message update must never require hydrating the complete deferred log.
   */
  targetKey?: string
  payload: Uint8Array
}

export type PendingTransactionStatus = "pending" | "failed"

export interface PendingTransaction
  extends DbModelBase<DbObjectKind.PendingTransaction, string> {
  kind: DbObjectKind.PendingTransaction
  id: string
  type: string
  /**
   * Optional for rows written before replay policies were recorded. Legacy
   * rows are still restricted by the transaction decoder's replay-safe
   * allowlist.
   */
  replayPolicy?: "idempotent"
  context: unknown
  createdAt: number
  status: PendingTransactionStatus
}

// TODO(contract): give these their own brands in `@inline/ids`.
export type MemberID = InlineID
export type UserGroupID = InlineID
export type DialogFolderID = InlineID

export type SpaceMemberKey = `${SpaceID}:${UserID}`
export const spaceMemberKey = (
  spaceId: SpaceID,
  userId: UserID,
): SpaceMemberKey => `${spaceId}:${userId}` as SpaceMemberKey

export type SpaceMemberRole = "owner" | "admin" | "member"

/**
 * One membership of a space (InlineKit `Member`). Keyed by the natural
 * identity (space, user); `memberId` is the server's immutable membership
 * generation, so a delayed event for an older generation is ignored.
 */
export interface SpaceMember
  extends DbModelBase<DbObjectKind.SpaceMember, SpaceMemberKey> {
  kind: DbObjectKind.SpaceMember
  id: SpaceMemberKey
  memberId: MemberID
  spaceId: SpaceID
  userId: UserID
  role?: SpaceMemberRole
  /** Protocol seconds: date of joining. */
  date: number
  canAccessPublicChats: boolean
}

export type ChatParticipantKey = `${ChatID}:${UserID}`
export const chatParticipantKey = (
  chatId: ChatID,
  userId: UserID,
): ChatParticipantKey => `${chatId}:${userId}` as ChatParticipantKey

/** A direct participant grant of a chat (InlineKit `ChatParticipant`). */
export interface ChatParticipant
  extends DbModelBase<DbObjectKind.ChatParticipant, ChatParticipantKey> {
  kind: DbObjectKind.ChatParticipant
  id: ChatParticipantKey
  chatId: ChatID
  userId: UserID
  date: number
}

export type ChatParticipantGroupKey = `${ChatID}:${UserGroupID}`
export const chatParticipantGroupKey = (
  chatId: ChatID,
  groupId: UserGroupID,
): ChatParticipantGroupKey => `${chatId}:${groupId}` as ChatParticipantGroupKey

/** A user-group grant of a chat (InlineKit `ChatParticipantGroup`). */
export interface ChatParticipantGroup
  extends DbModelBase<
    DbObjectKind.ChatParticipantGroup,
    ChatParticipantGroupKey
  > {
  kind: DbObjectKind.ChatParticipantGroup
  id: ChatParticipantGroupKey
  chatId: ChatID
  groupId: UserGroupID
  date: number
}

/** A user group of a space, for group mentions (InlineKit `UserGroup`). */
export interface UserGroup
  extends DbModelBase<DbObjectKind.UserGroup, UserGroupID> {
  kind: DbObjectKind.UserGroup
  id: UserGroupID
  spaceId: SpaceID
  name: string
  description?: string
  memberCount: number
  userIds: UserID[]
  currentUserIsMember: boolean
  date: number
}

/** A personal dialog folder (InlineKit `DialogFolder`). */
export interface DialogFolder
  extends DbModelBase<DbObjectKind.DialogFolder, DialogFolderID> {
  kind: DbObjectKind.DialogFolder
  id: DialogFolderID
  title?: string
  /** Fractional order, the same coordinate as `Dialog.order`. */
  order: string
  emoji?: string
  /** Present when pinned: the coordinate in the shared pinned lane. */
  pinnedOrder?: string
}

export type NotificationMode =
  | "all"
  | "none"
  | "mentions"
  | "importantOnly"
  | "onlyMentions"

/**
 * The account's settings (InlineKit `INUserSettings`), one row. The server
 * sends the whole merged settings in every `updateUserSettings`; a group
 * the server leaves out keeps its stored value.
 */
export interface UserSettings
  extends DbModelBase<DbObjectKind.UserSettings, 0> {
  kind: DbObjectKind.UserSettings
  id: 0
  notifications?: {
    mode?: NotificationMode
    silent?: boolean
    zenModeRequiresMention?: boolean
    zenModeUsesDefaultRules?: boolean
    zenModeCustomRules?: string
    disableDmNotifications?: boolean
  }
  privacy?: {
    shareTimeZone?: boolean
    appearInGlobalSearch?: boolean
    timeZone?: PrivacyRule
    focusStatus?: PrivacyRule
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

/** Persisted owner-only pool entry matching InlineKit ReservedChatID. */
export interface ReservedChatID
  extends DbModelBase<DbObjectKind.ReservedChatID, ChatID> {
  kind: DbObjectKind.ReservedChatID
  id: ChatID
  chatId: ChatID
  /** Protocol seconds since Unix epoch. */
  expiresAt: number
  /** Local milliseconds since Unix epoch, used for FIFO consumption. */
  createdAt: number
}
import type {
  ChatID,
  DialogID,
  InlineID,
  MessageID,
  PhotoID,
  SpaceID,
  UserID,
} from "@inline/ids"
import type {
  MessageActions,
  MessageAttachments,
  MessageEntities,
  MessageFwdHeader,
  MessageMedia,
  MessageReactions,
  MessageReplies,
  MessageSendMode,
  MessageService,
  MessageSubthread,
  MessageVia,
  BlockContent,
  PrivacyRule,
} from "@inline-chat/protocol/core"
