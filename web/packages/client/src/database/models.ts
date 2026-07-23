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
}

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
} from "@inline-chat/protocol/core"
