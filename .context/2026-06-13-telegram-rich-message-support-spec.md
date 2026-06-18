# Telegram Rich Messages Research and Inline Support Spec

Date: 2026-06-13
Status: research/spec, no implementation yet

## Scope

This document covers Telegram Bot API 10.1 rich messages from the June 11, 2026 changelog, the underlying MTProto/TL schema used by current clients, the iOS and desktop rendering paths, and a concrete plan to add equivalent support to Inline.

Primary sources checked:

- Official Bot API docs: `https://core.telegram.org/bots/api#june-11-2026`
- TDLib `origin/master`: `a17f87c4cff7b90b278d12b91ba0614383aaee82`, MTProto layer constant `MTPROTO_LAYER = 227`
- Telegram Desktop `origin/dev` / tag `v6.9.3`: `3887c78b035b47f179ef366e3a8a56c08c44ad0b`
- Telegram iOS `master` / peeled tag `release-12.8`: `6e370e06d147b091b07903071cb1b8a22152492d`
- TelegramSwift/macOS local source and remote `master`: `579cebbf0c01fd41b712eff3647fa7f69db9665d`, inspected in a second pass. It does not contain the new rich-message TL/API surface or chat rendering bridge; treat it as stale/non-authoritative for the new rich-message feature, but useful for its existing native Instant Page renderer.

Direct source links used for audit:

- Bot API changelog and methods:
  - `https://core.telegram.org/bots/api#june-11-2026`
  - `https://core.telegram.org/bots/api#richmessage`
  - `https://core.telegram.org/bots/api#inputrichmessage`
  - `https://core.telegram.org/bots/api#sendrichmessage`
  - `https://core.telegram.org/bots/api#sendrichmessagedraft`
  - `https://core.telegram.org/bots/api#inputrichmessagecontent`
- TDLib:
  - `https://github.com/tdlib/td/blob/a17f87c4cff7b90b278d12b91ba0614383aaee82/td/generate/scheme/telegram_api.tl`
  - `https://github.com/tdlib/td/blob/a17f87c4cff7b90b278d12b91ba0614383aaee82/td/generate/scheme/td_api.tl`
  - `https://github.com/tdlib/td/blob/a17f87c4cff7b90b278d12b91ba0614383aaee82/td/telegram/RichMessage.cpp`
  - `https://github.com/tdlib/td/blob/a17f87c4cff7b90b278d12b91ba0614383aaee82/td/telegram/OptionManager.cpp`
- Telegram Desktop:
  - `https://github.com/telegramdesktop/tdesktop/blob/3887c78b035b47f179ef366e3a8a56c08c44ad0b/Telegram/SourceFiles/mtproto/scheme/api.tl`
  - `https://github.com/telegramdesktop/tdesktop/blob/3887c78b035b47f179ef366e3a8a56c08c44ad0b/Telegram/SourceFiles/iv/iv_rich_page.cpp`
  - `https://github.com/telegramdesktop/tdesktop/blob/3887c78b035b47f179ef366e3a8a56c08c44ad0b/Telegram/SourceFiles/iv/iv_rich_message_serializer.cpp`
  - `https://github.com/telegramdesktop/tdesktop/blob/3887c78b035b47f179ef366e3a8a56c08c44ad0b/Telegram/SourceFiles/history/history_streamed_drafts.cpp`
- Telegram iOS:
  - `https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramCore/Sources/SyncCore/SyncCore_RichTextMessageAttribute.swift`
  - `https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramCore/Sources/ApiUtils/InstantPage.swift`
  - `https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Chat/ChatMessageRichDataBubbleContentNode/Sources/ChatMessageRichDataBubbleContentNode.swift`
  - `https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/InstantPageUI/Sources/InstantPageRenderer.swift`
  - `https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/InstantPageUI/Sources/InstantPageV2Layout.swift`
- TelegramSwift/macOS:
  - `https://github.com/overtake/TelegramSwift/blob/579cebbf0c01fd41b712eff3647fa7f69db9665d/.gitmodules`
  - `https://github.com/overtake/TelegramSwift/blob/579cebbf0c01fd41b712eff3647fa7f69db9665d/Telegram-Mac/ChatMessageItem.swift`
  - `https://github.com/overtake/TelegramSwift/blob/579cebbf0c01fd41b712eff3647fa7f69db9665d/Telegram-Mac/WPLayout.swift`
  - `https://github.com/overtake/TelegramSwift/blob/579cebbf0c01fd41b712eff3647fa7f69db9665d/Telegram-Mac/PeerMediaWebpageRowContent.swift`
  - `https://github.com/overtake/TelegramSwift/blob/579cebbf0c01fd41b712eff3647fa7f69db9665d/Telegram-Mac/InstantPageLayout.swift`
  - `https://github.com/overtake/TelegramSwift/blob/579cebbf0c01fd41b712eff3647fa7f69db9665d/Telegram-Mac/InstantPageTextItem.swift`
  - `https://github.com/overtake/TelegramSwift/blob/579cebbf0c01fd41b712eff3647fa7f69db9665d/Telegram-Mac/InstantPageTableItem.swift`
  - `https://github.com/overtake/TelegramSwift/blob/579cebbf0c01fd41b712eff3647fa7f69db9665d/Telegram-Mac/InstantPageViewController.swift`
  - `https://github.com/overtake/TelegramSwift/blob/579cebbf0c01fd41b712eff3647fa7f69db9665d/Telegram-Mac/InstantPageSelectText.swift`

## High-Level Findings

Telegram did not bolt rich formatting onto flat `MessageEntity` text. The new system is a block AST that reuses the Instant View `PageBlock`/`RichText` model internally:

- Bot API exposes `RichMessage` and `RichBlock` JSON output, and accepts `InputRichMessage` as either rich HTML or rich Markdown.
- MTProto carries `message.rich_message: RichMessage` plus `InputRichMessage` variants for structured blocks, HTML, and Markdown.
- TDLib normalizes this as `messageRichMessage` / `inputMessageRichMessage` and exposes `getFullRichMessage` for partial messages.
- iOS stores rich messages as `RichTextMessageAttribute(instantPage, fullInstantPage)` and renders them through `InstantPageV2View`.
- Telegram Desktop renders rich messages through the `iv/markdown` Instant View renderer, not through the ordinary history text item path.

For Inline, the safe architecture is the same: server-side parsing and canonicalization into a protobuf block tree, encrypted storage of that tree, flat fallback text for notifications/search/backward compatibility, and native Apple renderers over the canonical AST.

## Official Bot API Surface

Bot API 10.1 added a complete rich-message API surface:

- `RichText`
- `RichBlockCaption`
- `RichBlockTableCell`
- `RichBlockListItem`
- All `RichBlock*` variants
- `RichBlock`
- `RichMessage`
- `Message.rich_message`
- `InputRichMessage`
- `InputRichMessageContent`
- `sendRichMessage`
- `sendRichMessageDraft`
- `editMessageText.rich_message`

Notably, Bot API rich messages are separate from normal `sendMessage`. A bot sends persistent rich content with `sendRichMessage`, streams ephemeral partial rich content with `sendRichMessageDraft`, and edits text/rich/game messages through `editMessageText`.

### Rich Message Limits

The Bot API docs and TDLib defaults match:

| Limit | Value |
| --- | --- |
| Text length | 32768 UTF-8 characters, including custom emoji alt text and formula source |
| Blocks | 500 total, including nested blocks, list items, table rows, quotations, and details |
| Depth | 16 nested levels |
| Media | 50 media attachments total |
| Table columns | 20 |

TDLib default option names:

- `rich_message_text_length_max = 32768`
- `rich_message_block_count_max = 500`
- `rich_message_depth_max = 16`
- `rich_message_media_count_max = 50`
- `rich_message_table_column_count_max = 20`

### Bot API Types

`Message` now has:

| Field | Type | Notes |
| --- | --- | --- |
| `rich_message` | `RichMessage` | Present when the message is a rich formatted message. |

`RichMessage`:

| Field | Type | Notes |
| --- | --- | --- |
| `blocks` | `Array<RichBlock>` | Canonical block content. |
| `is_rtl` | `Boolean?` | Render whole message right-to-left. |

`InputRichMessage`:

| Field | Type | Notes |
| --- | --- | --- |
| `html` | `String?` | HTML-style input. Exactly one of `html` or `markdown`. |
| `markdown` | `String?` | Markdown-style input. Exactly one of `html` or `markdown`. |
| `is_rtl` | `Boolean?` | Force RTL rendering. |
| `skip_entity_detection` | `Boolean?` | Disable automatic detection of URL, email, mention, hashtag, cashtag, bot command, phone, bank card. |

`InputRichMessageContent`:

| Field | Type | Notes |
| --- | --- | --- |
| `rich_message` | `InputRichMessage` | Rich message content for inline query results, guest queries, Web App queries, and prepared inline messages. |

### Bot API Methods

`sendRichMessage`:

| Param | Type | Required | Notes |
| --- | --- | --- | --- |
| `business_connection_id` | `String` | No | Business connection identity. |
| `chat_id` | `Integer or String` | Yes | Target chat or username. |
| `message_thread_id` | `Integer` | No | Forum/private topic. |
| `direct_messages_topic_id` | `Integer` | No | Required for channel direct messages topics. |
| `rich_message` | `InputRichMessage` | Yes | Rich content to send. |
| `disable_notification` | `Boolean` | No | Silent send. |
| `protect_content` | `Boolean` | No | Disable forwarding/saving. |
| `allow_paid_broadcast` | `Boolean` | No | High-throughput paid broadcast. |
| `message_effect_id` | `String` | No | Private chats only. |
| `suggested_post_parameters` | `SuggestedPostParameters` | No | Direct messages chats. |
| `reply_parameters` | `ReplyParameters` | No | Reply metadata. |
| `reply_markup` | Inline/reply keyboard types | No | Inline keyboards and reply keyboard controls. |

If a rich message contains media blocks, Telegram checks whether the bot has the corresponding send-media rights.

`sendRichMessageDraft`:

| Param | Type | Required | Notes |
| --- | --- | --- | --- |
| `chat_id` | `Integer` | Yes | Private chat only. |
| `message_thread_id` | `Integer` | No | Target topic/thread. |
| `draft_id` | `Integer` | Yes | Non-zero identifier. Updates with the same ID are animated. |
| `rich_message` | `InputRichMessage` | Yes | Partial rich content to stream. |

Drafts are ephemeral 30-second previews. Telegram expects the bot to later call `sendRichMessage` with the final content.

`editMessageText` relevant additions:

| Param | Type | Notes |
| --- | --- | --- |
| `text` | `String?` | Required if `rich_message` is absent. |
| `rich_message` | `InputRichMessage?` | Required if `text` is absent. |

`editMessageMedia` can replace a text or rich message with media.

### Rich Text Output Schema

`RichText` can be:

- string plain text
- array of `RichText`
- `bold`
- `italic`
- `underline`
- `strikethrough`
- `spoiler`
- `date_time`
- `text_mention`
- `subscript`
- `superscript`
- `marked`
- `code`
- `custom_emoji`
- `mathematical_expression`
- `url`
- `email_address`
- `phone_number`
- `bank_card_number`
- `mention`
- `hashtag`
- `cashtag`
- `bot_command`
- `anchor`
- `anchor_link`
- `reference`
- `reference_link`

The common wrapper shape is `{ type, text }` for styles, with variant-specific fields:

- `date_time`: `unix_time`, `date_time_format`
- `text_mention`: `user`
- `custom_emoji`: `custom_emoji_id`, `alternative_text`
- `mathematical_expression`: `expression`
- `url`: `url`
- `email_address`: `email_address`
- `phone_number`: `phone_number`
- `bank_card_number`: `bank_card_number`
- `mention`: `username`
- `hashtag`: `hashtag`
- `cashtag`: `cashtag`
- `bot_command`: `bot_command`
- `anchor`: `name`
- `anchor_link`: `anchor_name`
- `reference`: `name`
- `reference_link`: `reference_name`

### Rich Block Output Schema

Helper types:

`RichBlockCaption`:

- `text: RichText`
- `credit?: RichText`

`RichBlockTableCell`:

- `text?: RichText`
- `is_header?: true`
- `colspan?: Integer`
- `rowspan?: Integer`
- `align: "left" | "center" | "right"`
- `valign: "top" | "middle" | "bottom"`

`RichBlockListItem`:

- `label: String`
- `blocks: Array<RichBlock>`
- `has_checkbox?: true`
- `is_checked?: true`
- `value?: Integer`
- `type?: "a" | "A" | "i" | "I" | "1"`

Block variants:

| Type | Fields |
| --- | --- |
| `paragraph` | `text: RichText` |
| `heading` | `text: RichText`, `size: 1..6` |
| `pre` | `text: RichText`, `language?: String` |
| `footer` | `text: RichText` |
| `divider` | no payload beyond `type` |
| `mathematical_expression` | `expression: String` |
| `anchor` | `name: String` |
| `list` | `items: RichBlockListItem[]` |
| `blockquote` | `blocks: RichBlock[]`, `credit?: RichText` |
| `pullquote` | `text: RichText`, `credit?: RichText` |
| `collage` | `blocks: RichBlock[]`, `caption?: RichBlockCaption` |
| `slideshow` | `blocks: RichBlock[]`, `caption?: RichBlockCaption` |
| `table` | `cells: RichBlockTableCell[][]`, `is_bordered?: true`, `is_striped?: true`, `caption?: RichText` |
| `details` | `summary: RichText`, `blocks: RichBlock[]`, `is_open?: true` |
| `map` | `location: Location`, `zoom: 13..20`, `width: Integer`, `height: Integer`, `caption?: RichBlockCaption` |
| `animation` | `animation: Animation`, `has_spoiler?: true`, `caption?: RichBlockCaption` |
| `audio` | `audio: Audio`, `caption?: RichBlockCaption` |
| `photo` | `photo: PhotoSize[]`, `has_spoiler?: true`, `caption?: RichBlockCaption` |
| `video` | `video: Video`, `has_spoiler?: true`, `caption?: RichBlockCaption` |
| `voice_note` | `voice_note: Voice`, `caption?: RichBlockCaption` |
| `thinking` | `text: RichText` |

### Rich Markdown and HTML Input

Rich Markdown is broadly GitHub-Flavored-Markdown compatible and can include supported rich HTML tags. Telegram supports:

- Inline: bold, italic, strikethrough, inline code, marked text, spoiler, URL/email/tel/user links, custom emoji, formatted time, inline math, automatic entity detection.
- Blocks: headings, paragraphs, fenced code blocks with optional language, horizontal rules, unordered/ordered/checklist lists, blockquotes, tables, footnotes/references, display math, details, maps, collages, slideshows, media blocks.
- Media blocks only as separate blocks.
- Media block URLs only `http` and `https`.
- Table cells contain only inline formatting.
- Formula source is raw LaTeX.

Rich HTML supports only listed tags, including:

- Inline style tags: `b`, `strong`, `i`, `em`, `u`, `ins`, `s`, `strike`, `del`, `code`, `mark`, `sub`, `sup`, `tg-spoiler`, `tg-emoji`, `tg-time`, `tg-math`.
- Links: `a href`, `a name`, `mailto:`, `tel:`, `tg://user?id=...`, local anchors.
- References: `tg-reference`.
- Blocks: `h1` through `h6`, `p`, `pre`, nested `pre > code.language-*`, `footer`, `hr`, `ul`, `ol`, `li`, checkboxes as `input type="checkbox"`, `blockquote`, `aside`, `details`, `summary`, `table`, `caption`, `tr`, `th`, `td`, `tg-map`, `tg-collage`, `tg-slideshow`, `tg-math-block`.
- Media: `img`, `video`, `audio`, `figure`, `figcaption`, `cite`, `tg-spoiler` media attribute.

Only specific named HTML entities are accepted by Bot API, while numeric entities are accepted.

## MTProto/TL Schema

The latest checked client schemas include the rich-message constructors. This is the schema current clients render, and it is richer than the public Bot API JSON surface.

### Message and Draft

From TDLib `telegram_api.tl` layer 227 and tdesktop `api.tl`:

```tl
message#7600b9d3 ... flags2:# ... message:string ... entities:flags.7?Vector<MessageEntity> ... rich_message:flags2.13?RichMessage = Message;

draftMessage#60fe3294 flags:# no_webpage:flags.1?true invert_media:flags.6?true reply_to:flags.4?InputReplyTo message:string entities:flags.3?Vector<MessageEntity> media:flags.5?InputMedia date:int effect:flags.7?long suggested_post:flags.8?SuggestedPost rich_message:flags.9?RichMessage = DraftMessage;
```

Key implication: rich content is additive to message/draft, not encoded as the `message:string` field. Clients still keep a string summary/fallback.

### Rich Message Constructors

```tl
inputRichFilePhoto#9b00622b id:string photo:InputPhoto = InputRichFile;
inputRichFileDocument#83281dbd id:string document:InputDocument = InputRichFile;

inputRichMessage#e4c449fc flags:# rtl:flags.0?true noautolink:flags.1?true blocks:Vector<PageBlock> photos:flags.2?Vector<InputPhoto> documents:flags.3?Vector<InputDocument> users:flags.4?Vector<InputUser> = InputRichMessage;
inputRichMessageHTML#dacb836a flags:# rtl:flags.0?true noautolink:flags.1?true html:string files:flags.2?Vector<InputRichFile> = InputRichMessage;
inputRichMessageMarkdown#4b572c flags:# rtl:flags.0?true noautolink:flags.1?true markdown:string files:flags.2?Vector<InputRichFile> = InputRichMessage;

richMessage#baf39d8b flags:# rtl:flags.0?true part:flags.1?true blocks:Vector<PageBlock> photos:Vector<Photo> documents:Vector<Document> = RichMessage;
```

Important flags:

- `rtl` is whole-message layout direction.
- `noautolink` disables automatic entity/block detection.
- `part` means the message is partial; clients must fetch the full rich message before expanding.

### New PageBlock Constructors

```tl
pageBlockHeading1#baff072f text:RichText = PageBlock;
pageBlockHeading2#96b2aec text:RichText = PageBlock;
pageBlockHeading3#67e731ad text:RichText = PageBlock;
pageBlockHeading4#b532772b text:RichText = PageBlock;
pageBlockHeading5#dbbe6c6a text:RichText = PageBlock;
pageBlockHeading6#682a41a9 text:RichText = PageBlock;
pageBlockMath#59080c20 source:string = PageBlock;
pageBlockThinking#3c29a3e2 text:RichText = PageBlock;
pageBlockBlockquoteBlocks#e6e47c4 blocks:Vector<PageBlock> caption:RichText = PageBlock;
inputPageBlockMap#3d5b64f0 location:InputGeoPoint zoom:int w:int h:int caption:PageCaption = PageBlock;
```

The rest of rich-message blocks reuse existing Instant View `PageBlock` variants: paragraph, preformatted, footer, divider, lists, ordered lists, pullquote, blockquote, photo/video/audio, collage, slideshow, table, details, related articles, map, embeds, and channel blocks.

### Send, Edit, Draft, Inline

```tl
messages.sendMessage#fef48f62 flags:# ... message:string random_id:long ... entities:flags.3?Vector<MessageEntity> ... rich_message:flags.23?InputRichMessage = Updates;

messages.editMessage#b106e66c flags:# ... message:flags.11?string media:flags.14?InputMedia reply_markup:flags.2?ReplyMarkup entities:flags.3?Vector<MessageEntity> ... rich_message:flags.23?InputRichMessage = Updates;

messages.editInlineBotMessage#a423bb51 flags:# ... id:InputBotInlineMessageID message:flags.11?string media:flags.14?InputMedia reply_markup:flags.2?ReplyMarkup entities:flags.3?Vector<MessageEntity> rich_message:flags.23?InputRichMessage = Bool;

messages.saveDraft#ad0fa15c flags:# ... peer:InputPeer message:string entities:flags.3?Vector<MessageEntity> media:flags.5?InputMedia ... rich_message:flags.9?InputRichMessage = Bool;

messages.getRichMessage#501569cf peer:InputPeer id:int = messages.Messages;
```

Inline bot content:

```tl
inputBotInlineMessageRichMessage#b43df56c flags:# reply_markup:flags.2?ReplyMarkup rich_message:InputRichMessage = InputBotInlineMessage;
botInlineMessageRichMessage#a617e7b flags:# reply_markup:flags.2?ReplyMarkup rich_message:RichMessage = BotInlineMessage;
```

Streaming/pending draft actions:

```tl
inputSendMessageRichMessageDraftAction#e2b23b51 random_id:long rich_message:InputRichMessage = SendMessageAction;
sendMessageRichMessageDraftAction#a2cb24f9 random_id:long rich_message:RichMessage = SendMessageAction;
```

### TDLib API Mapping

TDLib exposes the normalized app-facing model:

```tl
richMessage blocks:vector<PageBlock> is_rtl:Bool is_full:Bool = RichMessage;

richMessageSourceMarkdown text:string = RichMessageSource;
richMessageSourceHtml text:string = RichMessageSource;

inputRichMessage source:RichMessageSource is_rtl:Bool detect_automatic_blocks:Bool = InputRichMessage;

draftMessageContentRichMessage message:richMessage = DraftMessageContent;
messageRichMessage message:richMessage = MessageContent;
inputMessageRichMessage message:inputRichMessage clear_draft:Bool = InputMessageContent;

updatePendingMessage chat_id:int53 forum_topic_id:int32 draft_id:int64 content:MessageContent = Update;
getFullRichMessage chat_id:int53 message_id:int53 = RichMessage;
sendRichMessageDraft chat_id:int53 forum_topic_id:int32 draft_id:int64 message:inputRichMessage = Ok;
```

TDLib comments say `updatePendingMessage.content` is always `messageText` or `messageRichMessage`. The pending rich message is shown only briefly, replaced by same `draft_id`, and removed when the final incoming bot message arrives in the same thread.

## TDLib Runtime Behavior

Files inspected:

- `/Users/mo/dev/telegram/td/td/telegram/RichMessage.cpp`
- `/Users/mo/dev/telegram/td/td/telegram/WebPageBlock.cpp`
- `/Users/mo/dev/telegram/td/td/telegram/DialogActionManager.cpp`
- `/Users/mo/dev/telegram/td/td/telegram/MessageContent.cpp`
- `/Users/mo/dev/telegram/td/td/telegram/MessagesManager.cpp`
- `/Users/mo/dev/telegram/td/td/telegram/OptionManager.cpp`

Key behavior:

- Incoming TL `richMessage` is converted into a TDLib `RichMessage` by processing `Photo` and `Document` vectors into media maps, then converting `PageBlock` values through the existing Instant View block parser.
- `richMessage.part` is inverted into `is_full`.
- `inputRichMessage` from TDLib app API only exposes Markdown/HTML source; the lower-level MTProto structured block variant exists internally.
- `detect_automatic_blocks = false` maps to TL `noautolink = true`.
- Strings are UTF-8-cleaned before parsing/sending.
- Rich messages participate in:
  - dependency collection
  - file ID collection
  - user ID collection
  - bot command detection
  - hashtag collection
  - custom emoji collection
  - message search indexing masks
  - send-permission checks by nested media block type
- `can_send` first requires normal message send rights, then validates media rights for photos/videos/audios/voice notes/animations and nested blocks.
- `DialogActionManager` converts rich-message draft actions into `td_api::updatePendingMessage(... messageRichMessage(...))` inside the configured pending-message period.

This is the reference architecture for Inline server validation: a rich message is not just render data. It must be walked for mentions, commands, hashtags, links, media permissions, dependencies, indexing, notifications, and previews.

## Telegram iOS Implementation

Current iOS source at `6e370e06...` has generated API files `Api0.swift` through `Api42.swift` with the new constructors:

- Parser registration:
  - `BotInlineMessage.parse_botInlineMessageRichMessage`
  - `InputBotInlineMessage.parse_inputBotInlineMessageRichMessage`
  - `InputRichMessage.parse_inputRichMessage`
  - `InputRichMessage.parse_inputRichMessageHTML`
  - `InputRichMessage.parse_inputRichMessageMarkdown`
  - `PageBlock.parse_pageBlockMath`
  - `PageBlock.parse_pageBlockThinking`
  - `RichMessage.parse_richMessage`
  - rich draft actions
- `Api16.swift` generated `Message` includes `richMessage: Api.RichMessage?`.
- `Api42.swift` generated functions include:
  - `messages.editInlineBotMessage(... richMessage: Api.InputRichMessage?)`
  - `messages.editMessage(... richMessage: Api.InputRichMessage?)`
  - `messages.getRichMessage(peer:id:)`
  - `messages.saveDraft(... richMessage: Api.InputRichMessage?)`
  - `messages.sendMessage(... richMessage: Api.InputRichMessage?)`

### iOS Storage Model

`submodules/TelegramCore/Sources/SyncCore/SyncCore_RichTextMessageAttribute.swift`:

- Defines `RichTextMessageAttribute: MessageAttribute`.
- Stores:
  - `instantPage: InstantPage`
  - `fullInstantPage: InstantPage?`
- Encodes both values into Postbox.
- Converts API `RichMessage` to `InstantPage` by:
  - converting photos to `TelegramMediaImage`
  - converting documents to `TelegramMediaFile`
  - mapping them into an `InstantPage.media` dictionary
  - converting each TL `PageBlock` into `InstantPageBlock`
  - preserving `rtl`
  - setting `isComplete = !part`
- Converts back to structured TL with `Api.InputRichMessage.inputRichMessage`, using `instantPage.blocks.compactMap { $0.apiInputBlock() }`.

`submodules/TelegramCore/Sources/ApiUtils/StoreMessage_Telegram.swift`:

- When an API message has `messageData.richMessage`, iOS appends `RichTextMessageAttribute(apiRichMessage:)`.
- It still stores ordinary `messageData.message` text and text entities separately.
- Tagging marks rich text messages distinctly enough for UI selection.

`submodules/TelegramCore/Sources/SyncCore/SyncCore_RichText.swift`:

- Defines a persisted recursive `RichText` enum with cases for plain, styles, URLs, email, concat, subscript, superscript, marked, phone, inline image, anchor, formula, custom emoji, auto detected entities, text mention, spoiler, and date.
- Stores compact integer tags and short Postbox keys.

`submodules/TelegramCore/Sources/ApiUtils/RichText.swift`:

- Maps API `RichText` to Swift `RichText` and back.
- Important supported inline cases: `textSubscript`, `textSuperscript`, `textMarked`, `textMath`, `textCustomEmoji`, auto URL/email/phone, bank card, bot command, cashtag, hashtag, mention, mention name, spoiler, date.

`submodules/TelegramCore/Sources/ApiUtils/InstantPage.swift`:

- Converts TL `PageBlock` to `InstantPageBlock`.
- New cases:
  - `pageBlockHeading1..6` -> `.heading(level:)`
  - `pageBlockMath` -> `.formula(latex:)`
  - `pageBlockThinking` -> `.thinking`
  - `pageBlockBlockquoteBlocks` -> `.blockQuote(blocks:caption:)`
- Converts many blocks back to API input blocks for outbound structured rich messages.

### iOS Rendering Path

`submodules/TelegramUI/Components/Chat/ChatMessageRichDataBubbleContentNode/Sources/ChatMessageRichDataBubbleContentNode.swift` is the chat bubble for rich messages.

Key choices:

- It uses `InstantPageV2View`, not the normal text bubble renderer.
- It lazily creates the page view in the main-thread apply closure.
- It keeps a `(message id, stableVersion, showMoreExpanded)` key to invalidate layout/view reuse.
- It builds a synthetic `TelegramMediaWebpage` around the rich message so Instant Page render context can reuse existing media/gallery/link infrastructure.
- It computes `layoutInstantPageV2` during async layout.
- It caches the layout unless a relative date/time entity needs time-based recomputation.
- It supports partial rich messages with a "Show more" affordance:
  - if `instantPage.isComplete == false`, show a link
  - on tap, call `engine.messages.requestFullRichText(id:)`
  - if `fullInstantPage` is already cached, expand without network
- It supports streaming/draft reveal:
  - creates `InstantPageV2RevealCostMap`
  - sizes the bubble to the revealed content prefix
  - applies reveal masks to text, code, details, tables, and media
  - keeps thinking blocks visible without adding reveal cost
- It handles taps through `pageView.urlItemAt`, `pageView.textItemAt`, and text attributes for mention, text mention, bot command, hashtag/cashtag, bank card, and date.
- It supports spoiler reveal by toggling display of concealed content across the rich page.
- It supports anchors and details expansion for in-message anchor scrolling.
- It builds a multi-text selection adapter across nested rich text items.

`submodules/InstantPageUI/Sources/InstantPageRenderer.swift`:

- `InstantPageV2View` owns stable item IDs and reuses child views during layout updates.
- Stable IDs are based on media index, details index, or positional kind.
- Media wrappers are registered by `media.index` for gallery transition and hidden-media updates.
- Text uses custom `InstantPageV2TextView` and `TextRenderView`.
- Details use nested `InstantPageV2View` for the body.
- Tables use `UIScrollView`, nested `InstantPageV2View` per title/cell, horizontal scrolling, row/cell overlays, and stable sub-layout updates.
- Formula blocks render through `InstantPageV2FormulaView` with pre-rendered math images and horizontal scroll for wide formulas.
- Thinking blocks use a custom shimmer/gradient mask over dimmed text.

`submodules/InstantPageUI/Sources/InstantPageV2Layout.swift`:

- Rich block layout maps `InstantPageBlock` cases to item arrays:
  - text, headings, author/date, code, lists, block quotes, pull quotes, formulas, tables, details, images/videos/audio/maps/collages/slideshows, thinking
- Uses CoreText line geometry to produce `InstantPageTextLine` values and per-character rects for reveal.
- Inline images and custom emoji are view/layer-owned by the parent page view, not separate message blocks.
- Inline formulas can inflate line metrics; custom emoji and images are centered on the line box and generally do not inflate lines.
- RTL is explicit and controls alignment, gutters, details chevron placement, table/list leading edges, and line positioning.
- Code blocks reuse syntax highlighting hooks and draw an inset/flush block depending on nesting.
- Tables compute min/max widths, row/col spans, header/background/border geometry, RTL mirroring, and horizontal scroll content.

`submodules/InstantPageUI/Sources/InstantPageV2RevealCost.swift`:

- Reveal cost is width-based, not character-count-based, so streaming speed is visually consistent across text, tables, and media.
- Text maps width budget to character masks using per-character rects.
- Tables reveal row by row and recurse into cell sub-layouts.
- Details reveal the title first, then recurse into body layout.
- Thinking blocks are visible but zero-cost to avoid shifting the streamed answer reveal position.

## Telegram Desktop Implementation

Current tdesktop `v6.9.3` contains the schema and rendering stack.

Important files:

- `Telegram/SourceFiles/mtproto/scheme/api.tl`
- `Telegram/SourceFiles/iv/iv_rich_page.h`
- `Telegram/SourceFiles/iv/iv_rich_page.cpp`
- `Telegram/SourceFiles/iv/iv_rich_message_serializer.cpp`
- `Telegram/SourceFiles/iv/markdown/iv_markdown_history_view_media.cpp`
- `Telegram/SourceFiles/iv/markdown/iv_markdown_article_layout_blocks.cpp`
- `Telegram/SourceFiles/iv/markdown/iv_markdown_article_paint.cpp`
- `Telegram/SourceFiles/iv/markdown/iv_markdown_parse.cpp`
- `Telegram/SourceFiles/history/history_streamed_drafts.cpp`

### Desktop Data Model

`Iv::RichPage`:

- `RichText` is represented as `TextWithEntities`, `anchorId`, and anchor IDs.
- `BlockKind` includes:
  - unsupported, heading, paragraph, footer, thinking, author date, code, divider, anchor, list, quote, photo, video, embed, embed post, grouped media, channel, audio, math, table, details, related articles, map.
- Blocks have fields for:
  - text/caption
  - language
  - formula
  - URL and HTML
  - author/channel/audio metadata
  - heading level
  - dimensions/zoom
  - media IDs
  - map coordinates/access hash
  - boolean layout/media flags
  - nested blocks/list items/media items/table rows/related articles.
- `RichMessageLimits` exactly match Bot API/TDLib limits.

### Desktop Parsing and Serialization

`iv_rich_page.cpp`:

- `ParseRichPage(session, MTPRichMessage)` reads `rtl`, photos, documents, and page blocks.
- Rich message parsing source is marked `ParseSource::RichMessage` to adjust inline image/media handling compared with normal Instant View pages.
- Rich text is converted to `TextWithEntities`.
- Inline text supports math, custom emoji, bold/italic/underline/strike/fixed, URL/email, subscript, superscript, marked, spoiler, mention, hashtag, bot command, cashtag, auto URL/email/phone, bank card, mention name, date, phone, and anchors.
- New blocks are mapped:
  - `pageBlockThinking` -> `BlockKind::Thinking`
  - `pageBlockHeading1..6` -> heading with level
  - `pageBlockMath` -> math block
  - `pageBlockBlockquoteBlocks` -> quote block with nested blocks
- `FlattenRichPageSummary` creates plain-ish `TextWithEntities` summary for chat rows, pending draft matching, notifications, and search.
- Tables and lists contribute flattened text with labels/prefixes.
- Media blocks contribute caption or media fallback labels.

`iv_rich_message_serializer.cpp`:

- Serializes `RichPage` back to TL `InputRichMessage`.
- Collects referenced input photos/documents/users.
- Serializes text entities to `MTPRichText`.
- Converts inline formula objects, custom emoji, date, and anchor/link structures.
- Serializes paragraph, heading, quote, details, list, table, map, media, collage/slideshow, etc.

`iv_markdown_parse.cpp`:

- Markdown parse limits for local IV input are larger than send limits:
  - source bytes: 4 MiB
  - cmark nodes: 100000
  - nesting: 128
  - formula bytes: 64 KiB
  - formula count: 10000
- Send-time rich message validation still uses the smaller `RichMessageLimits`.

### Desktop Rendering

`iv_markdown_article_layout_blocks.cpp`:

- Produces `PreparedBlockKind`/`LaidOutBlock` items for paragraphs, thinking, headings, code, math, tables, details, media, rule, quote, list, and grouped media.
- Code blocks expand tabs and include a trailing guard character.
- Tables compute column minimum widths, spans, row heights, borders, scroll viewport, and overflow behavior.
- Display math uses a rendered formula when available and falls back to text on render failure.
- Media blocks are centered and constrained with stable dimensions.

`iv_markdown_article_paint.cpp`:

- Paints text, code blocks, tables, display math, quotes, media, details, lists, and thinking.
- Thinking uses a sliding gradient animation.
- Tables paint headers, borders, scrollbars, selection overlays, and row bands.
- Display math paints a colorized formula raster and overflow affordances.
- Code/quote use cached quote/background painting primitives.

`iv_markdown_history_view_media.cpp`:

- Bridges Instant View rich media blocks to existing `HistoryView::Media`.
- Creates host/fake `HistoryItem` instances for embedded history media.
- Reuses existing media draw, hit-test, selection, heavy-part unloading, spoiler hiding, and activation infrastructure.

`history_streamed_drafts.cpp`:

- Handles `sendMessageRichMessageDraftAction`.
- Converts rich draft action to `Iv::ParseRichPage`.
- Flattens summary text for the temporary message.
- Creates local fake history messages with `setRichPage`.
- Updates same `random_id` by replacing page content and requesting text refresh.
- Matches final incoming rich messages to pending drafts by thread/from/kind/text, with special handling for empty rich summaries.
- Clears expired drafts after timeout.

## TelegramSwift macOS Client

Second-pass scope:

- Local and remote `master` are both `579cebbf0c01fd41b712eff3647fa7f69db9665d`.
- `origin/master` is the remote HEAD.
- The app-level source is present and clean.
- `submodules/telegram-ios` is a git submodule pinned to `a24bbe45f9861f736a79916a50898512f751e0dc`, but the local submodule directory is empty.
- The Xcode project references shared `TelegramCore` and `Postbox` through `submodules/telegram-ios/submodules/TelegramCore` and `submodules/telegram-ios/submodules/Postbox`.

Important limitation: the current public TelegramSwift source does not contain the new rich-message feature. Grepping the fetched public source for `RichMessage`, `InputRichMessage`, `rich_message`, `pageBlockThinking`, `pageBlockMath`, `pageBlockHeading`, `inputBotInlineMessageRichMessage`, `botInlineMessageRichMessage`, `sendMessageRichMessageDraftAction`, and `getRichMessage` returns no matches. There are also no local generated `Api*.swift` or `api.tl` files in the top-level app source. This means the current public Swift macOS client cannot be used as authoritative evidence for how Telegram's shipped macOS binary renders `message.rich_message`.

What it does contain is a substantial native Instant Page renderer, which is still relevant because rich messages reuse the same `InstantPage`/`PageBlock`/`RichText` mental model.

### macOS Chat Path

`Telegram-Mac/ChatMessageItem.swift`:

- Builds normal chat text from `message.text` plus `TextEntitiesMessageAttribute`.
- Calls `ChatMessageItem.applyMessageEntities(...)` to create a flat `NSMutableAttributedString`.
- Applies inline stickers/custom emoji to the flat text using `InlineStickerItem.apply`.
- Builds `TextViewLayout`/`FoldingTextLayout` for the message body.
- Checks `message.anyMedia as? TelegramMediaWebpage` and, if present, builds either `WPArticleLayout` or `WPMediaLayout`.
- If the webpage content has `instantPage`, the chat row still treats it as a link preview/article, not as primary message content.

There is no branch equivalent to iOS `RichTextMessageAttribute`, no `fullInstantPage`, no partial rich-message "Show more", and no chat bubble that renders a rich block tree as the message body.

### macOS Instant Page Entry Points

`Telegram-Mac/WPLayout.swift` and `Telegram-Mac/PeerMediaWebpageRowContent.swift`:

- Expose `hasInstantPage` for webpage previews.
- Suppress Instant Page affordances for some sites/types such as Instagram, Twitter, Telegram, and `telegram_album`.
- Special-case collage/slideshow previews by checking whether captions have visible rich text.
- Open Instant Page through `BrowserStateContext.get(...).open(tab: .instantView(url:webPage:anchor:))`.

This is preview-driven behavior. It is not rich chat-message rendering.

### macOS Instant Page Layout

`Telegram-Mac/InstantPageLayout.swift`:

- Converts a loaded `TelegramMediaWebpage.content.instantPage` into an `InstantPageLayout`.
- Uses `instantPage._parse().blocks`, `instantPage._parse().media`, and `instantPage.rtl`.
- Lays out blocks into an array of `InstantPageItem`.
- Tracks media, embed, and details indices during recursive layout.
- Computes spacing between blocks with `spacingBetweenBlocks`.
- Uses a fixed `17.0 + safeInset` horizontal inset for top-level page blocks.

Supported block cases in this public macOS renderer:

- cover
- title
- subtitle
- author/date
- kicker
- header
- subheader
- paragraph
- preformatted/code-style block
- footer
- divider
- list, ordered list, and list items containing nested blocks
- block quote
- pull quote
- image
- video
- collage
- post embed
- slideshow
- table
- details
- related articles
- map
- web embed
- channel banner
- anchor
- audio

Unsupported or not-yet-present for the new rich-message release:

- heading levels 1 through 6 as distinct block constructors
- display math block
- thinking block
- blockquote with nested blocks as the new TL constructor
- rich-message partial/full hydration
- rich-message draft streaming/reveal maps

Because the app lacks the new TL constructors, these cases would not compile into the current `InstantPageBlock` enum anyway. If TelegramSwift were updated for rich messages, it would need both shared TelegramCore schema/model updates and app-level layout cases for the new blocks.

### macOS RichText Rendering

`Telegram-Mac/InstantPageTextItem.swift`:

- `attributedStringForRichText(_:)` recursively converts `RichText` into `NSAttributedString`.
- Supports:
  - empty/plain
  - bold
  - italic
  - underline
  - strikethrough
  - fixed-width/code style
  - URL with optional webpage id
  - email
  - concat
  - subscript
  - superscript
  - marked text
  - phone links
  - inline image through a `CTRunDelegate`
  - anchor text/zero-width anchor
- Uses `InstantPageTextStyleStack` to accumulate font, color, marker color, underline, link, line spacing, and anchor attributes.
- Uses Core Text line layout (`CTLine`) and per-line geometry.
- Represents inline image/media with custom attributed-string attributes:
  - `.instantPageMediaIdAttribute`
  - `.instantPageMediaDimensionsAttribute`
  - `.instantPageAnchorAttribute`
  - `.instantPageMarkerColorAttribute`
  - `.instantPageLineSpacingFactorAttribute`

Missing compared with current iOS rich-message support:

- spoiler rich text in this path
- custom emoji rich text in this path
- mathematical-expression inline text
- auto entity rich-text variants for mention/hashtag/cashtag/bot command/bank card/date
- `text_mention`
- reference/reference link rich text

Those may exist in newer shared TelegramCore/iOS code, but they are not in the current public TelegramSwift app-level renderer.

### macOS Tables, Details, Anchors, and Selection

`Telegram-Mac/InstantPageTableItem.swift`:

- Builds table column min/max widths by laying out each cell's rich text twice: minimized width and normal width.
- Handles colspan, rowspan, horizontal alignment, vertical alignment, RTL mirroring, border sides, rounded corners, header fill, and additional nested items in cells.
- Renders table cells manually in `drawInTile`.
- Provides `textItemAtLocation` for selection within visible cell text.

`Telegram-Mac/InstantPageDetailsItem.swift` and `InstantPageViewController.swift`:

- Details blocks have stable indices and local expanded/collapsed state.
- `InstantPageViewController` keeps `currentExpandedDetails`, recalculates effective frames, and updates visible item positions when details expand.
- Anchor navigation can open nested details before scrolling to an anchor.

`Telegram-Mac/InstantPageSelectText.swift`:

- Implements multi-item text selection across Instant Page text lines.
- Descends into table cells and expanded details.
- Copies selected text by joining selected attributed ranges with newlines.
- Uses custom window mouse handlers instead of relying on `NSTextView` for the whole page.

### macOS Instant Page View Reuse

`Telegram-Mac/InstantPageViewController.swift`:

- Owns `currentLayout`, `currentLayoutTiles`, `currentLayoutItemsWithViews`, and `currentLayoutItemsWithLinks`.
- Virtualizes content by converting layout into tiles (`instantPageTilesFromLayout`) and only materializing visible item views.
- Reuses item views when `item.matchesView(...)` succeeds.
- Handles web embed height changes by debouncing layout reloads.
- Stores/restores scroll state and details expansion state through `InstantPageStoredState`.
- Has logic for incomplete Instant Pages: if an anchor is requested but `instantPage.isComplete == false`, it saves `pendingAnchor`.

This is a useful design reference for Inline macOS rendering:

- Layout should produce a plain item tree independent from AppKit views.
- Text drawing can be CoreText-backed with explicit line geometry.
- Tables/details/anchors need first-class layout state.
- Selection across nested block views is easier if rich text layout exposes text lines and coordinates.
- Web embed support should not be carried over to Inline rich messages in V1 for security.

### macOS Source Conclusion

TelegramSwift's public macOS source is not updated for Bot API 10.1 rich messages. It should not override the iOS, TDLib, or Telegram Desktop findings. The source still reinforces the same architectural conclusion: rich messages should be rendered as native block layouts over a canonical AST, not as flat attributed chat text.

For Inline, the practical macOS lesson is to copy the architectural shape, not the exact implementation:

- Keep a rich-message layout model separate from message row rendering.
- Reuse existing flat text/entity rendering only for inline runs.
- Build native table/details/anchor/selection support deliberately.
- Do not route rich messages through webpage preview layouts or WebViews.

## Inline Current State

Relevant current Inline paths:

- `proto/core.proto`
  - `Message.message: optional string`
  - `Message.entities: optional MessageEntities`
  - `SendMessageInput.message`, `entities`, `parse_markdown`
  - `EditMessageInput.text`, `entities`, `parse_markdown`
  - `DraftMessage.text`, `entities`
  - `MessageEntity.Type` is a flat enum: mention, url, text_url, email, bold, italic, username_mention, code, pre, phone_number, thread, thread_title, bot_command.
- `proto/client.proto`
  - `MessageContentPayload` currently has voice/actions/replies, no rich message.
- Server
  - `server/src/db/schema/messages.ts` stores encrypted `text`, encrypted `entities`, encrypted `actions`, plus `has_link`.
  - `server/src/functions/messages.sendMessage.ts` calls `processOutgoingText`, detects links/previews, encrypts text/entities/actions, inserts and emits updates.
  - `server/src/db/models/messages.ts` edit path encrypts text/entities/actions and updates `rev`.
  - `server/src/realtime/encoders/encodeMessage.ts` decrypts text/entities/actions and builds `Message`.
- Bot API
  - `packages/bot-api-types/src/index.ts` exposes text/entities/parse_markdown only.
  - `server/src/controllers/bot/types.ts` requires `text` for `sendMessage` and `editMessageText`.
  - `server/src/controllers/bot/entities.ts` maps the flat entity enum.
- Apple
  - `apple/InlineKit/Sources/InlineKit/Models/Message.swift` stores flat text/entities and content payload.
  - `apple/InlineUI/Sources/TextProcessing/ProcessEntities.swift` renders/extracts flat inline entities and parses a small Markdown subset.
  - macOS `MessageView.swift` and `MessageSizeCalculator.swift` cache attributed flat text.
  - iOS `UIMessageView` builds attributed strings through `ProcessEntities` and has code block support, but no block-level rich renderer.

Conclusion: do not extend `MessageEntities` into block-level formatting. Inline needs a separate rich message AST, with flat text/entities kept for fallback and compatibility.

## Inline Product Spec

### Product Behavior

Add first-class rich messages to Inline:

- Persistent rich messages sent by bots and, later, users.
- Rich Markdown and Rich HTML input for bot APIs.
- Rich message output in bot API responses and webhooks.
- Inline query result content support via `InputRichMessageContent`.
- Native rendering on iOS and macOS.
- Fallback text for older clients, notifications, search snippets, replies, quotes, and compact previews.
- Optional streaming rich drafts for bot/AI generation, modeled after Telegram's `sendRichMessageDraft`.

### Compatibility Rules

- Existing clients continue receiving `Message.message` fallback text and `Message.entities` where available.
- New clients prefer `Message.rich_message` when present.
- Bot API JSON should match Telegram names where practical:
  - `rich_message`
  - `sendRichMessage`
  - `sendRichMessageDraft`
  - `InputRichMessageContent`
  - `RichText`, `RichBlock`, `RichMessage`
- Internal protobuf can carry `is_complete` for client hydration even if the Bot API JSON omits it.
- Existing `sendMessage` remains text-only for compatibility. Add `sendRichMessage`; add `editMessageText.rich_message` to match Telegram.

## Inline Protocol Proposal

Add rich types to `proto/core.proto`.

Recommended message additions:

```proto
message Message {
  // Existing fields...
  optional string message = 5;
  optional MessageEntities entities = 16;

  // New. Clients render this instead of message/entities when present.
  optional RichMessage rich_message = 22;
}

message SendMessageInput {
  optional string message = 2;
  optional MessageEntities entities = 7;
  optional bool parse_markdown = 8;

  // New. Use SendRichMessage RPC/API externally; keep field for internal transaction reuse.
  optional InputRichMessage rich_message = 11;
}

message EditMessageInput {
  optional string text = 3;
  optional MessageEntities entities = 7;
  optional bool parse_markdown = 8;
  optional InputRichMessage rich_message = 10;
}

message DraftMessage {
  string text = 1;
  optional MessageEntities entities = 2;
  optional RichMessage rich_message = 3;
}
```

Add core rich types:

```proto
message RichMessage {
  repeated RichBlock blocks = 1;
  bool is_rtl = 2;
  bool is_complete = 3;
  string fallback_text = 4;
  optional MessageEntities fallback_entities = 5;
}

message InputRichMessage {
  oneof source {
    RichMarkdown markdown = 1;
    RichHtml html = 2;
    RichBlocks blocks = 3; // internal/trusted, not public Bot API V1
  }
  bool is_rtl = 4;
  bool skip_entity_detection = 5;
}

message RichMarkdown { string text = 1; }
message RichHtml { string text = 1; }
message RichBlocks { repeated RichBlock blocks = 1; }
```

Add recursive inline text:

```proto
message RichText {
  oneof value {
    string plain = 1;
    RichTextList list = 2;
    RichTextStyle bold = 3;
    RichTextStyle italic = 4;
    RichTextStyle underline = 5;
    RichTextStyle strikethrough = 6;
    RichTextStyle spoiler = 7;
    RichTextStyle code = 8;
    RichTextStyle subscript = 9;
    RichTextStyle superscript = 10;
    RichTextStyle marked = 11;
    RichTextCustomEmoji custom_emoji = 12;
    RichTextMath math = 13;
    RichTextUrl url = 14;
    RichTextEmail email_address = 15;
    RichTextPhone phone_number = 16;
    RichTextBankCard bank_card_number = 17;
    RichTextMention mention = 18;
    RichTextHashtag hashtag = 19;
    RichTextCashtag cashtag = 20;
    RichTextBotCommand bot_command = 21;
    RichTextTextMention text_mention = 22;
    RichTextDateTime date_time = 23;
    RichTextAnchor anchor = 24;
    RichTextAnchorLink anchor_link = 25;
    RichTextReference reference = 26;
    RichTextReferenceLink reference_link = 27;
  }
}
```

Use wrapper messages rather than enum+payload maps. This keeps generated Swift/TS types usable and avoids `Any`.

Add block types:

```proto
message RichBlock {
  oneof value {
    RichBlockParagraph paragraph = 1;
    RichBlockHeading heading = 2;
    RichBlockPre pre = 3;
    RichBlockFooter footer = 4;
    RichBlockDivider divider = 5;
    RichBlockMath math = 6;
    RichBlockAnchor anchor = 7;
    RichBlockList list = 8;
    RichBlockBlockquote blockquote = 9;
    RichBlockPullquote pullquote = 10;
    RichBlockCollage collage = 11;
    RichBlockSlideshow slideshow = 12;
    RichBlockTable table = 13;
    RichBlockDetails details = 14;
    RichBlockMap map = 15;
    RichBlockMedia media = 16;
    RichBlockThinking thinking = 17;
  }
}
```

Media blocks should refer to canonical Inline media references, not raw remote URLs:

```proto
message RichMediaRef {
  string id = 1;          // stable rich-message-local media id
  int64 file_id = 2;      // Inline file/blob id when ingested
  string mime_type = 3;
  int32 width = 4;
  int32 height = 5;
  int32 duration = 6;
}

message RichBlockMedia {
  enum Kind {
    KIND_UNSPECIFIED = 0;
    ANIMATION = 1;
    AUDIO = 2;
    PHOTO = 3;
    VIDEO = 4;
    VOICE_NOTE = 5;
  }
  Kind kind = 1;
  RichMediaRef media = 2;
  bool has_spoiler = 3;
  optional RichBlockCaption caption = 4;
}
```

Reason: Telegram lets Bot API input reference HTTP(S) media URLs, but clients render resolved Telegram media objects. Inline should likewise resolve remote media server-side and store stable media/file references. Clients should not fetch arbitrary rich-message media URLs directly from message bodies.

### RealtimeV2 and Transactions

Add client-facing RealtimeV2 paths, not legacy HTTP client flows:

- `sendRichMessage`
  - input: `peer`, `rich_message`, `reply`, actions/keyboard if supported
  - output: normal `Message`
- `editMessage` accepts either text or `InputRichMessage`, mutually exclusive.
- `sendRichMessageDraft`
  - input: `peer`, optional thread, `draft_id`, `rich_message`
  - output: ack
- `UpdatePendingMessage`
  - `draft_id`
  - `content` oneof text/rich message
  - `expires_at`

If streaming is deferred, still reserve protobuf field numbers and design it now to avoid repainting the protocol later.

## Inline Server Spec

### DB and Encryption

Add encrypted rich message columns to `server/src/db/schema/messages.ts`:

- `rich_message_encrypted bytea`
- `rich_message_iv bytea`
- `rich_message_tag bytea`
- optional `rich_message_fallback_encrypted` only if fallback diverges from existing `text_encrypted`

Preferred invariant:

- `text_encrypted` remains the flat fallback/search/notification text for all rich messages.
- `entities_encrypted` can hold fallback entities if the fallback has meaningful inline spans.
- `rich_message_*` holds `RichMessage.toBinary(...)`.
- Edits update `rev` and all three representations atomically.

Do not store rich blocks in `MessageContentPayload` unless we first fix/standardize payload encoding. The rich message is primary message content, not an auxiliary payload.

### Parser and Canonicalizer

Implement server-only parsing in `server/src/modules/richMessage/`.

Recommended modules:

- `types.ts`: TS internal AST mirroring protobuf.
- `parseMarkdown.ts`: Markdown source to AST.
- `parseHtml.ts`: HTML source to AST.
- `normalize.ts`: canonical ordering/defaults.
- `validate.ts`: limits, security, permissions.
- `flatten.ts`: fallback text/entities, mentions, hashtags, bot commands, links.
- `media.ts`: resolve/fetch/attach media URLs.
- `encodeBot.ts`: Bot API JSON output.
- `fixtures/`: Telegram-compatible syntax fixtures.

Technical parser choice:

- Use a real Markdown parser with GFM support for tables, footnotes, task lists, raw HTML, and math extensions. A server-only pinned dependency is justified here; hand-rolling full rich Markdown would be fragile.
- Use a structured HTML parser such as `parse5`/HAST, not regex.
- Canonicalize both HTML and Markdown into the same AST.
- Clients render only canonical protobuf, never raw bot-provided HTML/Markdown.

Security rules:

- Reject or strip unsupported HTML tags and attributes.
- Only allow URL schemes:
  - inline links: `https`, `http`, `mailto`, `tel`, app-approved internal schemes
  - mentions: internal user IDs or safe username forms
  - media URLs: `https` and maybe `http` only if product accepts Telegram parity; prefer `https`
- No script/style/event handler attributes.
- No arbitrary iframes/embeds in V1.
- Media fetcher must enforce:
  - content length cap
  - MIME sniffing
  - redirect limit
  - private IP/localhost denial
  - timeout
  - virus/media validation if existing pipeline supports it
  - dedupe and object-storage upload before message commit
- Formula source is plain text; do not run external TeX commands on the server.

Validation rules:

- Apply Telegram limits exactly unless product chooses stricter caps.
- Count text as UTF-8 bytes/chars consistently. Telegram says UTF-8 characters; for offsets, Inline should stay in protobuf `Int64` with Swift-safe string index conversion.
- Count list items, table rows, quotation/details children, and nested blocks against total block count.
- Count formula source and custom emoji alt text in text length.
- Enforce depth before recursion becomes expensive.
- Enforce table column count after spans normalize.

### Send/Edit Integration

`messages.sendMessage` shared logic should branch early:

1. If `input.rich_message` is present:
   - parse/canonicalize input
   - resolve media
   - validate chat permissions and bot permissions
   - flatten fallback text/entities
   - detect preview/link/mentions from canonical rich text
   - encrypt text/entities/rich_message/actions
   - insert
2. Else use existing text flow.

Do not parse rich content inside computed properties or encoders. Encoders only decrypt and serialize already canonical content.

`editMessage`:

- Text edit clears `rich_message_*`.
- Rich edit clears old text entities only if replaced by new fallback entities.
- Media edit clears rich message and text fields according to existing semantics.
- Preserve `rev` monotonic behavior and update all realtime clients.

### Bot API

Add types to `packages/bot-api-types/src/index.ts`:

- `BotRichText`
- `BotRichBlock*`
- `BotRichMessage`
- `BotInputRichMessage`
- `BotInputRichMessageContent`
- `SendRichMessageParams`
- `SendRichMessageDraftParams`
- add `rich_message?: BotRichMessage` to `BotMessage`
- add `rich_message?: BotInputRichMessage` to `EditMessageTextParams`

Add routes in `server/src/controllers/bot/bot.ts`:

- `POST /bot/:token/sendRichMessage`
- `POST /bot/:token/sendRichMessageDraft`
- update `/editMessageText` to accept `rich_message`
- update inline query answer validation to allow `input_message_content: { rich_message }`

For Bot API output, match Telegram JSON names. Do not expose internal `is_complete` unless we intentionally diverge. For pending draft APIs, if we expose updates internally to bots, keep separate from Telegram-compatible Bot API output.

## Inline Apple Rendering Spec

### Shared Swift Model

Regenerate protobuf into `apple/InlineProtocol`. Add lightweight Swift helpers in `InlineKit`:

- `RichMessage+Flatten.swift`
- `RichText+Attributed.swift`
- `RichMessageLayoutKey`
- `RichBlockID` stable identity helper

Do not extend `ProcessEntities` to parse/render blocks. Reuse its palette/entity styling only for inline spans.

### Renderer Architecture

Create shared renderer package code under `apple/InlineUI/Sources/RichMessage/`:

- `RichMessageViewModel`: immutable message + theme + width input.
- `RichMessageLayout`: value type with measured block frames.
- `RichMessageLayoutCache`: keyed by message id, rev, rich hash, width, theme variant.
- `RichTextRunBuilder`: converts `RichText` to `NSAttributedString` / attributed runs.
- `RichBlockRenderer`: iOS/macOS adapters.

Requirements:

- Message row structs stay render-only.
- No parsing in `MessageView`, `UIMessageView`, or `MessageSizeCalculator`.
- Layout should be computed in the same phase that currently measures message rows, then cached.
- Rendering updates should reuse views/layers where possible for streaming drafts and edits.

### iOS

Add a `RichMessageBubbleView` for UIKit message cells:

- Input: `RichMessage`, layout, theme, tap handlers.
- Use existing text rendering utilities for attributed text.
- Code blocks reuse or adapt current `CodeBlockTextView`.
- Tables use horizontal `UIScrollView`; cells render nested inline text only in V1.
- Details use a `UIButton`/disclosure row plus nested rich block view; expanded state local to message id.
- Media blocks reuse current image/video/audio attachment views after server ingestion.
- Spoilers use existing spoiler reveal model if available; otherwise V1 tap-to-reveal per block.
- Links/mentions/bot commands/hashtags/cards/dates feed into existing tap-action routing.

Streaming drafts:

- Add reveal support only after static rendering is stable.
- Start with replacing whole layout on `draft_id`.
- Then add Telegram-like width-based reveal maps if AI output needs smooth streaming.

### macOS

Add `RichMessageBubbleView` / `RichMessageViewAppKit`:

- Integrate with `MessageViewAppKit`, `MinimalMessageViewAppKit`, and `MessageSizeCalculator`.
- Layout cache key must include rich message hash, width, theme, minimal/bubble style, and rev.
- Use `NSTextView`/TextKit only where selection or multi-line link hit-testing requires it; otherwise prefer light attributed text drawing/layers.
- Code blocks reuse `CodeBlockTextView` style.
- Tables use `NSScrollView` with stable content size.
- Details use disclosure button and cached expanded state.
- Media blocks use existing attachment renderers and hit-testing.

Avoid WebView for rich message rendering. Telegram's clients render native ASTs; Inline should do the same for security and hot-list performance.

### Rendering Parity Priorities

V1:

- paragraphs
- headings 1-6
- bold/italic/underline/strike/marked/code/spoiler
- sub/sup
- links, mentions, hashtags, cashtags, bot commands, phone/email/bank card/date
- custom emoji as existing custom emoji support allows
- pre/code blocks
- divider
- blockquote/pullquote
- lists, ordered lists, checklists
- tables with horizontal scroll
- details
- thinking block
- math as rendered image if feasible; otherwise raw LaTeX fallback with monospaced styling

V2:

- server-ingested media blocks
- collage/slideshow
- map block
- inline image
- full math renderer parity
- rich draft streaming reveal maps
- full text selection across nested blocks

## Search, Mentions, Notifications

For each rich message, derive:

- `fallback_text`: deterministic flattened text.
- fallback entities where possible.
- mentioned user IDs.
- URLs/link preview candidates.
- hashtags/cashtags.
- bot commands.
- custom emoji IDs.
- media dependency IDs.

Use the flattened text for:

- chat list previews
- push notifications
- reply previews
- search index
- moderation logs
- old clients

Use the rich AST for:

- message body rendering
- bot API output
- client copy/export where supported

## Rollout Plan

Phase 0: schema and parser fixtures

- Add proto messages.
- Generate TS/Swift.
- Add parser/canonicalizer behind feature flag.
- Add golden fixtures covering Markdown, HTML, nested blocks, tables, details, media URL rejection, math, and malicious HTML.

Phase 1: bot API persistent rich text without media ingestion

- Add `sendRichMessage`, `editMessageText.rich_message`, output JSON.
- Support text-only blocks and tables/details/code/math fallback.
- Store encrypted rich message + fallback text.
- Apple clients render static rich blocks.
- Older clients show fallback text.

Phase 2: media blocks

- Add server-side media URL ingestion.
- Add media refs in AST.
- Render photo/video/audio/voice/animation blocks.
- Add media permission checks.

Phase 3: inline mode

- Add `InputRichMessageContent` to inline query results.
- Ensure chosen inline messages persist as rich messages.
- Add validation for inline result payload size and remote media public URL semantics.

Phase 4: streaming rich drafts

- Add `sendRichMessageDraft`.
- Add `UpdatePendingMessage`.
- Add client pending-message row replacement keyed by `draft_id`.
- Start with whole-content replacement; add reveal maps if needed.

Phase 5: full parity polish

- Native formula renderer.
- Collage/slideshow.
- Map blocks.
- Rich copy/selection/export.
- Anchor navigation and details auto-expansion.

## Tests

Server:

- Parser golden tests for Markdown and HTML.
- Malicious HTML sanitization tests.
- Limit tests for text length, blocks, depth, media count, table columns.
- Flattening tests for nested blocks.
- Mention/link/hashtag/bot command extraction from rich content.
- Send/edit transaction tests:
  - rich send stores encrypted rich blob and fallback
  - text edit clears rich blob
  - rich edit updates rev and fallback
  - old text send unaffected
- Bot API tests:
  - `sendRichMessage`
  - `editMessageText` text-to-rich and rich-to-text
  - `InputRichMessageContent`
  - invalid both `html` and `markdown`
  - invalid neither `html` nor `markdown`

Apple:

- Swift model decode/encode tests.
- Layout tests for headings/lists/tables/details/code.
- Snapshot tests for iOS/macOS rich message fixtures.
- Hit-test tests for links/mentions/spoilers/details.
- Size-cache tests keyed by rev/theme/width/rich hash.
- Performance test: rich message row layout does not parse raw Markdown/HTML and does not synchronously hit DB.

Bot API packages:

- Type tests for new JSON shapes.
- Client request serialization tests.

## Open Questions

- Should Inline expose structured `blocks` input publicly, or only Markdown/HTML like Telegram Bot API? Recommendation: public V1 only Markdown/HTML; structured blocks internal/trusted until client authoring exists.
- Should rich media input allow `http`, or require `https`? Recommendation: require `https` unless a strong compatibility requirement appears.
- Should math rendering ship in V1? Recommendation: parse/canonicalize in V1, render as safe fallback if native rendering is not ready.
- Should normal user compose support full rich Markdown immediately? Recommendation: bots first, then user compose after render/storage stabilizes.
- Should `MessageContentPayload` be cleaned up before rich messages? Recommendation: no. Keep rich content as a first-class encrypted message field.

## Production Risks

Security:

- HTML parsing/sanitization is the largest risk.
- Remote media ingestion can become SSRF if URL fetching is not locked down.
- Formula rendering must not execute shell TeX.
- Link spoofing and concealed URL warnings need product decisions.

Performance:

- Rich messages can be large, nested, and table-heavy.
- Parsing must be server-side only.
- Client layout must be cached and avoid per-row heavy work.
- Media blocks must have stable dimensions before render to avoid scroll jumps.

Backward compatibility:

- Older clients need reliable fallback text.
- Bot API clients need Telegram-compatible names.
- Realtime clients must tolerate absent `rich_message`.

Implementation tradeoff:

- Matching Telegram exactly requires a full parser, canonical AST, native renderers, media ingestion, and streaming drafts. The pragmatic path is to implement the model and static renderer first, then media and streaming once the storage/rendering contract is stable.
