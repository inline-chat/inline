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
  | "thread"
  | "thread_title"
  | "bot_command"
  | "underline"
  | "strikethrough"
  | "blockquote"
  | "expandable_blockquote"

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
  url?: string
  language?: string
  chat_id?: number
  space_id?: number
  title?: string
}

export type BotRichDirection = "auto" | "ltr" | "rtl"

export type BotRichTextStyle = "bold" | "italic" | "underline" | "strikethrough" | "code" | "spoiler"

export type BotRichText = {
  text?: string
  children?: BotRichText[]
  styles?: BotRichTextStyle[]
  url?: string
}

export type BotRichBlockType =
  | "paragraph"
  | "heading"
  | "list"
  | "list_item"
  | "quote"
  | "code"
  | "divider"
  | "thinking"
  | "details"
  | "photo"
  | "video"
  | "document"
  | "audio"
  | "table"
  | "math"
  | "map"
  | "embed"
  | "embed_post"
  | "link_preview"
  | "collage"

export type BotRichMediaRef = {
  alt?: string
  file_name?: string
  width?: number
  height?: number
  mime_type?: string
  cdn_url?: string
  file_unique_id?: string
  photo_id?: BotInputId
  video_id?: BotInputId
  document_id?: BotInputId
  voice_id?: BotInputId
  public_url?: string
}

export type BotRichTableCell = {
  text?: BotRichText[]
  header?: boolean
  colspan?: number
  rowspan?: number
  align?: "left" | "center" | "right"
  valign?: "top" | "middle" | "bottom"
}

export type BotRichTableRow = {
  cells: BotRichTableCell[]
}

export type BotRichBlock = {
  block_id?: string
  type: BotRichBlockType
  text?: BotRichText[]
  children?: BotRichBlock[]
  blocks?: BotRichBlock[]
  items?: BotRichBlock[]
  level?: number
  language?: string
  direction?: BotRichDirection
  ordered?: boolean
  start?: number
  checked?: boolean
  expandable?: boolean
  initially_collapsed?: boolean
  title?: BotRichText[] | string
  initially_open?: boolean
  media?: BotRichMediaRef
  poster?: BotRichMediaRef
  author_photo?: BotRichMediaRef
  caption?: BotRichText[]
  duration?: number
  performer?: string
  source?: string
  display?: boolean
  fallback?: string
  rows?: BotRichTableRow[]
  bordered?: boolean
  striped?: boolean
  latitude?: number
  longitude?: number
  zoom?: number
  address?: string
  open_url?: string
  aspect_ratio?: number
  url?: string
  html?: string
  width?: number
  height?: number
  full_width?: boolean
  allow_scrolling?: boolean
  provider?: string
  author?: string
  date?: BotInputId
  display_url?: string
  site_name?: string
  description?: string
  media_aspect_ratio?: number
  compact?: boolean
  layout?: "grid" | "masonry"
}

export type BotRichMessage = {
  blocks: BotRichBlock[]
  direction?: BotRichDirection
  fallback_text: string
}

export type BotRichInputOptions = {
  direction?: BotRichDirection
  is_rtl?: boolean
  skip_entity_detection?: boolean
}

/**
 * Preferred stable rich-message input. The server parses Markdown into a
 * canonical rich payload and keeps fallback text readable for older clients.
 */
export type BotRichMarkdownInput = BotRichInputOptions & {
  markdown: string
}

/**
 * Preferred stable rich-message input for the allowlisted HTML subset.
 */
export type BotRichHtmlInput = BotRichInputOptions & {
  html: string
}

/**
 * Beta/internal structured rich block input. Prefer `BotRichMarkdownInput` or
 * `BotRichHtmlInput` for public bot integrations unless Inline owns both ends
 * of the payload contract.
 */
export type BotStructuredRichMessageInput =
  | BotRichMessage
  | (BotRichInputOptions & {
      rich_message: BotRichMessage
    })
  | (BotRichInputOptions & {
      rich_text: BotRichMessage
    })

export type BotInputRichMessage =
  | BotRichMarkdownInput
  | BotRichHtmlInput
  | BotStructuredRichMessageInput

export type BotChatLastMessage = {
  message_id: number
  from_id: number
  from: BotUser
  date: number
  text?: string
  entities?: BotMessageEntityOutput[]
  rich_text?: BotRichMessage
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
  rich_text?: BotRichMessage
}

export type BotMessage = BotMessageLite & {
  reply_to_message?: BotMessageLite
}

export type BotCommand = {
  command: string
  description: string
  sort_order?: number
}

export type GetMeResult = { user: BotUser }
export type GetChatResult = { chat: BotChat }
export type GetChatHistoryResult = { messages: BotMessage[] }
export type SendMessageResult = { message: BotMessage }
export type GetMyCommandsResult = { commands: BotCommand[] }
export type EditMessageTextResult = { message: BotMessage }
export type EmptyResult = Record<string, never>

export type SendMessageParams = BotTargetInput & {
  text?: string
  reply_to_message_id?: BotInputId
  entities?: BotMessageEntityInput[]
  parse_markdown?: boolean
  /** Prefer `{ markdown }` or `{ html }`; structured block JSON is beta/internal. */
  rich_text?: BotInputRichMessage
  /** Prefer `{ markdown }` or `{ html }`; structured block JSON is beta/internal. */
  rich_message?: BotInputRichMessage
  parse_rich_markdown?: boolean
  skip_entity_detection?: boolean
  // 2026-06-03: Deprecated compatibility for production bot clients; prefer `parse_markdown`.
  // Remove after confirming no production use in the previous month.
  parseMarkdown?: boolean
  parseRichMarkdown?: boolean
}

export type SendRichMessageParams = BotTargetInput & {
  text?: string
  reply_to_message_id?: BotInputId
  /** Prefer `{ markdown }` or `{ html }`; structured block JSON is beta/internal. */
  rich_message?: BotInputRichMessage
  /** Prefer `{ markdown }` or `{ html }`; structured block JSON is beta/internal. */
  rich_text?: BotInputRichMessage
  parse_rich_markdown?: boolean
  skip_entity_detection?: boolean
  parseRichMarkdown?: boolean
}

export type SendRichMessageDraftParams = BotTargetInput & {
  /** Stable transient draft key. Maximum 256 UTF-16 code units. */
  draft_id: string
  message_id?: BotInputId
  /** Streaming drafts may use structured rich JSON for Inline-owned progress UI. */
  rich_message?: BotInputRichMessage
  /** Streaming drafts may use structured rich JSON for Inline-owned progress UI. */
  rich_text?: BotInputRichMessage
  clear?: boolean
  ttl_seconds?: number
}

export type EditMessageTextParams = BotTargetInput & {
  message_id: BotInputId
  text?: string
  entities?: BotMessageEntityInput[]
  parse_markdown?: boolean
  /** Prefer `{ markdown }` or `{ html }`; structured block JSON is beta/internal. */
  rich_text?: BotInputRichMessage
  /** Prefer `{ markdown }` or `{ html }`; structured block JSON is beta/internal. */
  rich_message?: BotInputRichMessage
  parse_rich_markdown?: boolean
  skip_entity_detection?: boolean
  // 2026-06-03: Deprecated compatibility for production bot clients; prefer `parse_markdown`.
  // Remove after confirming no production use in the previous month.
  parseMarkdown?: boolean
  parseRichMarkdown?: boolean
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

export type SetMyCommandsParams = {
  commands: BotCommand[]
}

export type BotMethodName =
  | "getMe"
  | "getChat"
  | "getChatHistory"
  | "getMyCommands"
  | "setMyCommands"
  | "deleteMyCommands"
  | "sendMessage"
  | "sendRichMessage"
  | "sendRichMessageDraft"
  | "editMessageText"
  | "deleteMessage"
  | "sendReaction"

export type BotMethodParamsByName = {
  getMe: undefined
  getChat: GetChatParams
  getChatHistory: GetChatHistoryParams
  getMyCommands: undefined
  setMyCommands: SetMyCommandsParams
  deleteMyCommands: undefined
  sendMessage: SendMessageParams
  sendRichMessage: SendRichMessageParams
  sendRichMessageDraft: SendRichMessageDraftParams
  editMessageText: EditMessageTextParams
  deleteMessage: DeleteMessageParams
  sendReaction: SendReactionParams
}

export type BotMethodResultByName = {
  getMe: GetMeResult
  getChat: GetChatResult
  getChatHistory: GetChatHistoryResult
  getMyCommands: GetMyCommandsResult
  setMyCommands: EmptyResult
  deleteMyCommands: EmptyResult
  sendMessage: SendMessageResult
  sendRichMessage: SendMessageResult
  sendRichMessageDraft: EmptyResult
  editMessageText: EditMessageTextResult
  deleteMessage: EmptyResult
  sendReaction: EmptyResult
}

export type BotMethodParams<M extends BotMethodName> = BotMethodParamsByName[M]
export type BotMethodResult<M extends BotMethodName> = BotMethodResultByName[M]
export type BotMethodEnvelope<M extends BotMethodName> = BotApiEnvelope<BotMethodResult<M>>
