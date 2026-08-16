export type BotApiSuccess<T> = {
  ok: true
  result: T
}

export type BotApiError = {
  ok: false
  error?: string
  error_code: number
  description: string
  parameters?: { retry_after?: number }
}

export type BotApiEnvelope<T> = BotApiSuccess<T> | BotApiError

export const BOT_ID_MAX = 4_503_599_627_370_495

export type BotInputId = number | string

export type BotUpdateKey =
  | "message"
  | "edited_message"
  | "deleted_messages"
  | "message_reaction"
  | "message_action"
  | "bot_participation"

export type BotDefaultUpdateKey = Exclude<BotUpdateKey, "message_reaction">
export const BOT_DEFAULT_UPDATE_KEYS = [
  "message",
  "edited_message",
  "deleted_messages",
  "message_action",
  "bot_participation",
] as const satisfies ReadonlyArray<BotDefaultUpdateKey>
export type BotMessageTrigger = "all" | "mentions"
export type BotActivationReason =
  | "direct"
  | "all"
  | "mention"
  | "reply"
  | "command"
  | "action"

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
  | "thread"
  | "thread_title"
  | "bot_command"

export type BotTargetInput = {
  chat_id?: BotInputId
  user_id?: BotInputId
  // 2026-06-03: Deprecated compatibility for production bot clients; prefer `chat_id`.
  // Remove after confirming no production use in the previous month.
  peer_thread_id?: BotInputId
  // 2026-06-03: Deprecated compatibility for production bot clients; prefer `user_id`.
  // Remove after confirming no production use in the previous month.
  peer_user_id?: BotInputId
}

export type BotUser = {
  id: number
  is_bot: boolean
  username?: string
  first_name?: string
  last_name?: string
}

export type BotChatType = "user" | "thread"

export type BotPeer = {
  user_id?: number
  // 2026-06-03: Deprecated output shape kept for production bot clients.
  // Prefer `message.chat_id`; remove after confirming no production use in the previous month.
  thread_id?: number
}

export type BotMessageEntityInput = {
  // 2026-06-03: Deprecated compatibility accepts legacy strings and enum numbers for existing entity types.
  // New thread-link entities should use canonical names only. Remove after production usage audit.
  type: BotMessageEntityType | string | number
  offset: BotInputId
  length: BotInputId
  user_id?: BotInputId
  agent_id?: BotInputId
  url?: string
  language?: string
  chat_id?: BotInputId
  space_id?: BotInputId
  title?: string
  // 2026-06-03: Deprecated compatibility for production bot clients; prefer `user_id`.
  // Remove after confirming no production use in the previous month.
  user?: { id: BotInputId }
}

export type BotMessageEntityOutput = {
  type: BotMessageEntityType | "unknown"
  offset: number
  length: number
  user?: BotUser
  agent_id?: number
  url?: string
  language?: string
  chat_id?: number
  space_id?: number
  title?: string
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
  type?: BotChatType
  title?: string
  space_id?: number
  is_public?: boolean
  parent_chat_id?: number
  /** Parent anchor encoded once; its chat omits parent_message and it has no reply_to_message. */
  parent_message?: BotMessageLite
  participants?: { count: number }
  last_message_id?: number
  last_message?: BotChatLastMessage
  emoji?: string
}

export type BotEventChat = BotChat & { type: BotChatType }

export type BotFile = {
  file_id: string
  file_name?: string
  mime_type?: string
  file_size?: number
  width?: number
  height?: number
  duration?: number
  download_url?: string
  download_url_expires_at?: number
}

export type BotMedia =
  | { type: "photo"; file: BotFile }
  | {
      type: "video"
      file: BotFile
      thumbnail?: BotFile
      is_animated?: boolean
      has_audio?: boolean
    }
  | { type: "document"; file: BotFile; thumbnail?: BotFile }
  | { type: "voice"; file: BotFile; waveform_base64?: string }
  | { type: "nudge" }

export type BotMessageAction =
  | {
      action_id: string
      text: string
      type: "callback"
      callback_data: string
      callback_data_base64?: never
    }
  | {
      action_id: string
      text: string
      type: "callback"
      callback_data?: never
      callback_data_base64: string
    }
  | {
      action_id: string
      text: string
      type: "callback"
      callback_data?: never
      callback_data_base64?: never
    }
  | {
      action_id: string
      text: string
      type: "copy_text"
      copy_text: string
    }

export type BotReaction = { emoji: string }
export type BotMessageReaction = BotReaction & {
  count: number
  chosen: boolean
}

export type BotAttachment = {
  type: "url_preview"
  url: string
  title?: string
  description?: string
  image?: BotFile
}

export type BotMessageLite = {
  message_id: number
  chat_id: number
  chat: BotChat
  peer: BotPeer
  from_id: number
  from: BotUser
  date: number
  edit_date?: number
  text?: string
  entities?: BotMessageEntityOutput[]
  media?: BotMedia
  attachments?: BotAttachment[]
  actions?: BotMessageAction[][]
  reactions?: BotMessageReaction[]
}

export type BotMessage = BotMessageLite & {
  reply_to_message?: BotMessageLite
}

export type BotEventMessage = Omit<BotMessage, "chat"> & {
  chat: BotEventChat
}

export type BotParticipationChange = {
  chat: BotEventChat
  actor?: BotUser
  date: number
  status: "added" | "removed"
}

export type BotSpaceMember = {
  id: number
  space_id: number
  user_id: number
  role?: "owner" | "admin" | "member"
  date: number
  can_access_public_chats: boolean
}

export type BotChatParticipant = {
  user: BotUser
  member?: BotSpaceMember
}

type BotUpdateBase = {
  update_id: number
  activation_reason?: BotActivationReason
  activated_agent?: BotAgent
}

export type BotUpdate = BotUpdateBase &
  (
    | { message: BotEventMessage }
    | { edited_message: BotEventMessage }
    | {
        deleted_messages: {
          chat: BotEventChat
          message_ids: number[]
          actor?: BotUser
          date: number
        }
      }
    | {
        message_reaction: {
          chat: BotEventChat
          message_id: number
          actor: BotUser
          date: number
          old_reaction: BotReaction[]
          new_reaction: BotReaction[]
        }
      }
    | {
        message_action: {
          interaction_id: number
          chat: BotEventChat
          message_id: number
          actor: BotUser
          date: number
          action: { action_id: string } &
            (
              | { callback_data: string; callback_data_base64?: never }
              | { callback_data?: never; callback_data_base64: string }
              | { callback_data?: never; callback_data_base64?: never }
            )
        }
      }
    | { bot_participation: BotParticipationChange }
  )

export type WebhookInfo = {
  url: string
  pending_update_count: number
  allowed_updates: BotUpdateKey[]
  message_trigger: BotMessageTrigger
  last_error_date?: number
  last_error_message?: string
  dropped_update_count: number
}

export type BotCommand = {
  command: string
  description: string
  sort_order?: number
}

export type BotAgent = {
  id: number
  bot_user_id: number
  name: string
  handle?: string
  emoji?: string
  description?: string
  skill_key?: string
  instructions?: string
}

export type CreateAgentParams = Omit<BotAgent, "id" | "bot_user_id">
export type GetAgentParams = { agent_id: BotInputId }
export type CreateAgentResult = { agent: BotAgent }
export type GetAgentResult = { bot: BotUser; agent: BotAgent }
export type GetMyAgentsResult = { agents: BotAgent[] }

export type GetMeResult = { user: BotUser }
export type GetChatResult = { chat: BotChat }
export type GetChatHistoryResult = { messages: BotMessage[] }
export type GetMessagesResult = { messages: BotMessage[] }
export type SearchMessagesResult = { messages: BotMessage[] }
export type CreateThreadResult = { chat: BotChat }
export type CreateReplyThreadResult = { chat: BotChat }
export type SendMessageResult = { message: BotMessage }
export type ForwardMessageResult = { message: BotMessage }
export type GetChatParticipantResult = { participant: BotChatParticipant }
export type GetChatParticipantCountResult = { count: number }
export type GetMyCommandsResult = { commands: BotCommand[] }
export type EditMessageTextResult = { message: BotMessage }
export type EmptyResult = Record<string, never>

export type GetUpdatesResult = BotUpdate[]
export type SetWebhookResult = true
export type DeleteWebhookResult = true
export type GetWebhookInfoResult = WebhookInfo

export type SendMessageParams = BotTargetInput & {
  text?: string
  reply_to_message_id?: BotInputId
  entities?: BotMessageEntityInput[]
  parse_markdown?: boolean
  media?:
    | { type: "photo" | "video" | "document" | "voice"; file_id: string }
    | { type: "nudge" }
  actions?: BotMessageAction[][]
  silent?: boolean
  // 2026-06-03: Deprecated compatibility for production bot clients; prefer `parse_markdown`.
  // Remove after confirming no production use in the previous month.
  parseMarkdown?: boolean
}

export type EditMessageTextParams = BotTargetInput & {
  message_id: BotInputId
  text: string
  entities?: BotMessageEntityInput[]
  parse_markdown?: boolean
  actions?: BotMessageAction[][]
  // 2026-06-03: Deprecated compatibility for production bot clients; prefer `parse_markdown`.
  // Remove after confirming no production use in the previous month.
  parseMarkdown?: boolean
}

export type DeleteMessageParams = BotTargetInput & {
  message_id: BotInputId
}

export type ForwardMessageParams = {
  chat_id: BotInputId
  from_chat_id: BotInputId
  message_id: BotInputId
}

export type PinMessageParams = {
  chat_id: BotInputId
  message_id: BotInputId
}

export type UnpinMessageParams = PinMessageParams

export type GetChatParticipantParams = {
  chat_id: BotInputId
  user_id: BotInputId
}

export type GetChatParticipantCountParams = {
  chat_id: BotInputId
}

export type SetThreadTitleParams = {
  chat_id: BotInputId
  title: string
}

export type SendReactionParams = BotTargetInput & {
  message_id: BotInputId
  emoji: string
}

export type DeleteReactionParams = SendReactionParams

export type AnswerMessageActionParams = {
  interaction_id: BotInputId
  text?: string
}

export type BotChatAction =
  | "typing"
  | "upload_photo"
  | "upload_video"
  | "upload_document"
  | "record_voice"
  | "cancel"

export type SendChatActionParams = BotTargetInput & { action: BotChatAction }

export type GetFileParams = { file_id: string }
export type GetFileResult = { file: BotFile }
export type UploadFileParams = {
  type: "photo" | "video" | "document" | "voice"
  file: Blob
  file_name?: string
  thumbnail?: Blob
  thumbnail_file_name?: string
  width?: number
  height?: number
  duration?: number
  is_animated?: boolean
  has_audio?: boolean
  waveform_base64?: string
}
export type UploadFileResult = { file: BotFile }

export type GetUpdatesParams = {
  offset?: BotInputId
  limit?: number
  timeout?: number
  message_trigger?: BotMessageTrigger
  allowed_updates?: BotUpdateKey[]
}

export type SetWebhookParams = {
  url: string
  secret_token?: string
  message_trigger?: BotMessageTrigger
  allowed_updates?: BotUpdateKey[]
  drop_pending_updates?: boolean
}

export type DeleteWebhookParams = { drop_pending_updates?: boolean }

export type GetChatParams = BotTargetInput

export type GetChatHistoryParams = BotTargetInput & {
  limit?: number
  offset_message_id?: BotInputId
}

export type GetMessagesParams = BotTargetInput & {
  message_ids: BotInputId[]
}

export type BotSearchFilter =
  | "photo"
  | "video"
  | "photo_video"
  | "document"
  | "link"
  | "voice"

export type SearchMessagesParams = BotTargetInput & {
  query: string
  filter?: BotSearchFilter
  offset_message_id?: BotInputId
  limit?: number
}

export type CreateThreadParams = {
  title?: string
  emoji?: string
  space_id?: BotInputId
  is_public?: boolean
  participant_ids?: BotInputId[]
}

export type CreateReplyThreadParams = {
  chat_id: BotInputId
  message_id: BotInputId
  title?: string
  emoji?: string
  participant_ids?: BotInputId[]
}

export type SetMyCommandsParams = {
  commands: BotCommand[]
}

export type BotMethodName =
  | "getMe"
  | "getChat"
  | "getChatHistory"
  | "getMessages"
  | "searchMessages"
  | "createThread"
  | "createReplyThread"
  | "getMyCommands"
  | "setMyCommands"
  | "deleteMyCommands"
  | "sendMessage"
  | "editMessageText"
  | "deleteMessage"
  | "forwardMessage"
  | "pinMessage"
  | "unpinMessage"
  | "getChatParticipant"
  | "getChatParticipantCount"
  | "setThreadTitle"
  | "sendReaction"
  | "deleteReaction"
  | "answerMessageAction"
  | "sendChatAction"
  | "getFile"
  | "uploadFile"
  | "getUpdates"
  | "setWebhook"
  | "deleteWebhook"
  | "getWebhookInfo"
  | "createAgent"
  | "getAgent"
  | "getMyAgents"

export type BotMethodParamsByName = {
  getMe: undefined
  getChat: GetChatParams
  getChatHistory: GetChatHistoryParams
  getMessages: GetMessagesParams
  searchMessages: SearchMessagesParams
  createThread: CreateThreadParams
  createReplyThread: CreateReplyThreadParams
  getMyCommands: undefined
  setMyCommands: SetMyCommandsParams
  deleteMyCommands: undefined
  sendMessage: SendMessageParams
  editMessageText: EditMessageTextParams
  deleteMessage: DeleteMessageParams
  forwardMessage: ForwardMessageParams
  pinMessage: PinMessageParams
  unpinMessage: UnpinMessageParams
  getChatParticipant: GetChatParticipantParams
  getChatParticipantCount: GetChatParticipantCountParams
  setThreadTitle: SetThreadTitleParams
  sendReaction: SendReactionParams
  deleteReaction: DeleteReactionParams
  answerMessageAction: AnswerMessageActionParams
  sendChatAction: SendChatActionParams
  getFile: GetFileParams
  uploadFile: UploadFileParams
  getUpdates: GetUpdatesParams
  setWebhook: SetWebhookParams
  deleteWebhook: DeleteWebhookParams
  getWebhookInfo: undefined
  createAgent: CreateAgentParams
  getAgent: GetAgentParams
  getMyAgents: undefined
}

export type BotMethodResultByName = {
  getMe: GetMeResult
  getChat: GetChatResult
  getChatHistory: GetChatHistoryResult
  getMessages: GetMessagesResult
  searchMessages: SearchMessagesResult
  createThread: CreateThreadResult
  createReplyThread: CreateReplyThreadResult
  getMyCommands: GetMyCommandsResult
  setMyCommands: EmptyResult
  deleteMyCommands: EmptyResult
  sendMessage: SendMessageResult
  editMessageText: EditMessageTextResult
  deleteMessage: EmptyResult
  forwardMessage: ForwardMessageResult
  pinMessage: EmptyResult
  unpinMessage: EmptyResult
  getChatParticipant: GetChatParticipantResult
  getChatParticipantCount: GetChatParticipantCountResult
  setThreadTitle: EmptyResult
  sendReaction: EmptyResult
  deleteReaction: EmptyResult
  answerMessageAction: EmptyResult
  sendChatAction: EmptyResult
  getFile: GetFileResult
  uploadFile: UploadFileResult
  getUpdates: GetUpdatesResult
  setWebhook: SetWebhookResult
  deleteWebhook: DeleteWebhookResult
  getWebhookInfo: GetWebhookInfoResult
  createAgent: CreateAgentResult
  getAgent: GetAgentResult
  getMyAgents: GetMyAgentsResult
}

export type BotMethodParams<M extends BotMethodName> = BotMethodParamsByName[M]
export type BotMethodResult<M extends BotMethodName> = BotMethodResultByName[M]
export type BotMethodEnvelope<M extends BotMethodName> = BotApiEnvelope<BotMethodResult<M>>
