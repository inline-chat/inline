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
  | "message_reaction"
  | "message_action"
  | "bot_participation"

export type BotDefaultUpdateKey = Exclude<BotUpdateKey, "message_reaction">
export const BOT_DEFAULT_UPDATE_KEYS = [
  "message",
  "edited_message",
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
  | "text_mention"
  | "url"
  | "text_link"
  | "email"
  | "bold"
  | "italic"
  | "code"
  | "pre"
  | "phone_number"
  | "thread"
  | "thread_title"
  | "bot_command"
  | "group_mention"

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

export type BotPeerId =
  | { user_id: number; chat_id?: never }
  | { user_id?: never; chat_id: number }

/** @deprecated Use `BotMessage.peer_id`. */
export type BotPeer = {
  user_id?: number
  thread_id?: number
}

export type BotMessageEntityOutput = {
  type: BotMessageEntityType | "unknown"
  offset: number
  length: number
  user?: BotUser
  /** Agent selected beneath the mentioned bot user. */
  agent_id?: number
  url?: string
  language?: string
  chat_id?: number
  space_id?: number
  title?: string
  group_id?: number
}

export type BotRichText =
  | string
  | BotRichText[]
  | {
      type: "bold" | "italic" | "code"
      text: BotRichText
    }
  | { type: "url"; text: BotRichText; url: string }
  | {
      type: "email_address"
      text: BotRichText
      email_address: string
    }
  | {
      type: "phone_number"
      text: BotRichText
      phone_number: string
    }
  | {
      type: "mention"
      text: BotRichText
      username: string
    }
  | {
      type: "text_mention"
      text: BotRichText
      user: BotUser
    }
  | {
      type: "bot_command"
      text: BotRichText
      bot_command: string
    }
  | {
      type: "chat_link"
      text: BotRichText
      chat_id: number
    }
  | {
      type: "thread_title"
      text: BotRichText
      title: string
      space_id?: number
    }
  | {
      type: "group_mention"
      text: BotRichText
      group_id: number
    }

export type BotRichBlock =
  | { type: "paragraph"; text: BotRichText; is_rtl?: true }
  | {
      type: "heading"
      text: BotRichText
      size: number
      is_rtl?: true
    }
  | {
      type: "pre"
      text: BotRichText
      language?: string
    }
  | { type: "footer"; text: BotRichText; is_rtl?: true }
  | { type: "divider" }
  | {
      type: "list"
      items: Array<{
        label: string
        blocks: BotRichBlock[]
        has_checkbox?: true
        is_checked?: true
        value?: number
      }>
      is_rtl?: true
    }
  | {
      type: "blockquote"
      blocks: BotRichBlock[]
      is_rtl?: true
    }
  | { type: "collage"; blocks: BotRichBlock[] }
  | {
      type: "details"
      summary: BotRichText
      blocks: BotRichBlock[]
      is_open?: true
      kind?: "progress"
      is_rtl?: true
    }
  | {
      type: "table"
      cells: Array<
        Array<{
          text: BotRichText
          align: "left" | "center" | "right"
          is_header?: true
        }>
      >
      is_bordered?: true
      is_rtl?: true
    }
  | {
      type: "photo"
      alt?: BotRichText
      file?: BotFile
      width?: number
      height?: number
    }

export type BotRichMessage = {
  blocks: BotRichBlock[]
}

export type BotChatLastMessage = {
  message_id: number
  from_id: number
  from: BotUser
  date: number
  text?: string
  entities?: BotMessageEntityOutput[]
  rich_message?: BotRichMessage
}

export type BotChat = {
  chat_id: number
  type: BotChatType
  title?: string
  space_id?: number
  is_public?: boolean
  parent_chat_id?: number
  /** Human-facing thread number scoped to its space or home. */
  number?: number
  /** Parent anchor encoded once; its chat omits parent_message and it has no reply_to_message. */
  parent_message?: BotMessageReference
  participants?: { count: number }
  last_message_id?: number
  last_message?: BotChatLastMessage
  emoji?: string
}

export type BotEventChat = BotChat

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

export type BotMessage = {
  message_id: number
  peer_id: BotPeerId
  chat?: BotChat
  /** @deprecated Use `peer_id.chat_id` for a thread peer. */
  chat_id?: number
  /** @deprecated Use `peer_id`. */
  peer?: BotPeer
  from_id: number
  from: BotUser
  date: number
  edit_date?: number
  text?: string
  entities?: BotMessageEntityOutput[]
  rich_message?: BotRichMessage
  media?: BotMedia
  attachments?: BotAttachment[]
  actions?: BotMessageAction[][]
  reactions?: BotMessageReaction[]
  reply_to_message?: BotMessageReference
}

type BotMessageReference = Omit<
  BotMessage,
  "chat" | "reply_to_message"
>

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
export type UpdateAgentParams = Partial<CreateAgentParams> & { agent_id: BotInputId }
export type DeleteAgentParams = { agent_id: BotInputId }
export type CreateAgentResult = { agent: BotAgent }
export type GetAgentResult = { bot: BotUser; agent: BotAgent }
export type GetMyAgentsResult = { agents: BotAgent[] }
export type UpdateAgentResult = { agent: BotAgent }
export type DeleteAgentResult = { agent_id: number }

type BotUpdateBase = {
  update_id: number
  activation_reason?: BotActivationReason
  /** Full specialization selected for this directed activation. */
  activated_agent?: BotAgent
}

export type BotUpdate = BotUpdateBase &
  (
    | { message: BotEventMessage }
    | { edited_message: BotEventMessage }
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

export type GetMeResult = { user: BotUser }
export type BotSpace = {
  id: number
  name: string
  is_public?: boolean
  handle?: string
}
export type GetSpaceResult = {
  space: BotSpace
  membership: BotSpaceMember
  settings: { grid_enabled: boolean }
}
export type GetChatResult = { chat: BotChat }
export type GetChatHistoryResult = { messages: BotMessage[] }
export type GetMessagesResult = { messages: BotMessage[] }
export type SearchMessagesResult = { messages: BotMessage[] }
export type CreateThreadResult = { chat: BotChat }
export type CreateReplyThreadResult = { chat: BotChat }
export type SendMessageResult = { message: BotMessage }
export type ForwardMessageResult = { message: BotMessage }
export type ForwardMessagesResult = { message_ids: number[] }
export type GetChatParticipantResult = { participant: BotChatParticipant }
export type GetChatParticipantCountResult = { count: number }
export type GetMyCommandsResult = { commands: BotCommand[] }
export type EditMessageTextResult = { message: BotMessage }
export type EditMessageActionsResult = { message: BotMessage }
export type EmptyResult = Record<string, never>

export type GetUpdatesResult = BotUpdate[]
export type SetWebhookResult = true
export type DeleteWebhookResult = true
export type GetWebhookInfoResult = WebhookInfo

export type SendMessageParams = BotTargetInput & {
  text?: string
  reply_to_message_id?: BotInputId
  /** Parse Inline's supported Markdown surface. Defaults to true; false preserves literal syntax. */
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
  /** Parse Inline's supported Markdown surface. Defaults to true; false preserves literal syntax. */
  parse_markdown?: boolean
  actions?: BotMessageAction[][]
  // 2026-06-03: Deprecated compatibility for production bot clients; prefer `parse_markdown`.
  // Remove after confirming no production use in the previous month.
  parseMarkdown?: boolean
}

export type EditMessageActionsParams = BotTargetInput & {
  message_id: BotInputId
  /** Replaces all actions. An empty array clears them. */
  actions: BotMessageAction[][]
}

export type DeleteMessageParams = BotTargetInput & {
  message_id: BotInputId
}

export type DeleteMessagesParams = BotTargetInput & {
  message_ids: BotInputId[]
}

export type ForwardMessageParams = {
  chat_id: BotInputId
  from_chat_id: BotInputId
  message_id: BotInputId
}

export type ForwardMessagesParams = {
  chat_id: BotInputId
  from_chat_id: BotInputId
  message_ids: BotInputId[]
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

export type AddThreadParticipantParams = {
  chat_id: BotInputId
  user_id: BotInputId
}

export type RemoveThreadParticipantParams = AddThreadParticipantParams

export type SetThreadTitleParams = {
  chat_id: BotInputId
  title?: string
  /** Empty string removes the emoji. */
  emoji?: string
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

export type GetSpaceParams = { space_id: BotInputId }

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
  participants?: BotInputId[]
}

export type CreateReplyThreadParams = {
  chat_id: BotInputId
  message_id: BotInputId
  title?: string
  emoji?: string
  participants?: BotInputId[]
}

export type SetMyCommandsParams = {
  commands: BotCommand[]
}

export type BotMethodName =
  | "getMe"
  | "getSpace"
  | "getChat"
  | "getChatHistory"
  | "getMessages"
  | "searchMessages"
  | "createThread"
  | "createReplyThread"
  | "getMyCommands"
  | "createAgent"
  | "getAgent"
  | "getMyAgents"
  | "updateAgent"
  | "deleteAgent"
  | "setMyCommands"
  | "deleteMyCommands"
  | "sendMessage"
  | "editMessageText"
  | "editMessageActions"
  | "deleteMessage"
  | "deleteMessages"
  | "forwardMessage"
  | "forwardMessages"
  | "pinMessage"
  | "unpinMessage"
  | "getChatParticipant"
  | "getChatParticipantCount"
  | "addThreadParticipant"
  | "removeThreadParticipant"
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

export type BotMethodParamsByName = {
  getMe: undefined
  getSpace: GetSpaceParams
  getChat: GetChatParams
  getChatHistory: GetChatHistoryParams
  getMessages: GetMessagesParams
  searchMessages: SearchMessagesParams
  createThread: CreateThreadParams
  createReplyThread: CreateReplyThreadParams
  getMyCommands: undefined
  createAgent: CreateAgentParams
  getAgent: GetAgentParams
  getMyAgents: undefined
  updateAgent: UpdateAgentParams
  deleteAgent: DeleteAgentParams
  setMyCommands: SetMyCommandsParams
  deleteMyCommands: undefined
  sendMessage: SendMessageParams
  editMessageText: EditMessageTextParams
  editMessageActions: EditMessageActionsParams
  deleteMessage: DeleteMessageParams
  deleteMessages: DeleteMessagesParams
  forwardMessage: ForwardMessageParams
  forwardMessages: ForwardMessagesParams
  pinMessage: PinMessageParams
  unpinMessage: UnpinMessageParams
  getChatParticipant: GetChatParticipantParams
  getChatParticipantCount: GetChatParticipantCountParams
  addThreadParticipant: AddThreadParticipantParams
  removeThreadParticipant: RemoveThreadParticipantParams
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
}

export type BotMethodResultByName = {
  getMe: GetMeResult
  getSpace: GetSpaceResult
  getChat: GetChatResult
  getChatHistory: GetChatHistoryResult
  getMessages: GetMessagesResult
  searchMessages: SearchMessagesResult
  createThread: CreateThreadResult
  createReplyThread: CreateReplyThreadResult
  getMyCommands: GetMyCommandsResult
  createAgent: CreateAgentResult
  getAgent: GetAgentResult
  getMyAgents: GetMyAgentsResult
  updateAgent: UpdateAgentResult
  deleteAgent: DeleteAgentResult
  setMyCommands: EmptyResult
  deleteMyCommands: EmptyResult
  sendMessage: SendMessageResult
  editMessageText: EditMessageTextResult
  editMessageActions: EditMessageActionsResult
  deleteMessage: EmptyResult
  deleteMessages: EmptyResult
  forwardMessage: ForwardMessageResult
  forwardMessages: ForwardMessagesResult
  pinMessage: EmptyResult
  unpinMessage: EmptyResult
  getChatParticipant: GetChatParticipantResult
  getChatParticipantCount: GetChatParticipantCountResult
  addThreadParticipant: EmptyResult
  removeThreadParticipant: EmptyResult
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
}

export type BotMethodParams<M extends BotMethodName> = BotMethodParamsByName[M]
export type BotMethodResult<M extends BotMethodName> = BotMethodResultByName[M]
export type BotMethodEnvelope<M extends BotMethodName> = BotApiEnvelope<BotMethodResult<M>>
