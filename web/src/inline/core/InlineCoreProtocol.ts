import type {
  AuthSession,
  CoreTransactionEnvelope,
  DbResidentChangeBatch,
  DbResidentSnapshot,
  LocalMessageWindowAroundOptions,
  Message,
  MessageKey,
  MessageWindowCursor,
  RealtimeConnectionState,
  CreateThreadInput,
} from "@inline/client/core"
import { DbObjectKind } from "@inline/client/core"
import type {
  ChatID,
  MessageID,
  UserID,
} from "@inline/ids"
import type { MessageDraftPeer } from "@inline/client/core"
import type {
  InputPeer,
  MessageEntities,
  RpcResult,
} from "@inline-chat/protocol/core"
import type { InlineMediaResource } from "../media/InlineMediaLoader"

/**
 * Increment this only for an incompatible renderer/core-owner handshake.
 * Domain payload schemas remain independently versioned.
 */
export const INLINE_CORE_PROTOCOL_VERSION = 17 as const

export const INLINE_CORE_RENDERER_KINDS = [
  DbObjectKind.User,
  DbObjectKind.Space,
  DbObjectKind.Chat,
  DbObjectKind.Dialog,
  DbObjectKind.Message,
  DbObjectKind.MessageDraft,
] as const

export type InlineCoreProtocolVersion =
  typeof INLINE_CORE_PROTOCOL_VERSION

export type InlineCorePhase =
  | "idle"
  | "openingStorage"
  | "hydratingNavigation"
  | "cacheReady"
  | "connecting"
  | "syncing"
  | "ready"
  | "error"
  | "stopped"

export type InlineCoreIdentity = {
  protocolVersion: InlineCoreProtocolVersion
  ownerId: string
  accountId: UserID
}

export type InlineCoreBlockingFailure = {
  code:
    | "storage-unavailable"
    | "owner-unavailable"
    | "owner-unresponsive"
    | "protocol-incompatible"
  message: string
  recoveryAction: "reload"
}

export type InlineCoreSyncIssue = {
  code: "initial-sync-unavailable"
  message: string
}

export type InlineCoreSnapshot = InlineCoreIdentity & {
  phase: InlineCorePhase
  cacheReady: boolean
  connectionState: RealtimeConnectionState
  blockingFailure?: InlineCoreBlockingFailure
  syncIssue?: InlineCoreSyncIssue
}

export type InlineCoreHello = {
  type: "inlineCoreHello"
  protocolVersion: InlineCoreProtocolVersion
  clientId: string
  accountId: UserID
  session: AuthSession
  lifecycle: InlineCoreClientLifecycle
}

export type InlineCoreReady = {
  type: "inlineCoreReady"
  identity: InlineCoreIdentity
  snapshot: InlineCoreSnapshot
  projection: InlineCoreProjection
}

export type InlineCoreProjection = DbResidentSnapshot & {
  messageWindowKeys: MessageKey[]
}

export type InlineCoreProjectionChanges = DbResidentChangeBatch & {
  messageWindowKeys: MessageKey[]
}

export type InlineCoreClientLifecycle = {
  visible: boolean
  online: boolean
}

export type InlineCoreClientMessage =
  | InlineCoreHello
  | {
      type: "inlineCoreExecute"
      requestId: string
      transaction: CoreTransactionEnvelope
    }
  | {
      type: "inlineCoreMutateAccepted"
      requestId: string
      transaction: CoreTransactionEnvelope
    }
  | {
      type: "inlineCoreCreateThread"
      requestId: string
      input: CreateThreadInput
    }
  | {
      type: "inlineCoreResendMessage"
      requestId: string
      chatId: ChatID
      messageId: MessageID
    }
  | {
      type: "inlineCoreHydrateMessageWindow"
      requestId: string
      chatId: ChatID
      limit: number
      before?: MessageWindowCursor
      after?: MessageWindowCursor
    }
  | {
      type: "inlineCoreLoadLocalWindowAroundMessage"
      requestId: string
      chatId: ChatID
      window: LocalMessageWindowAroundOptions
    }
  | {
      type: "inlineCoreLoadMedia"
      requestId: string
      key: string
      remoteUrl: string
    }
  | {
      type: "inlineCoreLoadCachedMedia"
      requestId: string
      key: string
    }
  | {
      type: "inlineCoreLoadMessageDraft"
      requestId: string
      peer: MessageDraftPeer
    }
  | {
      type: "inlineCoreLoadMessageReferences"
      requestId: string
      peerId: InputPeer
      chatId: ChatID
      messageIds: MessageID[]
    }
  | {
      type: "inlineCoreUpdateMessageDraft"
      requestId: string
      peer: MessageDraftPeer
      text: string
      entities?: MessageEntities
    }
  | {
      type: "inlineCoreClearMessageDraft"
      requestId: string
      peer: MessageDraftPeer
    }
  | {
      type: "inlineCoreCancelMedia"
      requestId: string
    }
  | {
      type: "inlineCoreLifecycle"
      requestId: string
      lifecycle: InlineCoreClientLifecycle
    }
  | {
      type: "inlineCoreSetActiveChats"
      chatIds: ChatID[]
    }
  | {
      type: "inlineCoreVisibleMessageRange"
      chatId: ChatID
      firstVisibleMessageId: MessageID
      lastVisibleMessageId: MessageID
    }
  | { type: "inlineCoreHeartbeat"; nonce: string }
  | { type: "inlineCoreWake" }
  | { type: "inlineCoreResync" }
  | { type: "inlineCoreStopSession"; requestId: string }
  | { type: "inlineCoreDetach" }

export type InlineCoreProtocolErrorCode =
  | "incompatible-version"
  | "invalid-message"
  | "not-attached"
  | "account-mismatch"
  | "request-failed"
  | "owner-failed"

export type InlineCoreHostMessage =
  | {
      type: "inlineCoreHandshakeAccepted"
      protocolVersion: InlineCoreProtocolVersion
      accountId: UserID
    }
  | InlineCoreReady
  | {
      type: "inlineCoreSnapshot"
      snapshot: InlineCoreSnapshot
    }
  | {
      type: "inlineCoreProjection"
      projection: InlineCoreProjection
    }
  | {
      type: "inlineCoreChanges"
      batch: InlineCoreProjectionChanges
    }
  | {
      type: "inlineCoreResult"
      requestId: string
      result?: RpcResult["result"]
      chatId?: ChatID
      count?: number
      found?: boolean
      media?: InlineMediaResource
      messageReferences?: Message[]
    }
  | {
      type: "inlineCoreAuthInvalidated"
    }
  | {
      type: "inlineCoreHeartbeatAck"
      nonce: string
      ownerId: string
    }
  | {
      type: "inlineCoreError"
      code: InlineCoreProtocolErrorCode
      message: string
      requestId?: string
    }

export const isCompatibleInlineCore = (
  ready: InlineCoreReady,
): boolean =>
  ready.identity.protocolVersion ===
  INLINE_CORE_PROTOCOL_VERSION
