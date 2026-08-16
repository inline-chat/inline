export { BOT_DEFAULT_UPDATE_KEYS, BOT_ID_MAX } from "@inline-chat/bot-api-types"

export type {
  BotActivationReason,
  BotApiEnvelope,
  BotApiError,
  BotApiSuccess,
  BotAttachment,
  BotChat,
  BotChatParticipant,
  BotSpaceMember,
  BotChatLastMessage,
  BotChatType,
  BotCommand,
  BotDefaultUpdateKey,
  BotEventChat,
  BotEventMessage,
  BotFile,
  BotInputId,
  BotMedia,
  BotParticipationChange,
  BotMessageAction,
  BotMessageEntityType,
  BotMessage,
  BotMessageEntityInput,
  BotMessageEntityOutput,
  BotMessageLite,
  BotMessageReaction,
  BotMessageTrigger,
  BotMethodEnvelope,
  BotMethodName,
  BotMethodParams,
  BotMethodParamsByName,
  BotMethodResult,
  BotMethodResultByName,
  BotPeer,
  BotTargetInput,
  BotUpdate,
  BotUpdateKey,
  BotUser,
  BotReaction,
  BotSearchFilter,
  CreateReplyThreadParams,
  CreateReplyThreadResult,
  CreateThreadParams,
  CreateThreadResult,
  AnswerMessageActionParams,
  BotChatAction,
  DeleteReactionParams,
  DeleteWebhookParams,
  DeleteWebhookResult,
  DeleteMessageParams,
  ForwardMessageParams,
  ForwardMessageResult,
  EditMessageTextParams,
  EditMessageTextResult,
  EmptyResult,
  GetChatHistoryParams,
  GetChatHistoryResult,
  GetChatParams,
  GetChatResult,
  GetChatParticipantParams,
  GetChatParticipantResult,
  GetChatParticipantCountParams,
  GetChatParticipantCountResult,
  GetFileParams,
  GetFileResult,
  GetMeResult,
  GetMessagesParams,
  GetMessagesResult,
  GetUpdatesParams,
  GetUpdatesResult,
  GetWebhookInfoResult,
  GetMyCommandsResult,
  SetMyCommandsParams,
  SendMessageParams,
  SendMessageResult,
  SendReactionParams,
  SendChatActionParams,
  PinMessageParams,
  UnpinMessageParams,
  SetThreadTitleParams,
  SearchMessagesParams,
  SearchMessagesResult,
  SetWebhookParams,
  SetWebhookResult,
  WebhookInfo,
  UploadFileParams,
  UploadFileResult,
} from "@inline-chat/bot-api-types"

export type InlineBotApiClientOptions = {
  // Defaults to https://api.inline.chat
  baseUrl?: string
  token: string
  authMode?: "header" | "path"

  // Dependency injection for tests / alternate runtimes.
  fetch?: typeof fetch
}

export type InlineBotApiRequestOptions = {
  method?: "GET" | "POST" | "PUT" | "PATCH" | "DELETE"
  headers?: Record<string, string>
  body?: unknown
  query?: Record<string, unknown>
  signal?: AbortSignal
}

export type InlineBotApiResponse<T> = {
  status: number
  headers: Headers
  data: T
}

export type InlineBotApiPostEncoding = "json" | "query"

export type InlineBotApiMethodOptions = {
  headers?: Record<string, string>
  signal?: AbortSignal
  // For POST methods only. Defaults to "json".
  postAs?: InlineBotApiPostEncoding
}
