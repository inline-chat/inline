import { t } from "elysia"
import { maxRichDraftIdLength } from "@in/server/modules/message/richDraftLimits"
import { TBotMessageEntitiesInput, TBotMessageEntitiesOutput } from "./entities"

const TTargetId = t.Union([t.Number(), t.String()])

const TBotTargetFields = {
  user_id: t.Optional(TTargetId),
  chat_id: t.Optional(TTargetId),
} as const

export const TBotUser = t.Object({
  id: t.Number(),
  is_bot: t.Boolean(),
  username: t.Optional(t.String()),
  first_name: t.Optional(t.String()),
  last_name: t.Optional(t.String()),
})

export const TBotPeer = t.Object({
  user_id: t.Optional(t.Number()),
})

export const TBotCommand = t.Object({
  command: t.String(),
  description: t.String(),
  sort_order: t.Optional(t.Number()),
})

export const TBotChat = t.Object({
  chat_id: t.Number(),
  title: t.Optional(t.String()),
  space_id: t.Optional(t.Number()),
  is_public: t.Optional(t.Boolean()),
  last_message_id: t.Optional(t.Number()),
  last_message: t.Optional(
    t.Object({
      message_id: t.Number(),
      from_id: t.Number(),
      from: TBotUser,
      date: t.Number(),
      text: t.Optional(t.String()),
      entities: t.Optional(TBotMessageEntitiesOutput),
      rich_text: t.Optional(t.Any()),
    }),
  ),
  emoji: t.Optional(t.String()),
})

export const TBotMessageLite = t.Object({
  message_id: t.Number(),
  chat_id: t.Number(),
  chat: TBotChat,
  peer: TBotPeer,
  from_id: t.Number(),
  from: TBotUser,
  date: t.Number(),
  text: t.Optional(t.String()),
  entities: t.Optional(TBotMessageEntitiesOutput),
  rich_text: t.Optional(t.Any()),
})

export const TBotMessage = t.Object({
  message_id: t.Number(),
  chat_id: t.Number(),
  chat: TBotChat,
  peer: TBotPeer,
  from_id: t.Number(),
  from: TBotUser,
  date: t.Number(),
  text: t.Optional(t.String()),
  entities: t.Optional(TBotMessageEntitiesOutput),
  rich_text: t.Optional(t.Any()),
  reply_to_message: t.Optional(TBotMessageLite),
})

const TBotRichDirection = t.Union([t.Literal("auto"), t.Literal("ltr"), t.Literal("rtl")])
const TBotRichTextStyle = t.Union([
  t.Literal("bold"),
  t.Literal("italic"),
  t.Literal("underline"),
  t.Literal("strikethrough"),
  t.Literal("code"),
  t.Literal("spoiler"),
])
const TBotRichText = t.Object({
  text: t.Optional(t.String()),
  children: t.Optional(t.Array(t.Any())),
  styles: t.Optional(t.Array(TBotRichTextStyle)),
  url: t.Optional(t.String()),
})
const TBotRichBlockType = t.Union([
  t.Literal("paragraph"),
  t.Literal("heading"),
  t.Literal("list"),
  t.Literal("list_item"),
  t.Literal("quote"),
  t.Literal("code"),
  t.Literal("divider"),
  t.Literal("thinking"),
  t.Literal("details"),
  t.Literal("photo"),
  t.Literal("video"),
  t.Literal("document"),
  t.Literal("audio"),
  t.Literal("table"),
  t.Literal("math"),
  t.Literal("map"),
  t.Literal("embed"),
  t.Literal("embed_post"),
  t.Literal("link_preview"),
  t.Literal("collage"),
])
const TBotRichMediaRef = t.Object({
  alt: t.Optional(t.String()),
  file_name: t.Optional(t.String()),
  width: t.Optional(t.Number()),
  height: t.Optional(t.Number()),
  mime_type: t.Optional(t.String()),
  cdn_url: t.Optional(t.String()),
  file_unique_id: t.Optional(t.String()),
  photo_id: t.Optional(TTargetId),
  video_id: t.Optional(TTargetId),
  document_id: t.Optional(TTargetId),
  voice_id: t.Optional(TTargetId),
  public_url: t.Optional(t.String()),
})
const TBotRichTableCell = t.Object({
  text: t.Optional(t.Array(TBotRichText)),
  header: t.Optional(t.Boolean()),
  colspan: t.Optional(t.Number()),
  rowspan: t.Optional(t.Number()),
  align: t.Optional(t.Union([t.Literal("left"), t.Literal("center"), t.Literal("right")])),
  valign: t.Optional(t.Union([t.Literal("top"), t.Literal("middle"), t.Literal("bottom")])),
})
const TBotRichTableRow = t.Object({
  cells: t.Array(TBotRichTableCell),
})
const TBotRichBlock = t.Object({
  block_id: t.Optional(t.String()),
  type: TBotRichBlockType,
  text: t.Optional(t.Array(TBotRichText)),
  children: t.Optional(t.Array(t.Any())),
  blocks: t.Optional(t.Array(t.Any())),
  items: t.Optional(t.Array(t.Any())),
  level: t.Optional(t.Number()),
  language: t.Optional(t.String()),
  direction: t.Optional(TBotRichDirection),
  ordered: t.Optional(t.Boolean()),
  start: t.Optional(t.Number()),
  checked: t.Optional(t.Boolean()),
  expandable: t.Optional(t.Boolean()),
  initially_collapsed: t.Optional(t.Boolean()),
  title: t.Optional(t.Union([t.Array(TBotRichText), t.String()])),
  initially_open: t.Optional(t.Boolean()),
  media: t.Optional(TBotRichMediaRef),
  poster: t.Optional(TBotRichMediaRef),
  author_photo: t.Optional(TBotRichMediaRef),
  caption: t.Optional(t.Array(TBotRichText)),
  duration: t.Optional(t.Number()),
  performer: t.Optional(t.String()),
  source: t.Optional(t.String()),
  display: t.Optional(t.Boolean()),
  fallback: t.Optional(t.String()),
  rows: t.Optional(t.Array(TBotRichTableRow)),
  bordered: t.Optional(t.Boolean()),
  striped: t.Optional(t.Boolean()),
  latitude: t.Optional(t.Number()),
  longitude: t.Optional(t.Number()),
  zoom: t.Optional(t.Number()),
  address: t.Optional(t.String()),
  open_url: t.Optional(t.String()),
  aspect_ratio: t.Optional(t.Number()),
  url: t.Optional(t.String()),
  html: t.Optional(t.String()),
  width: t.Optional(t.Number()),
  height: t.Optional(t.Number()),
  full_width: t.Optional(t.Boolean()),
  allow_scrolling: t.Optional(t.Boolean()),
  provider: t.Optional(t.String()),
  author: t.Optional(t.String()),
  date: t.Optional(TTargetId),
  display_url: t.Optional(t.String()),
  site_name: t.Optional(t.String()),
  description: t.Optional(t.String()),
  media_aspect_ratio: t.Optional(t.Number()),
  compact: t.Optional(t.Boolean()),
  layout: t.Optional(t.Union([t.Literal("grid"), t.Literal("masonry")])),
})
const TBotRichMessage = t.Object({
  blocks: t.Array(TBotRichBlock),
  direction: t.Optional(TBotRichDirection),
  fallback_text: t.String(),
})

export const TBotRichMessageInput = t.Union([
  TBotRichMessage,
  t.Object({
    markdown: t.Optional(t.String()),
    html: t.Optional(t.String()),
    rich_message: t.Optional(TBotRichMessage),
    rich_text: t.Optional(TBotRichMessage),
    direction: t.Optional(TBotRichDirection),
    is_rtl: t.Optional(t.Boolean()),
    skip_entity_detection: t.Optional(t.Boolean()),
  }),
])
export const TBotRichMessageOutput = TBotRichMessage

export const TSendMessageInput = t.Object({
  ...TBotTargetFields,
  text: t.Optional(t.String()),
  reply_to_message_id: t.Optional(TTargetId),
  entities: t.Optional(TBotMessageEntitiesInput),
  parse_markdown: t.Optional(t.Boolean()),
  rich_text: t.Optional(TBotRichMessageInput),
  rich_message: t.Optional(TBotRichMessageInput),
  parse_rich_markdown: t.Optional(t.Boolean()),
  skip_entity_detection: t.Optional(t.Boolean()),
})

export const TSendRichMessageInput = t.Object({
  ...TBotTargetFields,
  text: t.Optional(t.String()),
  reply_to_message_id: t.Optional(TTargetId),
  rich_message: t.Optional(TBotRichMessageInput),
  rich_text: t.Optional(TBotRichMessageInput),
  parse_rich_markdown: t.Optional(t.Boolean()),
  skip_entity_detection: t.Optional(t.Boolean()),
})

export const TSendRichMessageDraftInput = t.Object({
  ...TBotTargetFields,
  draft_id: t.String({ maxLength: maxRichDraftIdLength }),
  message_id: t.Optional(TTargetId),
  rich_message: t.Optional(TBotRichMessageInput),
  rich_text: t.Optional(TBotRichMessageInput),
  clear: t.Optional(t.Boolean()),
  ttl_seconds: t.Optional(t.Number()),
})

export const TGetChatInput = t.Object({
  ...TBotTargetFields,
})

export const TGetChatHistoryInput = t.Object({
  ...TBotTargetFields,
  limit: t.Optional(t.Number()),
  offset_message_id: t.Optional(TTargetId),
})

export const TEditMessageTextInput = t.Object({
  ...TBotTargetFields,
  message_id: TTargetId,
  text: t.Optional(t.String()),
  entities: t.Optional(TBotMessageEntitiesInput),
  parse_markdown: t.Optional(t.Boolean()),
  rich_text: t.Optional(TBotRichMessageInput),
  rich_message: t.Optional(TBotRichMessageInput),
  parse_rich_markdown: t.Optional(t.Boolean()),
  skip_entity_detection: t.Optional(t.Boolean()),
})

export const TDeleteMessageInput = t.Object({
  ...TBotTargetFields,
  message_id: TTargetId,
})

export const TSendReactionInput = t.Object({
  ...TBotTargetFields,
  message_id: TTargetId,
  emoji: t.String(),
})

export const TSetMyCommandsInput = t.Object({
  commands: t.Array(TBotCommand),
})
