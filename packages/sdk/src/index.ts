export { InlineSdkClient } from "./sdk/inline-sdk-client.js"
export type {
  InlineSdkClientOptions,
  InlineSdkGetMessagesParams,
  InlineSdkSendMessageMedia,
  InlineSdkSendMessageParams,
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

export { JsonFileStateStore } from "./state/json-file-state-store.js"
export { serializeStateV1, deserializeStateV1 } from "./state/serde.js"

export type { InlineId, InlineIdLike } from "./ids.js"
export { asInlineId } from "./ids.js"

export type { InlineUnixSeconds, InlineUnixSecondsLike } from "./time.js"
export { asInlineUnixSeconds } from "./time.js"

// Re-export the full protocol surface for convenience.
export * from "@inline-chat/protocol"
