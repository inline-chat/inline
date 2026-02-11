export type BotApiSuccess<T> = {
  ok: true
  result: T
}

export type BotApiError = {
  ok: false
  error?: string
  error_code: number
  description: string
}

export type BotApiEnvelope<T> = BotApiSuccess<T> | BotApiError

export type BotInputId = number | string

export type BotMessageEntityType =
  | "mention"
  | "url"
  | "text_link"
  | "email"
  | "bold"
  | "italic"
  | "username_mention"
  | "code"
  | "pre"
  | "phone_number"

export type BotTargetInput = {
  // Canonical target fields.
  chat_id?: BotInputId
  user_id?: BotInputId

  // Alpha compatibility aliases.
  peer_thread_id?: BotInputId
  peer_user_id?: BotInputId
}

export type BotUser = {
  id: number
  is_bot: boolean
  username?: string
  first_name?: string
  last_name?: string
}

export type BotPeer = {
  user_id?: number
  thread_id?: number
}

export type BotMessageEntityInput = {
  type: BotMessageEntityType | string | number
  offset: BotInputId
  length: BotInputId
  user_id?: BotInputId
  url?: string
  language?: string
  // Compatibility input accepted by server.
  user?: { id: BotInputId }
}

export type BotMessageEntityOutput = {
  type: BotMessageEntityType | "unknown"
  offset: number
  length: number
  user?: BotUser
  url?: string
  language?: string
}

export type BotChatLastMessage = {
  message_id: number
  from_id: number
  from: BotUser
  date: number
  text?: string
  entities?: BotMessageEntityOutput[]
}

export type BotChat = {
  chat_id: number
  title?: string
  space_id?: number
  is_public?: boolean
  last_message_id?: number
  last_message?: BotChatLastMessage
  emoji?: string
}

export type BotMessageLite = {
  message_id: number
  chat_id: number
  chat: BotChat
  peer: BotPeer
  from_id: number
  from: BotUser
  date: number
  text?: string
  entities?: BotMessageEntityOutput[]
}

export type BotMessage = BotMessageLite & {
  reply_to_message?: BotMessageLite
}

export type GetMeResult = { user: BotUser }
export type GetChatResult = { chat: BotChat }
export type GetChatHistoryResult = { messages: BotMessage[] }
export type SendMessageResult = { message: BotMessage }
export type EditMessageTextResult = { message: BotMessage }
export type EmptyResult = Record<string, never>

export type SendMessageParams = BotTargetInput & {
  text: string
  reply_to_message_id?: BotInputId
  entities?: BotMessageEntityInput[]
}

export type EditMessageTextParams = BotTargetInput & {
  message_id: BotInputId
  text: string
  entities?: BotMessageEntityInput[]
}

export type DeleteMessageParams = BotTargetInput & {
  message_id: BotInputId
}

export type SendReactionParams = BotTargetInput & {
  message_id: BotInputId
  emoji: string
}

export type GetChatParams = BotTargetInput

export type GetChatHistoryParams = BotTargetInput & {
  limit?: number
  offset_message_id?: BotInputId
}

export type BotMethodName =
  | "getMe"
  | "getChat"
  | "getChatHistory"
  | "sendMessage"
  | "editMessageText"
  | "deleteMessage"
  | "sendReaction"

export type BotMethodParamsByName = {
  getMe: undefined
  getChat: GetChatParams
  getChatHistory: GetChatHistoryParams
  sendMessage: SendMessageParams
  editMessageText: EditMessageTextParams
  deleteMessage: DeleteMessageParams
  sendReaction: SendReactionParams
}

export type BotMethodResultByName = {
  getMe: GetMeResult
  getChat: GetChatResult
  getChatHistory: GetChatHistoryResult
  sendMessage: SendMessageResult
  editMessageText: EditMessageTextResult
  deleteMessage: EmptyResult
  sendReaction: EmptyResult
}

export type BotMethodParams<M extends BotMethodName> = BotMethodParamsByName[M]
export type BotMethodResult<M extends BotMethodName> = BotMethodResultByName[M]
export type BotMethodEnvelope<M extends BotMethodName> = BotApiEnvelope<BotMethodResult<M>>
