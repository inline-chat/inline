export type {
  BotApiEnvelope,
  BotApiError,
  BotApiSuccess,
  BotChat,
  BotChatLastMessage,
  BotCommand,
  BotInputRichMessage,
  BotInputId,
  BotMessageEntityType,
  BotMessage,
  BotRichBlock,
  BotRichBlockType,
  BotRichDirection,
  BotRichHtmlInput,
  BotRichInputOptions,
  BotRichMediaRef,
  BotRichMessage,
  BotRichMarkdownInput,
  BotRichTableCell,
  BotRichTableRow,
  BotRichText,
  BotRichTextStyle,
  BotStructuredRichMessageInput,
  BotMessageEntityInput,
  BotMessageEntityOutput,
  BotMessageLite,
  BotMethodEnvelope,
  BotMethodName,
  BotMethodParams,
  BotMethodParamsByName,
  BotMethodResult,
  BotMethodResultByName,
  BotPeer,
  BotTargetInput,
  BotUser,
  DeleteMessageParams,
  EditMessageTextParams,
  EditMessageTextResult,
  EmptyResult,
  GetChatHistoryParams,
  GetChatHistoryResult,
  GetChatParams,
  GetChatResult,
  GetMeResult,
  GetMyCommandsResult,
  SetMyCommandsParams,
  SendMessageParams,
  SendMessageResult,
  SendRichMessageParams,
  SendRichMessageDraftParams,
  SendReactionParams,
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
