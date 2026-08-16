export { InlineSdkClient } from "./sdk/inline-sdk-client.js"
export {
  InlineSdkAuthenticationError,
  type InlineSdkAuthenticationErrorCode,
} from "./sdk/errors.js"
export { registerBotCapabilitiesWithRetry } from "./sdk/bot-capabilities.js"
export type {
  InlineSdkClientOptions,
  InlineSdkBotPresenceStateKind,
  InlineSdkGetMessagesParams,
  InlineSdkPeerTarget,
  InlineSdkRequestBotChatSettingsParams,
  InlineSdkInvokeBotChatSettingsItemParams,
  InlineSdkAnswerBotChatSettingsParams,
  InlineSdkInvokeMessageActionParams,
  InlineSdkAnswerMessageActionParams,
  InlineSdkSendMessageMedia,
  InlineSdkSendMessageParams,
  InlineSdkSetBotPresenceStateParams,
  InlineSdkSetMyBotCapabilitiesParams,
  InlineSdkState,
  InlineSdkStateStore,
  InlineSdkUploadFileParams,
  InlineSdkUploadFileResult,
  InlineSdkUploadFileType,
  InlineInboundEvent,
  RpcInputForMethod,
  RpcResultForMethod,
} from "./sdk/types.js"
export type { InlineSdkLogger } from "./sdk/logger.js"
export {
  INLINE_FOLLOW_MODE_MENTION_FRESH_LAST_MESSAGE_ID_LIMIT,
  isInlineFollowModeMentionGateEligible,
  isInlineFreshThreadForMentionGate,
  isInlineReplyThreadForMentionGate,
} from "./sdk/thread-mention-gating.js"
export type {
  InlineFollowModeMentionGateChat,
  InlineMentionGateIdLike,
} from "./sdk/thread-mention-gating.js"

export { JsonFileStateStore } from "./state/json-file-state-store.js"
export { serializeStateV1, deserializeStateV1 } from "./state/serde.js"

export type { InlineId, InlineIdLike } from "./ids.js"
export { asInlineId } from "./ids.js"

export type { InlineUnixSeconds, InlineUnixSecondsLike } from "./time.js"
export { asInlineUnixSeconds } from "./time.js"

export {
  InlineProtocolV3Connection,
  InlineProtocolV3Error,
  type InlineProtocolAuthorization,
  type InlineProtocolPublicKey,
  type InlineProtocolV3ConnectionOptions,
} from "./realtime/v3-connection.js"
export {
  InlineRealtimeV3Client,
  type InlineProtocolV3Credentials,
  type InlineRealtimeV3ClientOptions,
} from "./realtime/v3-client.js"

// Re-export the full protocol surface for convenience.
export * from "@inline-chat/protocol"
