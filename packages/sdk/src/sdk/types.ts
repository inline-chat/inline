import type {
  BotCapability,
  BotChatSettingsResponse,
  BotChatSettingsValue,
  ChatParticipant,
  ChatParticipantGroup,
  DialogFollowMode,
  Message,
  MessageActionResponseUi,
  MessageActions,
  MessageEntities,
  Peer,
  Reaction,
  RpcCall,
  RpcResult,
  Update,
  UpdateBucket,
  UpdatesPayload,
} from "@inline-chat/protocol/core"
import type { InlineId, InlineIdLike } from "../ids.js"
import type { InlineUnixSeconds } from "../time.js"
import type { InlineSdkLogger } from "./logger.js"
import type { Transport } from "../realtime/transport.js"
import type { InlineSdkAuthenticationError } from "./errors.js"
import type { InlineProtocolPublicKey } from "../realtime/v3-connection.js"
import type { InlineProtocolV3Credentials } from "../realtime/v3-client.js"

type InlineSdkClientCommonOptions = {
  baseUrl?: string // e.g. https://api.inline.chat
  // Default timeout used by response-waiting RPC calls.
  // Defaults to 30_000 ms. Set to `null`, `Infinity`, or `<= 0` for no timeout.
  rpcTimeoutMs?: number | null
  logger?: InlineSdkLogger
  state?: InlineSdkStateStore
  catchUpUserFromStart?: boolean
  transport?: Transport
  fetch?: typeof fetch
  onAuthenticationError?: (error: InlineSdkAuthenticationError) => void
  /** Durable authority owner used by logout. close() never invokes these callbacks. */
  credentialOwner?: InlineSdkCredentialOwner
  /**
   * Optional stronger replacement owner for hosts with materialized state.
   * The callback must durably apply a complete bucket snapshot before returning
   * its cursor; partial overlays must fail. Event-only hosts may omit it: the
   * SDK replays bounded ranges and retains a server-authoritative liveness leap.
   */
  repairUpdatesBucket?: (
    request: InlineSdkAuthoritativeRepairRequest,
  ) => InlineSdkAuthoritativeRepairResult | Promise<InlineSdkAuthoritativeRepairResult>
}

export type InlineSdkCredentialOwner = {
  /**
   * Persist a durable logout marker. Credential storage used by
   * inlineProtocol.onCredentials must reject stale writes after this resolves.
   */
  beginLogout(): void | Promise<void>
  clearCredentials(): void | Promise<void>
  finishLogout(): void | Promise<void>
}

export type InlineSdkLogoutResult = {
  remoteOutcome: "confirmed" | "commitUnknown" | "notSent"
}

export type InlineSdkUpdateBucketRef =
  | { kind: "user" }
  | { kind: "chat"; chatId: InlineId; peer?: Peer }
  | { kind: "space"; spaceId: InlineId }

export type InlineSdkAuthoritativeRepairRequest = {
  bucket: InlineSdkUpdateBucketRef
  serverSeq: number
  serverDate: InlineUnixSeconds
}

export type InlineSdkAuthoritativeRepairResult = {
  /** Cursor whose complete authoritative state the callback durably applied. */
  appliedSeq: number
  dateCursor?: InlineUnixSeconds
}

export type InlineSdkSyncStatus = {
  state: "live" | "syncing" | "degraded"
  degradedBuckets: readonly InlineSdkUpdateBucketRef[]
}

export type InlineSdkProtocolV3Options = {
  credentials: InlineProtocolV3Credentials
  /** Defaults to Inline's pinned overlapping production ring. Override for custom servers. */
  rsaPublicKeys?: readonly InlineProtocolPublicKey[]
  realtimeUrl?: string
  /**
   * Persist replacement authority before it is used. The storage owner must
   * reject a write that races after credentialOwner.beginLogout() completes.
   */
  onCredentials?: (credentials: InlineProtocolV3Credentials) => void | Promise<void>
}

export type InlineSdkClientOptions = InlineSdkClientCommonOptions & (
  | { token: string; inlineProtocol?: never }
  | { token?: never; inlineProtocol: InlineSdkProtocolV3Options }
)

export type InlineSdkChatInfo = {
  chatId: InlineId
  title: string
  peer?: Peer
  spaceId?: InlineId
  parentChatId?: InlineId
  parentMessageId?: InlineId
  lastMsgId?: InlineId
  dialogFollowMode?: DialogFollowMode
  isPublic?: boolean
  untitled?: boolean
  number?: number
}

export type InlineSdkSendMessageMedia =
  | { kind: "photo"; photoId: InlineIdLike }
  | { kind: "video"; videoId: InlineIdLike }
  | { kind: "document"; documentId: InlineIdLike }
  | { kind: "voice"; voiceId: InlineIdLike }

export type InlineSdkSendMessageParams =
  | {
      chatId: InlineIdLike
      userId?: never
      text?: string
      media?: InlineSdkSendMessageMedia
      /** Stable non-zero signed 64-bit idempotency key. Generated when omitted. */
      randomId?: bigint
      replyToMsgId?: InlineIdLike
      parseMarkdown?: boolean
      sendMode?: "silent"
      entities?: MessageEntities
      actions?: MessageActions
    }
  | {
      userId: InlineIdLike
      chatId?: never
      text?: string
      media?: InlineSdkSendMessageMedia
      /** Stable non-zero signed 64-bit idempotency key. Generated when omitted. */
      randomId?: bigint
      replyToMsgId?: InlineIdLike
      parseMarkdown?: boolean
      sendMode?: "silent"
      entities?: MessageEntities
      actions?: MessageActions
    }

export type InlineSdkInvokeMessageActionParams =
  | {
      chatId: InlineIdLike
      userId?: never
      messageId: InlineIdLike
      actionId: string
    }
  | {
      userId: InlineIdLike
      chatId?: never
      messageId: InlineIdLike
      actionId: string
    }

export type InlineSdkAnswerMessageActionParams = {
  interactionId: InlineIdLike
  ui?: MessageActionResponseUi
}

export type InlineSdkPeerTarget =
  | { chatId: InlineIdLike; userId?: never }
  | { userId: InlineIdLike; chatId?: never }

export type InlineSdkSetMyBotCapabilitiesParams = {
  capabilities: BotCapability[]
}

export type InlineSdkRequestBotChatSettingsParams = InlineSdkPeerTarget & {
  botUserId: InlineIdLike
  version?: number
}

export type InlineSdkInvokeBotChatSettingsItemParams = InlineSdkPeerTarget & {
  botUserId: InlineIdLike
  version?: number
  itemId: string
  value?: BotChatSettingsValue
  documentRevision: string
}

export type InlineSdkAnswerBotChatSettingsParams = {
  requestId: InlineIdLike
  response: BotChatSettingsResponse
}

export type InlineSdkGetMessagesParams =
  | {
      chatId: InlineIdLike
      userId?: never
      messageIds: InlineIdLike[]
    }
  | {
      userId: InlineIdLike
      chatId?: never
      messageIds: InlineIdLike[]
    }

export type InlineSdkClearChatHistoryParams =
  | {
      chatId: InlineIdLike
      userId?: never
      spaceId?: never
      keepLastDays: number
      deleteReplyThreads?: boolean
    }
  | {
      userId: InlineIdLike
      chatId?: never
      spaceId?: never
      keepLastDays: number
      deleteReplyThreads?: boolean
    }
  | {
      spaceId: InlineIdLike
      chatId?: never
      userId?: never
      keepLastDays: number
      deleteReplyThreads?: boolean
    }

export type InlineSdkBotPresenceStateKind =
  | "idle"
  | "happy"
  | "waving"
  | "jumping"
  | "failed"
  | "waiting"
  | "running"
  | "review"

export type InlineSdkSetBotPresenceStateParams =
  | {
      chatId: InlineIdLike
      userId?: never
      kind: InlineSdkBotPresenceStateKind
      comment?: string
    }
  | {
      userId: InlineIdLike
      chatId?: never
      kind: InlineSdkBotPresenceStateKind
      comment?: string
    }

export type InlineSdkBinaryInput =
  | Blob
  | Uint8Array
  | ArrayBuffer
  | SharedArrayBuffer

export type InlineSdkUploadFileType = "photo" | "video" | "document" | "voice"

export type InlineSdkUploadFileParams = {
  type: InlineSdkUploadFileType
  file: InlineSdkBinaryInput
  fileName?: string
  contentType?: string
  thumbnail?: InlineSdkBinaryInput
  thumbnailFileName?: string
  thumbnailContentType?: string
  width?: number
  height?: number
  duration?: number
  isAnimated?: boolean
  hasAudio?: boolean
  waveform?: Uint8Array
  clientUploadId?: Uint8Array
  signal?: AbortSignal
  onProgress?: (progress: { acceptedBytes: number; totalBytes: number }) => void
}

export type InlineSdkUploadFileResult = {
  fileUniqueId: string
  photoId?: bigint
  videoId?: bigint
  documentId?: bigint
  voiceId?: bigint
}

export type InlineInboundEvent =
  | {
      kind: "bot.chatSettings.request"
      requestId: InlineId
      chatId: InlineId
      actorUserId: InlineId
      version: number
    }
  | {
      kind: "bot.chatSettings.item.invoke"
      requestId: InlineId
      chatId: InlineId
      actorUserId: InlineId
      version: number
      itemId: string
      value?: BotChatSettingsValue
      documentRevision: string
    }
  | { kind: "message.new"; chatId: InlineId; message: Message; seq: number; date: InlineUnixSeconds }
  | { kind: "message.edit"; chatId: InlineId; message: Message; seq: number; date: InlineUnixSeconds }
  | { kind: "message.delete"; chatId: InlineId; messageIds: InlineId[]; seq: number; date: InlineUnixSeconds }
  | ({
      kind: "message.history.clear"
      beforeDate?: InlineUnixSeconds
      deleteReplyThreads: boolean
      deletedChatIds: InlineId[]
      orphanedChatIds: InlineId[]
      detachedChatIds: InlineId[]
      seq: number
      date: InlineUnixSeconds
    } & ({ chatId: InlineId; userId?: never } | { userId: InlineId; chatId?: never }))
  | {
      kind: "space.history.clear"
      spaceId: InlineId
      beforeDate?: InlineUnixSeconds
      deleteReplyThreads: boolean
      deletedChatIds: InlineId[]
      orphanedChatIds: InlineId[]
      detachedChatIds: InlineId[]
      seq: number
      date: InlineUnixSeconds
    }
  | { kind: "reaction.add"; chatId: InlineId; reaction: Reaction; seq: number; date: InlineUnixSeconds }
  | { kind: "reaction.delete"; chatId: InlineId; emoji: string; messageId: InlineId; userId: InlineId; seq: number; date: InlineUnixSeconds }
  | { kind: "chat.participant.add"; chatId: InlineId; participant?: ChatParticipant; seq: number; date: InlineUnixSeconds }
  | { kind: "chat.participant.delete"; chatId: InlineId; userId: InlineId; seq: number; date: InlineUnixSeconds }
  | {
      kind: "chat.access.added"
      chatId: InlineId
      participant?: ChatParticipant
      group?: ChatParticipantGroup
      seq: number
      date: InlineUnixSeconds
    }
  | {
      kind: "chat.access.removed"
      chatId: InlineId
      groupId?: InlineId
      seq: number
      date: InlineUnixSeconds
    }
  | {
      kind: "message.action.invoke"
      interactionId: InlineId
      chatId: InlineId
      messageId: InlineId
      actorUserId: InlineId
      actionId: string
      data: Uint8Array
      seq: number
      date: InlineUnixSeconds
    }
  | {
      kind: "message.action.answered"
      interactionId: InlineId
      ui?: MessageActionResponseUi
      seq: number
      date: InlineUnixSeconds
    }
  | { kind: "chat.hasUpdates"; chatId: InlineId; seq: number; date: InlineUnixSeconds }
  | { kind: "space.hasUpdates"; spaceId: InlineId; seq: number; date: InlineUnixSeconds }

export type InlineSdkState = {
  version: 1
  dateCursor?: InlineUnixSeconds
  lastSeqByChatId?: Record<string, number>
  chatPeerByChatId?: Record<string, InlineSdkPersistedChatPeer>
  lastSeqBySpaceId?: Record<string, number>
  lastUserSeq?: number
}

export type InlineSdkPersistedChatPeer = {
  kind: "user" | "chat"
  id: string
}

export interface InlineSdkStateStore {
  load(): Promise<InlineSdkState | null>
  save(next: InlineSdkState): Promise<void>
}

export type RpcInputKind = RpcCall["input"]["oneofKind"]
export type RpcResultKind = RpcResult["result"]["oneofKind"]

export const rpcInputKindByMethod = {
  0: undefined, // UNSPECIFIED
  1: "getMe",
  2: "sendMessage",
  3: "getPeerPhoto",
  4: "deleteMessages",
  5: "getChatHistory",
  6: "addReaction",
  7: "deleteReaction",
  8: "editMessage",
  9: "createChat",
  10: "getSpaceMembers",
  11: "deleteChat",
  12: "inviteToSpace",
  13: "getChatParticipants",
  14: "addChatParticipant",
  15: "removeChatParticipant",
  16: "translateMessages",
  17: "getChats",
  18: "updateUserSettings",
  19: "getUserSettings",
  20: "sendComposeAction",
  21: "createBot",
  22: "deleteMember",
  23: "markAsUnread",
  24: "getUpdatesState",
  25: "getChat",
  26: "getUpdates",
  27: "updateMemberAccess",
  28: "searchMessages",
  29: "forwardMessages",
  30: "updateChatVisibility",
  31: "pinMessage",
  32: "updateChatInfo",
  33: "listBots",
  34: "revealBotToken",
  35: "moveThread",
  36: "rotateBotToken",
  37: "updateBotProfile",
  38: "getMessages",
  56: "setBotAvatar",
  57: "clearBotAvatar",
  58: "getBotPresence",
  59: "setBotPresenceState",
  48: "invokeMessageAction",
  49: "answerMessageAction",
  53: "clearChatHistory",
  61: "getSessions",
  62: "checkUsername",
  63: "changeUsername",
  64: "updateProfile",
  76: "getPeerBots",
  77: "getMyBotCapabilities",
  78: "setMyBotCapabilities",
  79: "requestBotChatSettings",
  80: "invokeBotChatSettingsItem",
  81: "answerBotChatSettings",
  106: "createBotAgent",
  107: "getBotAgent",
  108: "listBotAgents",
  117: "createUpload",
  118: "saveUploadPart",
  119: "getUploadState",
  120: "finishUpload",
  121: "cancelUpload",
  127: "getSpace",
  131: "updateBotAgent",
  132: "deleteBotAgent",
} as const satisfies Record<number, RpcInputKind | undefined>

export const rpcResultKindByMethod = {
  0: undefined, // UNSPECIFIED
  1: "getMe",
  2: "sendMessage",
  3: "getPeerPhoto",
  4: "deleteMessages",
  5: "getChatHistory",
  6: "addReaction",
  7: "deleteReaction",
  8: "editMessage",
  9: "createChat",
  10: "getSpaceMembers",
  11: "deleteChat",
  12: "inviteToSpace",
  13: "getChatParticipants",
  14: "addChatParticipant",
  15: "removeChatParticipant",
  16: "translateMessages",
  17: "getChats",
  18: "updateUserSettings",
  19: "getUserSettings",
  20: "sendComposeAction",
  21: "createBot",
  22: "deleteMember",
  23: "markAsUnread",
  24: "getUpdatesState",
  25: "getChat",
  26: "getUpdates",
  27: "updateMemberAccess",
  28: "searchMessages",
  29: "forwardMessages",
  30: "updateChatVisibility",
  31: "pinMessage",
  32: "updateChatInfo",
  33: "listBots",
  34: "revealBotToken",
  35: "moveThread",
  36: "rotateBotToken",
  37: "updateBotProfile",
  38: "getMessages",
  56: "setBotAvatar",
  57: "clearBotAvatar",
  58: "getBotPresence",
  59: "setBotPresenceState",
  48: "invokeMessageAction",
  49: "answerMessageAction",
  53: "clearChatHistory",
  61: "getSessions",
  62: "checkUsername",
  63: "changeUsername",
  64: "updateProfile",
  76: "getPeerBots",
  77: "getMyBotCapabilities",
  78: "setMyBotCapabilities",
  79: "requestBotChatSettings",
  80: "invokeBotChatSettingsItem",
  81: "answerBotChatSettings",
  106: "createBotAgent",
  107: "getBotAgent",
  108: "listBotAgents",
  117: "createUpload",
  118: "saveUploadPart",
  119: "getUploadState",
  120: "finishUpload",
  121: "cancelUpload",
  127: "getSpace",
  131: "updateBotAgent",
  132: "deleteBotAgent",
} as const satisfies Record<number, RpcResultKind | undefined>

type RpcInputKindByMethod = typeof rpcInputKindByMethod
type RpcResultKindByMethod = typeof rpcResultKindByMethod

export type MappedMethod = keyof RpcInputKindByMethod & keyof RpcResultKindByMethod

export type RpcInputForMethod<M extends MappedMethod> = RpcInputKindByMethod[M] extends RpcInputKind
  ? Extract<RpcCall["input"], { oneofKind: RpcInputKindByMethod[M] }>
  : Extract<RpcCall["input"], { oneofKind: undefined }>

export type RpcResultForMethod<M extends MappedMethod> = RpcResultKindByMethod[M] extends RpcResultKind
  ? Extract<RpcResult["result"], { oneofKind: RpcResultKindByMethod[M] }>
  : Extract<RpcResult["result"], { oneofKind: undefined }>

// Internal helper types for SDK runtime.
export type RawUpdatesEvent = {
  updates: UpdatesPayload
}

export type UpdateHandlerContext = {
  emit: (event: InlineInboundEvent) => Promise<void>
  catchUpChat?: (params: { chatId: InlineId; peer?: Peer; updateSeq: number; update: Update }) => Promise<void>
  catchUpSpace?: (params: { spaceId: InlineId; updateSeq: number; update: Update }) => Promise<void>
  updateBucketForChat: (params: { chatId: InlineId; peer?: Peer }) => UpdateBucket
}
