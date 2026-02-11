import type {
  Message,
  Method,
  Peer,
  Reaction,
  RpcCall,
  RpcResult,
  Update,
  UpdateBucket,
  UpdatesPayload,
} from "@inline-chat/protocol/core"
import type { InlineId } from "../ids.js"
import type { InlineUnixSeconds } from "../time.js"
import type { InlineSdkLogger } from "./logger.js"
import type { Transport } from "../realtime/transport.js"

export type InlineSdkClientOptions = {
  baseUrl?: string // e.g. https://api.inline.chat
  token: string
  logger?: InlineSdkLogger
  state?: InlineSdkStateStore
  transport?: Transport
}

export type InlineInboundEvent =
  | { kind: "message.new"; chatId: InlineId; message: Message; seq: number; date: InlineUnixSeconds }
  | { kind: "message.edit"; chatId: InlineId; message: Message; seq: number; date: InlineUnixSeconds }
  | { kind: "message.delete"; chatId: InlineId; messageIds: InlineId[]; seq: number; date: InlineUnixSeconds }
  | { kind: "reaction.add"; chatId: InlineId; reaction: Reaction; seq: number; date: InlineUnixSeconds }
  | { kind: "reaction.delete"; chatId: InlineId; emoji: string; messageId: InlineId; userId: InlineId; seq: number; date: InlineUnixSeconds }
  | { kind: "chat.hasUpdates"; chatId: InlineId; seq: number; date: InlineUnixSeconds }
  | { kind: "space.hasUpdates"; spaceId: InlineId; seq: number; date: InlineUnixSeconds }

export type InlineSdkState = {
  version: 1
  dateCursor?: InlineUnixSeconds
  lastSeqByChatId?: Record<string, number>
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
