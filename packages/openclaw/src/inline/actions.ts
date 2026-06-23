import type {
  ChannelMessageActionAdapter,
  ChannelMessageActionName,
  ChannelMessageToolDiscovery,
  ChannelMessageToolSchemaContribution,
} from "openclaw/plugin-sdk/channel-contract"
import {
  normalizeInteractiveReply,
  reduceInteractiveReply,
  type InteractiveReplyButton,
} from "openclaw/plugin-sdk/interactive-runtime"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import {
  InlineSdkClient,
  Method,
  type Chat,
  type Dialog,
  type Message,
  type MessageActions,
  type User,
} from "@inline-chat/realtime-sdk"
import { listInlineAccountIds, resolveInlineAccount, resolveInlineToken } from "./accounts.js"
import { downloadInlineMediaFromUrl, uploadInlineMediaFromUrl } from "./media.js"
import { summarizeInlineMessageContent } from "./message-content.js"
import { sanitizeInlineOutgoingText } from "./message-formatting.js"
import { normalizeInlineTarget } from "./normalize.js"
import { recordInlineThreadParticipation } from "./thread-participation.js"
import {
  lookupInlineReplyThreadRoute,
  lookupInlineReplyThreadRouteByThreadId,
  rememberInlineReplyThreadRoute,
} from "./thread-routes.js"
import {
  sanitizeInlineActionCallbackData,
  sanitizeInlineActionCopyText,
  sanitizeInlineActionLabel,
  sanitizeInlineVisibleText,
} from "./outbound-sanitize.js"
import { resolveInlineInteractiveTextFallback } from "./interactive-fallback.js"
import { buildInlineUserDisplayName, getSpaceMembersWithUsers } from "./space-members.js"
import {
  createActionGate,
  jsonResult,
  readReactionParams,
  readNumberParam,
  readStringParam,
} from "../openclaw-compat.js"

type InlineActionGateKey =
  | "send"
  | "reply"
  | "reactions"
  | "read"
  | "search"
  | "translate"
  | "edit"
  | "channels"
  | "participants"
  | "delete"
  | "pins"
  | "permissions"

type InlineMessageActionName =
  | ChannelMessageActionName
  | "upload-file"
  | "download-file"
  | "compose-action"
  | "typing"
  | "stop-typing"
  | "uploading-photo"
  | "uploading-document"
  | "uploading-video"
  | "recording-voice"
  | "forward"
  | "forwardMessages"
  | "get-messages"
  | "getMessages"
  | "bot-commands"
  | "botCommands"
  | "peer-bot-commands"
  | "peerBotCommands"
  | "translate"
  | "translateMessages"
  | "invite-to-space"
  | "inviteToSpace"
  | "delete-attachment"
  | "deleteMessageAttachment"

const ACTION_GROUPS: Array<{
  key: InlineActionGateKey
  defaultEnabled: boolean
  actions: InlineMessageActionName[]
}> = [
  {
    key: "send",
    defaultEnabled: true,
    actions: [
      "send",
      "sendAttachment",
      "upload-file",
      "compose-action",
      "typing",
      "stop-typing",
      "uploading-photo",
      "uploading-document",
      "uploading-video",
      "recording-voice",
      "forward",
      "forwardMessages",
    ],
  },
  { key: "reply", defaultEnabled: true, actions: ["reply", "thread-reply"] },
  { key: "reactions", defaultEnabled: true, actions: ["react", "reactions"] },
  {
    key: "read",
    defaultEnabled: true,
    actions: [
      "read",
      "get-messages",
      "getMessages",
      "bot-commands",
      "botCommands",
      "peer-bot-commands",
      "peerBotCommands",
      "download-file",
    ],
  },
  { key: "search", defaultEnabled: true, actions: ["search"] },
  { key: "translate", defaultEnabled: true, actions: ["translate", "translateMessages"] },
  { key: "edit", defaultEnabled: true, actions: ["edit"] },
  {
    key: "channels",
    defaultEnabled: true,
    actions: [
      "channel-info",
      "channel-edit",
      "renameGroup",
      "channel-list",
      "channel-create",
      "channel-delete",
      "channel-move",
      "thread-list",
      "thread-create",
    ],
  },
  {
    key: "participants",
    defaultEnabled: true,
    actions: [
      "addParticipant",
      "removeParticipant",
      "kick",
      "leaveGroup",
      "member-info",
      "invite-to-space",
      "inviteToSpace",
    ],
  },
  { key: "delete", defaultEnabled: true, actions: ["delete", "unsend", "delete-attachment", "deleteMessageAttachment"] },
  { key: "pins", defaultEnabled: true, actions: ["pin", "unpin", "list-pins"] },
  { key: "permissions", defaultEnabled: true, actions: ["permissions"] },
]

const ACTION_TO_GATE_KEY = new Map<InlineMessageActionName, InlineActionGateKey>()
for (const group of ACTION_GROUPS) {
  for (const action of group.actions) {
    ACTION_TO_GATE_KEY.set(action, group.key)
  }
}

const SUPPORTED_ACTIONS = Array.from(ACTION_TO_GATE_KEY.keys())
const GET_MESSAGES_METHOD =
  typeof (Method as Record<string, unknown>).GET_MESSAGES === "number" &&
  Number.isInteger((Method as Record<string, unknown>).GET_MESSAGES) &&
  ((Method as Record<string, unknown>).GET_MESSAGES as number) > 0
    ? ((Method as Record<string, unknown>).GET_MESSAGES as Method)
    : (38 as Method)
const GET_PEER_BOT_COMMANDS_METHOD =
  typeof (Method as Record<string, unknown>).GET_PEER_BOT_COMMANDS === "number" &&
  Number.isInteger((Method as Record<string, unknown>).GET_PEER_BOT_COMMANDS) &&
  ((Method as Record<string, unknown>).GET_PEER_BOT_COMMANDS as number) > 0
    ? ((Method as Record<string, unknown>).GET_PEER_BOT_COMMANDS as Method)
    : (45 as Method)
const CREATE_SUBTHREAD_METHOD =
  typeof (Method as Record<string, unknown>).CREATE_SUBTHREAD === "number" &&
  Number.isInteger((Method as Record<string, unknown>).CREATE_SUBTHREAD) &&
  ((Method as Record<string, unknown>).CREATE_SUBTHREAD as number) > 0
    ? ((Method as Record<string, unknown>).CREATE_SUBTHREAD as Method)
    : (42 as Method)
const UPDATE_CHAT_VISIBILITY_METHOD =
  typeof (Method as Record<string, unknown>).UPDATE_CHAT_VISIBILITY === "number" &&
  Number.isInteger((Method as Record<string, unknown>).UPDATE_CHAT_VISIBILITY) &&
  ((Method as Record<string, unknown>).UPDATE_CHAT_VISIBILITY as number) > 0
    ? ((Method as Record<string, unknown>).UPDATE_CHAT_VISIBILITY as Method)
    : (30 as Method)
const INVITE_TO_SPACE_METHOD =
  typeof (Method as Record<string, unknown>).INVITE_TO_SPACE === "number" &&
  Number.isInteger((Method as Record<string, unknown>).INVITE_TO_SPACE) &&
  ((Method as Record<string, unknown>).INVITE_TO_SPACE as number) > 0
    ? ((Method as Record<string, unknown>).INVITE_TO_SPACE as Method)
    : (12 as Method)
const DELETE_MESSAGE_ATTACHMENT_METHOD =
  typeof (Method as Record<string, unknown>).DELETE_MESSAGE_ATTACHMENT === "number" &&
  Number.isInteger((Method as Record<string, unknown>).DELETE_MESSAGE_ATTACHMENT) &&
  ((Method as Record<string, unknown>).DELETE_MESSAGE_ATTACHMENT as number) > 0
    ? ((Method as Record<string, unknown>).DELETE_MESSAGE_ATTACHMENT as Method)
    : (55 as Method)
const FORWARD_MESSAGES_METHOD =
  typeof (Method as Record<string, unknown>).FORWARD_MESSAGES === "number" &&
  Number.isInteger((Method as Record<string, unknown>).FORWARD_MESSAGES) &&
  ((Method as Record<string, unknown>).FORWARD_MESSAGES as number) > 0
    ? ((Method as Record<string, unknown>).FORWARD_MESSAGES as Method)
    : (29 as Method)
const SEND_COMPOSE_ACTION_METHOD =
  typeof (Method as Record<string, unknown>).SEND_COMPOSE_ACTION === "number" &&
  Number.isInteger((Method as Record<string, unknown>).SEND_COMPOSE_ACTION) &&
  ((Method as Record<string, unknown>).SEND_COMPOSE_ACTION as number) > 0
    ? ((Method as Record<string, unknown>).SEND_COMPOSE_ACTION as Method)
    : (20 as Method)

const INLINE_ACTION_MAX_ROWS = 8
const INLINE_ACTION_MAX_PER_ROW = 8
const COMPOSE_ACTION_NONE = 0
const COMPOSE_ACTION_TYPING = 1
const COMPOSE_ACTION_UPLOADING_PHOTO = 2
const COMPOSE_ACTION_UPLOADING_DOCUMENT = 3
const COMPOSE_ACTION_UPLOADING_VIDEO = 4
const COMPOSE_ACTION_RECORDING_VOICE = 5
const HISTORY_MODE_LATEST = 1
const HISTORY_MODE_OLDER = 2
const HISTORY_MODE_NEWER = 3
const HISTORY_MODE_AROUND = 4
const INLINE_BOT_PRESENCE_KINDS = [
  "idle",
  "happy",
  "waving",
  "jumping",
  "failed",
  "waiting",
  "running",
  "review",
] as const

const inlineBotPresenceChannelDataSchema = {
  type: "object",
  description: "Inline-specific metadata for a send. Use inline.botPresence for the bot's on-screen body.",
  additionalProperties: true,
  properties: {
    inline: {
      type: "object",
      additionalProperties: true,
      properties: {
        botPresence: {
          type: "object",
          description: "Optional Inline bot presence state generated from your current mood or process.",
          additionalProperties: true,
          properties: {
            kind: {
              type: "string",
              enum: INLINE_BOT_PRESENCE_KINDS,
              description: "Emotion/state for the on-screen bot presence.",
            },
            comment: {
              type: "string",
              maxLength: 30,
              description:
                "Optional short expression from your actual current thought, status, mood, request, or aside. Text or one/two emoji.",
            },
          },
        },
      },
    },
  },
} as unknown as ChannelMessageToolSchemaContribution["properties"][string]

const inlineThreadCreateSchemaProperties = {
  spaceId: {
    type: "string",
    description: "Optional Inline space id for a top-level thread. Required for public threads.",
  },
  space: {
    type: "string",
    description: "Alias for spaceId.",
  },
  isPublic: {
    type: "boolean",
    description:
      "Create a public space thread. Public threads require spaceId and ignore participants.",
  },
  participant: {
    type: "string",
    description:
      "Inline user id, @username, or comma-separated users for a private top-level thread or reply thread participants.",
  },
  participants: {
    oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }],
    description:
      "Inline user ids, @usernames, or names for a private top-level thread or reply thread participants.",
  },
  participantId: {
    type: "string",
    description: "Inline user id for a private top-level thread or reply thread participant.",
  },
  participantIds: {
    oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }],
    description: "Inline user ids for a private top-level thread or reply thread participants.",
  },
  userId: {
    type: "string",
    description: "Alias for participantId when creating a thread.",
  },
  userIds: {
    oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }],
    description: "Alias for participantIds when creating a thread.",
  },
} as unknown as ChannelMessageToolSchemaContribution["properties"]

const inlineThreadReplySchemaProperties = {
  threadId: {
    type: "string",
    description: "Inline reply-thread chat id. Returned by thread-create and used as the send target.",
  },
  parentMessageId: {
    type: "string",
    description:
      "Parent chat message id used to recover a previously created Inline reply thread when threadId is unavailable.",
  },
  anchorMessageId: {
    type: "string",
    description: "Alias for parentMessageId.",
  },
} as unknown as ChannelMessageToolSchemaContribution["properties"]

const inlineReactionSchemaProperties = {
  to: {
    type: "string",
    description: "Inline target (`chat:<id>`, bare chat id, or `user:<id>`). Defaults to the current thread/chat when available.",
  },
  target: {
    type: "string",
    description: "Alias for to.",
  },
  chatId: {
    type: "string",
    description: "Inline chat id.",
  },
  channelId: {
    type: "string",
    description: "Alias for chatId.",
  },
  threadId: {
    type: "string",
    description: "Inline reply-thread chat id to react in.",
  },
  messageId: {
    type: "string",
    description: "Inline message id to react to. Defaults to the current inbound message when available.",
  },
} as unknown as ChannelMessageToolSchemaContribution["properties"]

const inlineTranslateSchemaProperties = {
  language: {
    type: "string",
    description: "Target BCP-47 language code for the translation, for example en, fa, or es.",
  },
  lang: {
    type: "string",
    description: "Alias for language.",
  },
  messageId: {
    type: "string",
    description: "Inline message id to translate. Defaults to the current inbound message when available.",
  },
  messageIds: {
    oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }],
    description: "One or more Inline message ids to translate.",
  },
} as unknown as ChannelMessageToolSchemaContribution["properties"]

const inlineReadHistorySchemaProperties = {
  to: {
    type: "string",
    description: "Inline target (`chat:<id>`, bare chat id, or `user:<id>`). Defaults to the current thread/chat when available.",
  },
  target: {
    type: "string",
    description: "Alias for to.",
  },
  chatId: {
    type: "string",
    description: "Inline chat id.",
  },
  channelId: {
    type: "string",
    description: "Alias for chatId.",
  },
  userId: {
    type: "string",
    description: "Inline user id for direct-message history.",
  },
  threadId: {
    type: "string",
    description: "Inline reply-thread chat id to read.",
  },
  before: {
    type: "string",
    description: "Read older messages before this message id.",
  },
  after: {
    type: "string",
    description: "Read newer messages after this message id.",
  },
  messageId: {
    type: "string",
    description: "Read an around-window centered on this message id.",
  },
  anchorId: {
    type: "string",
    description: "Alias for messageId in around-window reads.",
  },
  beforeLimit: {
    type: "number",
    description: "Around-window older-message count. Defaults to server split.",
  },
  afterLimit: {
    type: "number",
    description: "Around-window newer-message count. Defaults to server split.",
  },
  includeAnchor: {
    type: "boolean",
    description: "Whether around-window reads include the anchor message. Defaults to true.",
  },
  limit: {
    type: "number",
    description: "Maximum messages to return, 1-100.",
  },
} as unknown as ChannelMessageToolSchemaContribution["properties"]

const inlineGetMessagesSchemaProperties = {
  to: {
    type: "string",
    description: "Inline target (`chat:<id>`, bare chat id, or `user:<id>`). Defaults to the current thread/chat when available.",
  },
  target: {
    type: "string",
    description: "Alias for to.",
  },
  chatId: {
    type: "string",
    description: "Inline chat id.",
  },
  channelId: {
    type: "string",
    description: "Alias for chatId.",
  },
  userId: {
    type: "string",
    description: "Inline user id for direct-message lookup.",
  },
  threadId: {
    type: "string",
    description: "Inline reply-thread chat id to fetch messages from.",
  },
  messageId: {
    type: "string",
    description: "Single Inline message id to fetch. Defaults to the current inbound message when available.",
  },
  messageIds: {
    oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }],
    description: "One or more Inline message ids to fetch from the target.",
  },
} as unknown as ChannelMessageToolSchemaContribution["properties"]

const inlineDownloadFileSchemaProperties = {
  to: {
    type: "string",
    description: "Inline target (`chat:<id>`, bare chat id, or `user:<id>`). Defaults to the current thread/chat when resolving by message.",
  },
  target: {
    type: "string",
    description: "Alias for to.",
  },
  chatId: {
    type: "string",
    description: "Inline chat id.",
  },
  channelId: {
    type: "string",
    description: "Alias for chatId.",
  },
  userId: {
    type: "string",
    description: "Inline user id for direct-message lookup.",
  },
  threadId: {
    type: "string",
    description: "Inline reply-thread chat id to fetch the source message from.",
  },
  messageId: {
    type: "string",
    description: "Inline message id whose media/preview image should be downloaded. Defaults to the current inbound message when available.",
  },
  mediaId: {
    type: "string",
    description: "Optional media.id selector from read/search/get-messages results.",
  },
  attachmentId: {
    type: "string",
    description: "Optional attachments[].id or URL preview id selector from read/search/get-messages results.",
  },
  mediaUrl: {
    type: "string",
    description: "Direct media URL or local file path to download/copy without fetching a message first.",
  },
  fileUrl: {
    type: "string",
    description: "Alias for mediaUrl.",
  },
  url: {
    type: "string",
    description: "Alias for mediaUrl.",
  },
  fileName: {
    type: "string",
    description: "Optional output filename hint.",
  },
} as unknown as ChannelMessageToolSchemaContribution["properties"]

const inlinePeerBotCommandsSchemaProperties = {
  to: {
    type: "string",
    description: "Inline target (`chat:<id>`, bare chat id, or `user:<id>`). Defaults to the current thread/chat when available.",
  },
  target: {
    type: "string",
    description: "Alias for to.",
  },
  chatId: {
    type: "string",
    description: "Inline chat id.",
  },
  channelId: {
    type: "string",
    description: "Alias for chatId.",
  },
  userId: {
    type: "string",
    description: "Inline user id for direct-message command discovery.",
  },
  threadId: {
    type: "string",
    description: "Inline reply-thread chat id to inspect for inherited bot commands.",
  },
} as unknown as ChannelMessageToolSchemaContribution["properties"]

const inlineDeleteAttachmentSchemaProperties = {
  messageId: {
    type: "string",
    description: "Inline message id containing the attachment.",
  },
  attachmentId: {
    type: "string",
    description: "Stable MessageAttachment.id from read/search results at attachments[].id.",
  },
} as unknown as ChannelMessageToolSchemaContribution["properties"]

const inlinePinMessageSchemaProperties = {
  to: {
    type: "string",
    description: "Inline target (`chat:<id>`, bare chat id, or `user:<id>`). Defaults to the current thread/chat when available.",
  },
  target: {
    type: "string",
    description: "Alias for to.",
  },
  chatId: {
    type: "string",
    description: "Inline chat id.",
  },
  channelId: {
    type: "string",
    description: "Alias for chatId.",
  },
  threadId: {
    type: "string",
    description: "Inline reply-thread chat id to pin/unpin in.",
  },
  messageId: {
    type: "string",
    description: "Inline message id to pin or unpin. Defaults to the current inbound message when available.",
  },
} as unknown as ChannelMessageToolSchemaContribution["properties"]

const inlineListPinsSchemaProperties = {
  to: {
    type: "string",
    description: "Inline target (`chat:<id>`, bare chat id, or `user:<id>`). Defaults to the current thread/chat when available.",
  },
  target: {
    type: "string",
    description: "Alias for to.",
  },
  chatId: {
    type: "string",
    description: "Inline chat id.",
  },
  channelId: {
    type: "string",
    description: "Alias for chatId.",
  },
  threadId: {
    type: "string",
    description: "Inline reply-thread chat id to list pins from.",
  },
} as unknown as ChannelMessageToolSchemaContribution["properties"]

const inlineForwardMessagesSchemaProperties = {
  to: {
    type: "string",
    description: "Destination Inline target (`chat:<id>`, bare chat id, or `user:<id>`).",
  },
  target: {
    type: "string",
    description: "Alias for to.",
  },
  chatId: {
    type: "string",
    description: "Destination chat id alias.",
  },
  channelId: {
    type: "string",
    description: "Destination chat id alias.",
  },
  userId: {
    type: "string",
    description: "Destination user id alias.",
  },
  toUserId: {
    type: "string",
    description: "Explicit destination user id.",
  },
  from: {
    type: "string",
    description: "Source Inline target. Defaults to the current Inline chat when available.",
  },
  source: {
    type: "string",
    description: "Alias for from.",
  },
  fromChatId: {
    type: "string",
    description: "Source chat id alias.",
  },
  sourceChatId: {
    type: "string",
    description: "Alias for fromChatId.",
  },
  fromUserId: {
    type: "string",
    description: "Explicit source user id.",
  },
  sourceUserId: {
    type: "string",
    description: "Alias for fromUserId.",
  },
  messageId: {
    type: "string",
    description: "Single source message id. Defaults to the current inbound message when available.",
  },
  messageIds: {
    oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }],
    description: "One or more source message ids to forward.",
  },
  shareForwardHeader: {
    type: "boolean",
    description: "Whether to include the original forward header. Defaults to true.",
  },
  includeForwardHeader: {
    type: "boolean",
    description: "Alias for shareForwardHeader.",
  },
} as unknown as ChannelMessageToolSchemaContribution["properties"]

const inlineUploadFileSchemaProperties = {
  to: {
    type: "string",
    description: "Destination Inline target (`chat:<id>`, bare chat id, or `user:<id>`).",
  },
  chatId: {
    type: "string",
    description: "Destination chat id alias.",
  },
  channelId: {
    type: "string",
    description: "Destination chat id alias.",
  },
  userId: {
    type: "string",
    description: "Destination user id alias.",
  },
  filePath: {
    type: "string",
    description: "Local file path to upload.",
  },
  path: {
    type: "string",
    description: "Alias for filePath.",
  },
  media: {
    type: "string",
    description: "Media URL or local file path to upload.",
  },
  mediaUrl: {
    type: "string",
    description: "Remote media URL or local file path to upload.",
  },
  url: {
    type: "string",
    description: "Alias for mediaUrl.",
  },
  message: {
    type: "string",
    description: "Optional message text sent as the first attachment caption.",
  },
  caption: {
    type: "string",
    description: "Optional first attachment caption.",
  },
  replyTo: {
    type: "string",
    description: "Optional Inline message id to reply to.",
  },
  messageId: {
    type: "string",
    description: "Alias for replyTo when uploading as a reply.",
  },
} as unknown as ChannelMessageToolSchemaContribution["properties"]

const inlineComposeActionSchemaProperties = {
  to: {
    type: "string",
    description: "Inline target (`chat:<id>`, bare chat id, or `user:<id>`). Defaults to the current chat when available.",
  },
  target: {
    type: "string",
    description: "Alias for to.",
  },
  chatId: {
    type: "string",
    description: "Inline chat id.",
  },
  channelId: {
    type: "string",
    description: "Alias for chatId.",
  },
  userId: {
    type: "string",
    description: "Inline user id for a direct-message compose action.",
  },
  composeAction: {
    type: "string",
    enum: [
      "typing",
      "stop-typing",
      "none",
      "uploading-photo",
      "uploading-document",
      "uploading-video",
      "recording-voice",
    ],
    description: "Compose state for the generic compose-action action.",
  },
  state: {
    type: "string",
    description: "Alias for composeAction.",
  },
} as unknown as ChannelMessageToolSchemaContribution["properties"]

const inlineChannelEditSchemaProperties = {
  emoji: {
    type: "string",
    description: "Optional thread emoji/icon.",
  },
  isPublic: {
    type: "boolean",
    description: "Set space-thread visibility. Public threads must not include participants.",
  },
  visibility: {
    type: "string",
    enum: ["public", "private"],
    description: "Alias for isPublic.",
  },
  participant: {
    type: "string",
    description: "User id, @username, or comma-separated users required when making a space thread private.",
  },
  participants: {
    oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }],
    description: "Users required when making a space thread private.",
  },
} as unknown as ChannelMessageToolSchemaContribution["properties"]

const inlineInviteToSpaceSchemaProperties = {
  spaceId: {
    type: "string",
    description: "Inline space id to invite into. Can also be inferred from a space chat target.",
  },
  space: {
    type: "string",
    description: "Alias for spaceId.",
  },
  userId: {
    type: "string",
    description: "Inline user id to invite.",
  },
  user: {
    type: "string",
    description: "Inline user id, @username, or display name to invite.",
  },
  participant: {
    type: "string",
    description: "Alias for user when inviting an existing Inline user to a space.",
  },
  email: {
    type: "string",
    description: "Email address to invite to the space.",
  },
  phoneNumber: {
    type: "string",
    description: "Phone number to invite to the space.",
  },
  phone: {
    type: "string",
    description: "Alias for phoneNumber.",
  },
  role: {
    type: "string",
    enum: ["member", "admin"],
    description: "Space role for the invited user. Defaults to member.",
  },
  canAccessPublicChats: {
    type: "boolean",
    description: "For member invites, whether the member can access public space chats. Defaults to true.",
  },
} as unknown as ChannelMessageToolSchemaContribution["properties"]

type InlineReplyMarkupButton =
  | {
      text: string
      kind: "callback"
      callbackData: string
    }
  | {
      text: string
      kind: "copyText"
      copyText: string
    }

const inlineMessageButtonsSchema = {
  type: "array",
  description:
    "Inline button rows. Use `callback_data` for callbacks, or `copy_text`/`copyText` for client-side copy buttons. JSON callback_data may include callbackToast/toast for the immediate press acknowledgement.",
  items: {
    type: "array",
    items: {
      type: "object",
      additionalProperties: false,
      properties: {
        text: {
          type: "string",
          description: "Button label.",
        },
        callback_data: {
          type: "string",
          description: "Callback payload sent back to the bot when pressed.",
        },
        copy_text: {
          type: "string",
          description: "Text copied client-side when pressed.",
        },
        copyText: {
          type: "string",
          description: "Alias for `copy_text`.",
        },
        style: {
          type: "string",
          enum: ["danger", "success", "primary"],
          description: "Optional visual style hint.",
        },
      },
      required: ["text"],
    },
  },
} as const

function suppressedInternalTextResult() {
  return jsonResult({
    ok: false,
    reason: "suppressed_internal_context",
    hint: "Inline suppressed OpenClaw internal runtime or heartbeat text before delivery. Do not retry this text.",
  })
}

function sanitizeVisibleActionText(raw: string | null | undefined) {
  const visible = sanitizeInlineVisibleText(raw)
  if (visible.shouldSkip) {
    return visible
  }
  return {
    ...visible,
    text: sanitizeInlineOutgoingText(visible.text),
  }
}

function requireVisibleActionText(raw: string | undefined, label: string): string {
  const visible = sanitizeVisibleActionText(raw)
  if (visible.shouldSkip) {
    throw new Error(`inline action: ${label} contains internal runtime text`)
  }
  const text = visible.text.trim()
  if (!text) {
    throw new Error(`inline action: ${label} is required`)
  }
  return text
}

function optionalVisibleActionText(raw: string | undefined, label: string): string | undefined {
  if (raw === undefined) return undefined
  const visible = sanitizeVisibleActionText(raw)
  if (visible.shouldSkip) {
    throw new Error(`inline action: ${label} contains internal runtime text`)
  }
  return visible.text.trim() || undefined
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null
}

function normalizeOptionalString(raw: unknown): string | undefined {
  return typeof raw === "string" && raw.trim() ? raw.trim() : undefined
}

function resolveInlineActionAgentId(params: {
  args: Record<string, unknown>
  toolContext?: Record<string, unknown> | null | undefined
}): string | undefined {
  return (
    normalizeOptionalString(params.args.__agentId) ??
    normalizeOptionalString(params.args.agentId) ??
    normalizeOptionalString(params.toolContext?.agentId) ??
    normalizeOptionalString(params.toolContext?.currentAgentId)
  )
}

function normalizeReplyMarkupButtons(raw: unknown): InlineReplyMarkupButton[][] {
  if (!Array.isArray(raw)) return []
  const rows: InlineReplyMarkupButton[][] = []
  for (const candidateRow of raw) {
    if (!Array.isArray(candidateRow)) continue
    const row: InlineReplyMarkupButton[] = []
    for (const candidateButton of candidateRow) {
      if (!isRecord(candidateButton)) continue
      const text = sanitizeInlineActionLabel(
        typeof candidateButton.text === "string" ? candidateButton.text : "",
      )
      const callbackData = sanitizeInlineActionCallbackData(
        typeof candidateButton.callback_data === "string" ? candidateButton.callback_data : "",
      )
      const copyText = sanitizeInlineActionCopyText(
        typeof candidateButton.copy_text === "string"
          ? candidateButton.copy_text
          : typeof candidateButton.copyText === "string"
            ? candidateButton.copyText
            : "",
      )
      if (!text) continue
      if (callbackData) {
        row.push({ text, kind: "callback", callbackData })
      } else if (copyText) {
        row.push({ text, kind: "copyText", copyText })
      }
      if (row.length >= INLINE_ACTION_MAX_PER_ROW) break
    }
    if (row.length === 0) continue
    rows.push(row)
    if (rows.length >= INLINE_ACTION_MAX_ROWS) break
  }
  return rows
}

function chunkInteractiveButtons(
  buttons: readonly InteractiveReplyButton[],
  rows: InlineReplyMarkupButton[][],
) {
  for (let i = 0; i < buttons.length; i += INLINE_ACTION_MAX_PER_ROW) {
    const row: InlineReplyMarkupButton[] = []
    for (const button of buttons.slice(i, i + INLINE_ACTION_MAX_PER_ROW)) {
      const text = sanitizeInlineActionLabel(button.label)
      const callbackData = sanitizeInlineActionCallbackData(button.value)
      if (!text || !callbackData) continue
      row.push({ text, kind: "callback", callbackData })
    }

    if (row.length === 0) continue
    rows.push(row)
    if (rows.length >= INLINE_ACTION_MAX_ROWS) return
  }
}

function resolveInlineInteractiveButtonsParam(
  params: Record<string, unknown>,
): InlineReplyMarkupButton[][] | undefined {
  if (!Object.prototype.hasOwnProperty.call(params, "interactive")) {
    return undefined
  }

  let rawInteractive = params.interactive
  if (typeof rawInteractive === "string") {
    const trimmed = rawInteractive.trim()
    if (!trimmed) {
      return undefined
    }
    try {
      rawInteractive = JSON.parse(trimmed) as unknown
    } catch {
      throw new Error("inline action: interactive must be valid JSON")
    }
  }

  const interactive = normalizeInteractiveReply(rawInteractive)
  if (!interactive) {
    return undefined
  }

  const rows = reduceInteractiveReply(interactive, [] as InlineReplyMarkupButton[][], (state, block) => {
    if (state.length >= INLINE_ACTION_MAX_ROWS) {
      return state
    }
    if (block.type === "buttons") {
      chunkInteractiveButtons(block.buttons, state)
      return state
    }
    if (block.type === "select") {
      chunkInteractiveButtons(
        block.options.map((option) => ({ label: option.label, value: option.value })),
        state,
      )
    }
    return state
  })
  return rows.length > 0 ? rows : undefined
}

function toInlineMessageActions(rows: InlineReplyMarkupButton[][]): MessageActions {
  return {
    rows: rows.map((row, rowIndex) => ({
      actions: row.map((button, buttonIndex) => ({
        actionId: `btn_${rowIndex + 1}_${buttonIndex + 1}`,
        text: button.text,
        action:
          button.kind === "callback"
            ? {
                oneofKind: "callback" as const,
                callback: {
                  data: new TextEncoder().encode(button.callbackData),
                },
              }
            : {
                oneofKind: "copyText" as const,
                copyText: {
                  text: button.copyText,
                },
              },
      })),
    })),
  }
}

export function resolveInlineMessageActionsParam(params: Record<string, unknown>): MessageActions | undefined {
  if (!Object.prototype.hasOwnProperty.call(params, "buttons")) {
    const interactiveRows = resolveInlineInteractiveButtonsParam(params)
    return interactiveRows ? toInlineMessageActions(interactiveRows) : undefined
  }

  let rawButtons: unknown = params.buttons
  if (typeof rawButtons === "string") {
    const trimmed = rawButtons.trim()
    if (!trimmed) {
      rawButtons = []
    } else {
      try {
        rawButtons = JSON.parse(trimmed) as unknown
      } catch {
        throw new Error("inline action: buttons must be valid JSON")
      }
    }
  }
  if (rawButtons == null) {
    rawButtons = []
  }
  if (!Array.isArray(rawButtons)) {
    throw new Error("inline action: buttons must be an array of button rows")
  }

  const rows = normalizeReplyMarkupButtons(rawButtons)
  return toInlineMessageActions(rows)
}

function normalizeChatId(raw: string): string {
  const normalized = normalizeInlineTarget(raw) ?? raw.trim()
  if (!/^[0-9]+$/.test(normalized)) {
    throw new Error(`inline action: invalid chat target "${raw}" (expected numeric chat id)`)
  }
  return normalized
}

function readFlexibleId(params: Record<string, unknown>, key: string): string | undefined {
  const direct = params[key]
  if (typeof direct === "bigint") return direct.toString()
  if (typeof direct === "number") {
    if (!Number.isFinite(direct) || !Number.isInteger(direct)) return undefined
    return String(direct)
  }
  if (typeof direct === "string") {
    const trimmed = direct.trim()
    return trimmed || undefined
  }
  return undefined
}

const OPTIONAL_ID_PLACEHOLDERS = new Set([
  "x",
  "n/a",
  "na",
  "none",
  "null",
  "undefined",
  "unknown",
  "-",
])

function normalizeOptionalInlineId(raw: string | undefined): string | undefined {
  const trimmed = raw?.trim()
  if (!trimmed) return undefined
  if (OPTIONAL_ID_PLACEHOLDERS.has(trimmed.toLowerCase())) return undefined
  return trimmed
}

function readOptionalInlineIdParam(
  params: Record<string, unknown>,
  keys: string[],
): string | undefined {
  for (const key of keys) {
    const value = normalizeOptionalInlineId(
      readFlexibleId(params, key) ?? readStringParam(params, key),
    )
    if (value) return value
  }
  return undefined
}

function readBooleanParam(params: Record<string, unknown>, key: string): boolean | undefined {
  const value = params[key]
  if (typeof value === "boolean") return value
  if (typeof value === "string") {
    const trimmed = value.trim().toLowerCase()
    if (trimmed === "true") return true
    if (trimmed === "false") return false
  }
  return undefined
}

function resolveInlineVisibilityParam(params: Record<string, unknown>): boolean | undefined {
  const direct = readBooleanParam(params, "isPublic") ?? readBooleanParam(params, "public")
  if (direct !== undefined) return direct

  const raw = readStringParam(params, "visibility") ?? readStringParam(params, "privacy")
  if (raw === undefined) return undefined
  const value = raw.trim().toLowerCase()
  if (value === "public" || value === "open") return true
  if (value === "private" || value === "closed") return false
  throw new Error("inline action: visibility must be \"public\" or \"private\"")
}

function parseInlineId(raw: unknown, label: string): bigint {
  if (typeof raw === "bigint") {
    if (raw < 0n) {
      throw new Error(`inline action: invalid ${label} "${raw.toString()}"`)
    }
    return raw
  }
  if (typeof raw === "number") {
    if (!Number.isFinite(raw) || !Number.isInteger(raw) || raw < 0) {
      throw new Error(`inline action: invalid ${label} "${String(raw)}"`)
    }
    return BigInt(raw)
  }
  if (typeof raw === "string") {
    const trimmed = raw.trim()
    if (!trimmed) {
      throw new Error(`inline action: missing ${label}`)
    }
    if (!/^[0-9]+$/.test(trimmed)) {
      if (/message/i.test(label)) {
        const prefixed = trimmed.match(/^(?:message|msg)\s*#?\s*([0-9]+)$/i)?.[1]
        if (prefixed) {
          return BigInt(prefixed)
        }
      }
      throw new Error(`inline action: invalid ${label} "${raw}"`)
    }
    return BigInt(trimmed)
  }
  throw new Error(`inline action: missing ${label}`)
}

function resolveMessageIdFromParamsOrContext(params: {
  args: Record<string, unknown>
  toolContext?: { currentMessageId?: string | number | null }
}): string | undefined {
  const explicit =
    readFlexibleId(params.args, "messageId") ??
    readStringParam(params.args, "messageId")
  if (explicit) {
    return explicit
  }
  const fromContext = params.toolContext?.currentMessageId
  if (typeof fromContext === "number" && Number.isFinite(fromContext)) {
    return String(Math.trunc(fromContext))
  }
  if (typeof fromContext === "string") {
    const trimmed = fromContext.trim()
    return trimmed || undefined
  }
  return undefined
}

function resolveThreadParentMessageIdFromArgs(args: Record<string, unknown>): string | undefined {
  return readOptionalInlineIdParam(args, [
    "parentMessageId",
    "messageId",
    "replyTo",
    "replyToId",
  ])
}

function resolveThreadParentMessageId(params: {
  args: Record<string, unknown>
  toolContext?: { currentMessageId?: string | number | null | undefined }
}): string | undefined {
  const explicit = resolveThreadParentMessageIdFromArgs(params.args)
  if (explicit) return explicit

  const fromContext = params.toolContext?.currentMessageId
  if (typeof fromContext === "number" && Number.isFinite(fromContext)) {
    return String(Math.trunc(fromContext))
  }
  if (typeof fromContext === "string") {
    const trimmed = fromContext.trim()
    return trimmed || undefined
  }
  return undefined
}

function resolveThreadReplyRouteParentMessageHint(params: {
  args: Record<string, unknown>
  toolContext?: { currentMessageId?: string | number | null | undefined }
}): { value?: string; source: "explicit" | "context" | "none" } {
  const explicit =
    readFlexibleId(params.args, "parentMessageId") ??
    readFlexibleId(params.args, "threadParentMessageId") ??
    readFlexibleId(params.args, "anchorMessageId") ??
    readStringParam(params.args, "parentMessageId") ??
    readStringParam(params.args, "threadParentMessageId") ??
    readStringParam(params.args, "anchorMessageId")
  if (explicit) return { value: explicit, source: "explicit" }

  const fromContext = params.toolContext?.currentMessageId
  if (typeof fromContext === "number" && Number.isFinite(fromContext)) {
    return { value: String(Math.trunc(fromContext)), source: "context" }
  }
  if (typeof fromContext === "string") {
    const trimmed = fromContext.trim()
    return trimmed ? { value: trimmed, source: "context" } : { source: "none" }
  }
  return { source: "none" }
}

function parseOptionalInlineId(raw: unknown, label: string): bigint | undefined {
  if (raw == null) return undefined
  return parseInlineId(raw, label)
}

function parseInlineIdList(raw: unknown, label: string): bigint[] {
  if (raw == null) return []
  if (Array.isArray(raw)) {
    return raw.map((item) => parseInlineId(item, label))
  }
  if (typeof raw === "string") {
    const trimmed = raw.trim()
    if (!trimmed) return []
    const chunks = trimmed
      .split(",")
      .map((item) => item.trim())
      .filter(Boolean)
    if (chunks.length <= 1) {
      return [parseInlineId(trimmed, label)]
    }
    return chunks.map((item) => parseInlineId(item, label))
  }
  return [parseInlineId(raw, label)]
}

function parseInlineIdListFromParams(params: Record<string, unknown>, key: string): bigint[] {
  const direct = params[key]
  if (direct != null) {
    return parseInlineIdList(direct, key)
  }
  return []
}

function parseInlineListValue(raw: unknown, label: string): string[] {
  if (raw == null) return []
  if (Array.isArray(raw)) {
    return raw.flatMap((entry) => parseInlineListValue(entry, label))
  }
  if (typeof raw === "bigint") return [raw.toString()]
  if (typeof raw === "number") {
    if (!Number.isFinite(raw) || !Number.isInteger(raw) || raw < 0) {
      throw new Error(`inline action: invalid ${label} "${String(raw)}"`)
    }
    return [String(raw)]
  }
  if (typeof raw === "string") {
    const trimmed = raw.trim()
    if (!trimmed) return []
    return trimmed
      .split(",")
      .map((entry) => entry.trim())
      .filter(Boolean)
  }
  throw new Error(`inline action: invalid ${label}`)
}

function parseInlineListValuesFromParams(params: Record<string, unknown>, keys: string[]): string[] {
  const entries = keys.flatMap((key) => parseInlineListValue(params[key], key))
  return Array.from(new Set(entries.map((entry) => entry.trim()).filter(Boolean)))
}

function resolveInlineOutboundMediaInputs(params: Record<string, unknown>): string[] {
  const plural = parseInlineListValuesFromParams(params, [
    "mediaUrls",
    "attachmentUrls",
    "filePaths",
    "paths",
    "files",
  ])
  const single = parseInlineListValuesFromParams(params, [
    "mediaUrl",
    "attachmentUrl",
    "url",
    "media",
    "filePath",
    "path",
    "file",
  ])
  return Array.from(new Set([...plural, ...single]))
}

function resolveInlineDownloadMediaUrl(params: Record<string, unknown>): string | undefined {
  return parseInlineListValuesFromParams(params, [
    "mediaUrl",
    "fileUrl",
    "url",
    "media",
    "file",
    "filePath",
    "path",
    "attachmentUrl",
    "mediaUrls",
  ])[0]
}

function normalizeInlineUserLookupToken(raw: string): string {
  return raw
    .trim()
    .replace(/^inline:/i, "")
    .replace(/^user:/i, "")
    .replace(/^@/, "")
    .trim()
}

function parseInlineIdIfNumericToken(raw: string): bigint | undefined {
  const normalized = normalizeInlineUserLookupToken(raw)
  if (!/^[0-9]+$/.test(normalized)) return undefined
  return BigInt(normalized)
}

function buildInlineUserHaystack(user: User): string {
  return [
    String(user.id),
    buildInlineUserDisplayName(user),
    user.firstName ?? "",
    user.lastName ?? "",
    user.username ?? "",
  ]
    .join("\n")
    .toLowerCase()
}

function resolveInlineUsersByToken(params: { users: User[]; token: string }): User[] {
  const normalized = normalizeInlineUserLookupToken(params.token)
  if (!normalized) return []
  const lowered = normalized.toLowerCase()

  const numericId = parseInlineIdIfNumericToken(normalized)
  if (numericId != null) {
    return params.users.filter((user) => user.id === numericId)
  }

  const byUsername = params.users.filter((user) => (user.username ?? "").trim().toLowerCase() === lowered)
  if (byUsername.length > 0) {
    return byUsername
  }

  const byExactName = params.users.filter(
    (user) => buildInlineUserDisplayName(user).trim().toLowerCase() === lowered,
  )
  if (byExactName.length > 0) {
    return byExactName
  }

  return params.users.filter((user) => buildInlineUserHaystack(user).includes(lowered))
}

async function fetchInlineUsersForResolution(client: InlineSdkClient): Promise<User[]> {
  const result = await client.invokeRaw(Method.GET_CHATS, {
    oneofKind: "getChats",
    getChats: {},
  })
  if (result.oneofKind !== "getChats") {
    throw new Error(`inline action: expected getChats result, got ${String(result.oneofKind)}`)
  }
  return result.getChats.users ?? []
}

async function resolveInlineUserIdsFromParams(params: {
  client: InlineSdkClient
  values: string[]
  label: string
}): Promise<bigint[]> {
  if (params.values.length === 0) return []

  const resolved: bigint[] = []
  const unresolved: string[] = []
  for (const value of params.values) {
    const numericId = parseInlineIdIfNumericToken(value)
    if (numericId != null) {
      resolved.push(numericId)
      continue
    }
    unresolved.push(value)
  }

  if (unresolved.length > 0) {
    const users = await fetchInlineUsersForResolution(params.client)
    for (const token of unresolved) {
      const matches = resolveInlineUsersByToken({ users, token })
      if (matches.length === 0) {
        throw new Error(`inline action: could not resolve ${params.label} "${token}"`)
      }
      if (matches.length > 1) {
        throw new Error(`inline action: ambiguous ${params.label} "${token}"`)
      }
      const match = matches[0]
      if (!match) {
        throw new Error(`inline action: could not resolve ${params.label} "${token}"`)
      }
      resolved.push(match.id)
    }
  }

  return Array.from(new Set(resolved.map((id) => id.toString()))).map((id) => BigInt(id))
}

function resolveChatIdFromParams(params: Record<string, unknown>): bigint {
  const raw =
    readFlexibleId(params, "chatId") ??
    readFlexibleId(params, "channelId") ??
    readFlexibleId(params, "to") ??
    readStringParam(params, "to")
  if (!raw) {
    throw new Error("inline action requires chatId/channelId/to")
  }
  return BigInt(normalizeChatId(raw))
}

function resolveOptionalChatIdFromParams(params: Record<string, unknown>): bigint | undefined {
  const raw =
    readFlexibleId(params, "chatId") ??
    readFlexibleId(params, "channelId") ??
    readFlexibleId(params, "to") ??
    readStringParam(params, "to")
  if (!raw) return undefined
  return BigInt(normalizeChatId(raw))
}

function resolveInlineCurrentChatTarget(params: {
  args: Record<string, unknown>
  toolContext: {
    currentChannelId?: string | number | null | undefined
    currentThreadTs?: string | number | null | undefined
  } | undefined
  label: string
}): {
  chatId: bigint
  usedCurrentChatDefault: boolean
  usedCurrentThreadDefault: boolean
} {
  const rawThreadId =
    readFlexibleId(params.args, "threadId") ??
    readStringParam(params.args, "threadId")
  if (rawThreadId) {
    return {
      chatId: parseInlineId(rawThreadId, "threadId"),
      usedCurrentChatDefault: false,
      usedCurrentThreadDefault: false,
    }
  }

  const explicit = resolveOptionalChatIdFromParams(params.args)
  if (explicit != null) {
    return {
      chatId: explicit,
      usedCurrentChatDefault: false,
      usedCurrentThreadDefault: false,
    }
  }

  const threadFallback = safeToolContextThreadChatId(params.toolContext)
  if (threadFallback != null) {
    return {
      chatId: threadFallback,
      usedCurrentChatDefault: false,
      usedCurrentThreadDefault: true,
    }
  }

  const chatFallback = resolveToolContextChatId(params.toolContext)
  if (chatFallback != null) {
    return {
      chatId: chatFallback,
      usedCurrentChatDefault: true,
      usedCurrentThreadDefault: false,
    }
  }

  throw new Error(`${params.label} requires chatId/channelId/to outside an Inline chat context`)
}

function resolveToolContextChatId(
  toolContext: { currentChannelId?: string | number | null | undefined } | undefined,
): bigint | undefined {
  const fromContext = toolContext?.currentChannelId
  if (typeof fromContext === "number" && Number.isFinite(fromContext) && Number.isInteger(fromContext)) {
    return BigInt(fromContext)
  }
  if (typeof fromContext !== "string") return undefined
  const trimmed = fromContext.trim()
  if (!trimmed) return undefined
  try {
    return BigInt(normalizeChatId(trimmed))
  } catch {
    return undefined
  }
}

function resolveToolContextThreadId(
  toolContext: { currentThreadTs?: string | number | null | undefined } | undefined,
): string | undefined {
  const fromContext = toolContext?.currentThreadTs
  if (typeof fromContext === "number" && Number.isFinite(fromContext) && Number.isInteger(fromContext)) {
    return String(fromContext)
  }
  if (typeof fromContext !== "string") return undefined
  const trimmed = fromContext.trim()
  return trimmed || undefined
}

function resolveMessageSendTargetFromParams(params: Record<string, unknown>): {
  target: string
  chatId?: bigint
  userId?: bigint
} {
  const explicitUserIdRaw = readFlexibleId(params, "userId") ?? readStringParam(params, "userId")
  if (explicitUserIdRaw) {
    const userId = parseInlineId(explicitUserIdRaw, "userId")
    return {
      target: `user:${String(userId)}`,
      userId,
    }
  }

  const rawTarget = readFlexibleId(params, "to") ?? readStringParam(params, "to")
  if (rawTarget) {
    const normalized = normalizeInlineTarget(rawTarget) ?? rawTarget.trim()
    const userMatch = normalized.match(/^user:([0-9]+)$/i)
    if (userMatch?.[1]) {
      return {
        target: `user:${userMatch[1]}`,
        userId: BigInt(userMatch[1]),
      }
    }
    if (!/^[0-9]+$/.test(normalized)) {
      throw new Error(`inline action: invalid target "${rawTarget}"`)
    }
    return {
      target: normalized,
      chatId: BigInt(normalized),
    }
  }

  const rawChatId =
    readFlexibleId(params, "chatId") ??
    readStringParam(params, "chatId") ??
    readFlexibleId(params, "channelId") ??
    readStringParam(params, "channelId")
  if (!rawChatId) {
    throw new Error("inline action requires to/chatId/channelId/userId")
  }

  const normalized = normalizeInlineTarget(rawChatId) ?? rawChatId.trim()
  const userMatch = normalized.match(/^user:([0-9]+)$/i)
  if (userMatch?.[1]) {
    return {
      target: `user:${userMatch[1]}`,
      userId: BigInt(userMatch[1]),
    }
  }
  if (!/^[0-9]+$/.test(normalized)) {
    throw new Error(`inline action: invalid target "${rawChatId}"`)
  }
  return {
    target: normalized,
    chatId: BigInt(normalized),
  }
}

function buildChatPeer(chatId: bigint) {
  return {
    type: {
      oneofKind: "chat" as const,
      chat: { chatId },
    },
  }
}

function buildUserPeer(userId: bigint) {
  return {
    type: {
      oneofKind: "user" as const,
      user: { userId },
    },
  }
}

type InlineInputPeer = ReturnType<typeof buildChatPeer> | ReturnType<typeof buildUserPeer>

function resolveInlinePeerTarget(params: {
  label: string
  direct?: string | undefined
  chatId?: string | undefined
  userId?: string | undefined
  fallbackChatId?: bigint | undefined
}): { target: string; peerId: InlineInputPeer; usedFallback: boolean } {
  if (params.direct) {
    const normalized = normalizeInlineTarget(params.direct) ?? params.direct.trim()
    const userMatch = normalized.match(/^user:([0-9]+)$/i)
    if (userMatch?.[1]) {
      const userId = BigInt(userMatch[1])
      return {
        target: `user:${String(userId)}`,
        peerId: buildUserPeer(userId),
        usedFallback: false,
      }
    }
    if (!/^[0-9]+$/.test(normalized)) {
      throw new Error(`inline action: invalid ${params.label} "${params.direct}"`)
    }
    const chatId = BigInt(normalized)
    return {
      target: String(chatId),
      peerId: buildChatPeer(chatId),
      usedFallback: false,
    }
  }

  if (params.userId) {
    const userId = parseInlineId(params.userId, `${params.label} userId`)
    return {
      target: `user:${String(userId)}`,
      peerId: buildUserPeer(userId),
      usedFallback: false,
    }
  }

  if (params.chatId) {
    const chatId = BigInt(normalizeChatId(params.chatId))
    return {
      target: String(chatId),
      peerId: buildChatPeer(chatId),
      usedFallback: false,
    }
  }

  if (params.fallbackChatId != null) {
    return {
      target: String(params.fallbackChatId),
      peerId: buildChatPeer(params.fallbackChatId),
      usedFallback: true,
    }
  }

  throw new Error(`inline action: missing ${params.label}`)
}

function resolveInlineForwardDestinationPeer(params: Record<string, unknown>) {
  return resolveInlinePeerTarget({
    label: "forward destination target",
    direct:
      readFlexibleId(params, "to") ??
      readStringParam(params, "to") ??
      readFlexibleId(params, "target") ??
      readStringParam(params, "target") ??
      readFlexibleId(params, "destination") ??
      readStringParam(params, "destination"),
    chatId:
      readFlexibleId(params, "toChatId") ??
      readFlexibleId(params, "destinationChatId") ??
      readFlexibleId(params, "chatId") ??
      readFlexibleId(params, "channelId") ??
      readStringParam(params, "toChatId") ??
      readStringParam(params, "destinationChatId") ??
      readStringParam(params, "chatId") ??
      readStringParam(params, "channelId"),
    userId:
      readFlexibleId(params, "toUserId") ??
      readFlexibleId(params, "destinationUserId") ??
      readFlexibleId(params, "userId") ??
      readStringParam(params, "toUserId") ??
      readStringParam(params, "destinationUserId") ??
      readStringParam(params, "userId"),
  })
}

function resolveInlineForwardSourcePeer(
  params: Record<string, unknown>,
  toolContext?: { currentChannelId?: string | number | null | undefined },
) {
  return resolveInlinePeerTarget({
    label: "forward source target",
    direct:
      readFlexibleId(params, "from") ??
      readStringParam(params, "from") ??
      readFlexibleId(params, "source") ??
      readStringParam(params, "source"),
    chatId:
      readFlexibleId(params, "fromChatId") ??
      readFlexibleId(params, "sourceChatId") ??
      readFlexibleId(params, "fromChannelId") ??
      readFlexibleId(params, "sourceChannelId") ??
      readStringParam(params, "fromChatId") ??
      readStringParam(params, "sourceChatId") ??
      readStringParam(params, "fromChannelId") ??
      readStringParam(params, "sourceChannelId"),
    userId:
      readFlexibleId(params, "fromUserId") ??
      readFlexibleId(params, "sourceUserId") ??
      readStringParam(params, "fromUserId") ??
      readStringParam(params, "sourceUserId"),
    fallbackChatId: resolveToolContextChatId(toolContext),
  })
}

const INLINE_COMPOSE_ACTION_NAMES = new Set<InlineMessageActionName>([
  "compose-action",
  "typing",
  "stop-typing",
  "uploading-photo",
  "uploading-document",
  "uploading-video",
  "recording-voice",
])

const INLINE_COMPOSE_TARGET_ALIASES = [
  "to",
  "target",
  "chatId",
  "channelId",
  "userId",
  "composeAction",
  "state",
] as const

function isInlineComposeActionName(action: InlineMessageActionName): boolean {
  return INLINE_COMPOSE_ACTION_NAMES.has(action)
}

function normalizeInlineComposeActionToken(raw: string): string {
  return raw
    .trim()
    .replace(/([a-z0-9])([A-Z])/g, "$1-$2")
    .replace(/[_\s]+/g, "-")
    .toLowerCase()
}

function resolveInlineComposeAction(params: {
  action: InlineMessageActionName
  rawParams: Record<string, unknown>
}): { label: string; rpcAction: number } {
  const raw =
    params.action === "compose-action"
      ? readStringParam(params.rawParams, "composeAction") ??
        readStringParam(params.rawParams, "state") ??
        readStringParam(params.rawParams, "kind")
      : params.action
  const normalized = normalizeInlineComposeActionToken(raw ?? "")

  switch (normalized) {
    case "typing":
      return { label: "typing", rpcAction: COMPOSE_ACTION_TYPING }
    case "stop":
    case "stop-typing":
    case "none":
    case "clear":
    case "cancel":
      return { label: "none", rpcAction: COMPOSE_ACTION_NONE }
    case "uploading":
    case "uploading-document":
    case "uploading-file":
    case "uploading-attachment":
      return { label: "uploading-document", rpcAction: COMPOSE_ACTION_UPLOADING_DOCUMENT }
    case "uploading-photo":
    case "uploading-image":
      return { label: "uploading-photo", rpcAction: COMPOSE_ACTION_UPLOADING_PHOTO }
    case "uploading-video":
      return { label: "uploading-video", rpcAction: COMPOSE_ACTION_UPLOADING_VIDEO }
    case "recording-voice":
    case "recording-audio":
    case "voice":
      return { label: "recording-voice", rpcAction: COMPOSE_ACTION_RECORDING_VOICE }
    default:
      throw new Error(
        "inline action: composeAction must be typing, stop-typing, uploading-photo, uploading-document, uploading-video, or recording-voice",
      )
  }
}

function resolveInlineComposePeer(
  params: Record<string, unknown>,
  toolContext?: { currentChannelId?: string | number | null | undefined },
) {
  return resolveInlinePeerTarget({
    label: "compose target",
    direct:
      readFlexibleId(params, "to") ??
      readStringParam(params, "to") ??
      readFlexibleId(params, "target") ??
      readStringParam(params, "target"),
    chatId:
      readFlexibleId(params, "chatId") ??
      readFlexibleId(params, "channelId") ??
      readStringParam(params, "chatId") ??
      readStringParam(params, "channelId"),
    userId:
      readFlexibleId(params, "userId") ??
      readStringParam(params, "userId"),
    fallbackChatId: resolveToolContextChatId(toolContext),
  })
}

function resolveInlineForwardMessageIds(
  params: Record<string, unknown>,
  toolContext?: { currentMessageId?: string | number | null | undefined },
): bigint[] {
  const messageIds = [
    ...parseInlineIdListFromParams(params, "messageIds"),
    ...parseInlineIdListFromParams(params, "messages"),
    ...parseInlineIdListFromParams(params, "ids"),
  ]
  if (messageIds.length === 0) {
    const rawMessageId =
      readFlexibleId(params, "messageId") ??
      readStringParam(params, "messageId") ??
      (typeof toolContext?.currentMessageId === "number" && Number.isFinite(toolContext.currentMessageId)
        ? String(Math.trunc(toolContext.currentMessageId))
        : typeof toolContext?.currentMessageId === "string"
          ? toolContext.currentMessageId.trim() || undefined
          : undefined)
    messageIds.push(parseInlineId(rawMessageId, "messageId"))
  }
  return Array.from(new Set(messageIds.map((id) => id.toString()))).map((id) => BigInt(id))
}

function extractNewMessageIdsFromUpdates(updates: unknown): string[] {
  if (!Array.isArray(updates)) return []
  const ids: string[] = []
  for (const update of updates) {
    if (!isRecord(update)) continue
    const payload = update.update
    if (!isRecord(payload) || payload.oneofKind !== "newMessage") continue
    const newMessage = payload.newMessage
    if (!isRecord(newMessage)) continue
    const message = newMessage.message
    if (!isRecord(message)) continue
    const id = message.id
    if (typeof id === "bigint") {
      ids.push(id.toString())
    } else if (typeof id === "number" && Number.isFinite(id)) {
      ids.push(String(Math.trunc(id)))
    } else if (typeof id === "string" && id.trim()) {
      ids.push(id.trim())
    }
  }
  return Array.from(new Set(ids))
}

function mapMessage(message: {
  id: bigint
  fromId: bigint
  date: bigint
  message?: string
  out?: boolean
  replyToMsgId?: bigint
  media?: Message["media"]
  attachments?: Message["attachments"]
  entities?: Message["entities"]
  reactions?: {
    reactions?: Array<{
      emoji?: string
      userId: bigint
      messageId: bigint
      chatId: bigint
      date: bigint
    }>
  }
}) {
  const content = summarizeInlineMessageContent(message as Message)
  const reactions = (message.reactions?.reactions ?? []).map((reaction) => ({
    emoji: reaction.emoji ?? "",
    userId: String(reaction.userId),
    messageId: String(reaction.messageId),
    chatId: String(reaction.chatId),
    date: Number(reaction.date) * 1000,
  }))

  return {
    id: String(message.id),
    fromId: String(message.fromId),
    date: Number(message.date) * 1000,
    text: content.text,
    rawText: content.rawText,
    attachmentText: content.attachmentText,
    entityText: content.entityText,
    out: Boolean(message.out),
    replyToId: message.replyToMsgId != null ? String(message.replyToMsgId) : undefined,
    attachmentUrls: content.attachmentUrls,
    links: content.links,
    media: content.media,
    attachments: content.attachments,
    entities: content.entities,
    reactions,
  }
}

type InlineMappedMessage = ReturnType<typeof mapMessage>
type InlineDownloadSource = {
  url: string
  source: "media" | "attachment-preview"
  sourceId: string | null
  mediaId?: string | null
  attachmentId?: string | null
  fileName?: string | null
  contentType?: string | null
}

function normalizeDownloadSelector(raw: string | undefined): string | undefined {
  const trimmed = raw?.trim()
  return trimmed || undefined
}

function sameDownloadSelector(expected: string | undefined, actual: string | null | undefined): boolean {
  if (!expected) return true
  return actual === expected
}

function collectInlineDownloadSources(message: InlineMappedMessage): InlineDownloadSource[] {
  const sources: InlineDownloadSource[] = []
  if (message.media?.url) {
    sources.push({
      url: message.media.url,
      source: "media",
      sourceId: message.media.id,
      mediaId: message.media.id,
      ...(message.media.fileName !== undefined ? { fileName: message.media.fileName } : {}),
      ...(message.media.mimeType !== undefined ? { contentType: message.media.mimeType } : {}),
    })
  }

  for (const attachment of message.attachments) {
    if (attachment.kind !== "urlPreview" || !attachment.previewImageUrl) continue
    sources.push({
      url: attachment.previewImageUrl,
      source: "attachment-preview",
      sourceId: attachment.id ?? attachment.urlPreviewId,
      attachmentId: attachment.id ?? attachment.urlPreviewId,
    })
  }

  return sources
}

function selectInlineDownloadSource(params: {
  message: InlineMappedMessage
  mediaId?: string
  attachmentId?: string
}): InlineDownloadSource | null {
  const mediaId = normalizeDownloadSelector(params.mediaId)
  const attachmentId = normalizeDownloadSelector(params.attachmentId)
  for (const source of collectInlineDownloadSources(params.message)) {
    if (mediaId && !sameDownloadSelector(mediaId, source.mediaId)) continue
    if (attachmentId && !sameDownloadSelector(attachmentId, source.attachmentId)) continue
    return source
  }
  return null
}

function inlineDownloadFileResult(params: {
  target?: ReturnType<typeof resolveInlineReadTarget>
  message?: InlineMappedMessage | null
  messageId?: bigint | null
  source: InlineDownloadSource | { url: string; source: "explicit"; sourceId: null; fileName?: string | null; contentType?: string | null }
  downloaded: Awaited<ReturnType<typeof downloadInlineMediaFromUrl>>
}) {
  return jsonResult({
    ok: true,
    ...(params.target
      ? {
          target: params.target.target,
          chatId: params.target.chatId != null ? String(params.target.chatId) : null,
          threadId: params.target.threadId != null ? String(params.target.threadId) : null,
          usedCurrentChatDefault: params.target.usedCurrentChatDefault,
          usedCurrentThreadDefault: params.target.usedCurrentThreadDefault,
        }
      : {}),
    ...(params.messageId != null ? { messageId: String(params.messageId) } : {}),
    source: params.source.source,
    sourceId: params.source.sourceId,
    sourceUrl: params.source.url,
    path: params.downloaded.path,
    fileName: params.downloaded.fileName,
    sizeBytes: params.downloaded.sizeBytes,
    contentType: params.downloaded.contentType ?? params.source.contentType ?? null,
    media: {
      mediaUrl: params.downloaded.path,
      mediaUrls: [params.downloaded.path],
      trustedLocalMedia: true,
      contentType: params.downloaded.contentType ?? params.source.contentType ?? null,
    },
  })
}

function mapTranslation(translation: {
  messageId: bigint
  language?: string
  translation?: string
  date?: bigint
  entities?: unknown
  msgRev?: bigint
}) {
  return {
    messageId: String(translation.messageId),
    language: translation.language ?? "",
    text: translation.translation ?? "",
    date: translation.date != null ? Number(translation.date) * 1000 : null,
    entities: translation.entities,
    messageRevision: translation.msgRev != null ? String(translation.msgRev) : undefined,
  }
}

function mapChatEntry(params: {
  chat: Chat
  dialogByChatId: Map<string, Dialog>
  usersById: Map<string, User>
}) {
  const dialog = params.dialogByChatId.get(String(params.chat.id))
  const peer = params.chat.peerId?.type
  let peerUser: User | null = null
  if (peer?.oneofKind === "user") {
    peerUser = params.usersById.get(String(peer.user.userId)) ?? null
  }

  return {
    id: String(params.chat.id),
    target: `chat:${String(params.chat.id)}`,
    title: params.chat.title,
    spaceId: params.chat.spaceId != null ? String(params.chat.spaceId) : null,
    isPublic: params.chat.isPublic ?? false,
    createdBy: params.chat.createdBy != null ? String(params.chat.createdBy) : null,
    date: params.chat.date != null ? Number(params.chat.date) * 1000 : null,
    unreadCount: dialog?.unreadCount ?? 0,
    archived: Boolean(dialog?.archived),
    pinned: Boolean(dialog?.pinned),
    peer:
      peer?.oneofKind === "user"
        ? {
            kind: "user",
            id: String(peer.user.userId),
            target: `user:${String(peer.user.userId)}`,
            username: peerUser?.username ?? null,
            name: peerUser ? buildInlineUserDisplayName(peerUser) : null,
          }
        : peer?.oneofKind === "chat"
          ? { kind: "chat", id: String(peer.chat.chatId), target: `chat:${String(peer.chat.chatId)}` }
          : null,
  }
}

function normalizeInlineListQuery(query: string | undefined): string {
  return query?.trim().toLowerCase() ?? ""
}

function mapUserPeerEntry(user: User) {
  return {
    id: String(user.id),
    target: `user:${String(user.id)}`,
    username: user.username ?? null,
    name: buildInlineUserDisplayName(user),
    bot: user.bot ?? false,
  }
}

function mapPeerBotCommandGroup(group: {
  bot?: User
  commands?: Array<{
    command?: string
    description?: string
    sortOrder?: number
  }>
}) {
  const bot = group.bot ?? null
  const commands = (group.commands ?? []).map((command) => ({
    command: command.command ?? "",
    description: command.description ?? "",
    sortOrder: command.sortOrder ?? null,
  }))

  return {
    bot:
      bot != null
        ? {
            id: String(bot.id),
            target: `user:${String(bot.id)}`,
            username: bot.username ?? null,
            name: buildInlineUserDisplayName(bot),
          }
        : null,
    count: commands.length,
    commands,
  }
}

function matchesInlineListQuery(text: string, query: string): boolean {
  if (!query) return true
  return text.toLowerCase().includes(query)
}

async function loadMessageReactions(params: {
  client: InlineSdkClient
  chatId: bigint
  messageId: bigint
}): Promise<Array<{ emoji: string; count: number; userIds: string[] }>> {
  const target = await findMessageById({
    client: params.client,
    chatId: params.chatId,
    messageId: params.messageId,
  })
  if (!target) {
    return []
  }

  const byEmoji = new Map<string, { emoji: string; count: number; userIds: string[] }>()
  for (const reaction of target.reactions?.reactions ?? []) {
    const emoji = reaction.emoji ?? ""
    if (!emoji) continue
    const existing = byEmoji.get(emoji)
    if (existing) {
      existing.count += 1
      existing.userIds.push(String(reaction.userId))
      continue
    }
    byEmoji.set(emoji, {
      emoji,
      count: 1,
      userIds: [String(reaction.userId)],
    })
  }
  return Array.from(byEmoji.values())
}

function getErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message
  if (typeof error === "string") return error
  if (error && typeof error === "object" && "message" in error && typeof error.message === "string") {
    return error.message
  }
  return String(error)
}

type InlineThreadReplyTarget = {
  chatId: bigint
  resolvedBy: "threadId" | "current-thread" | "route"
  parentChatId?: bigint
  parentMessageId?: bigint | null
}

async function resolveInlineThreadReplyTarget(params: {
  accountId: string
  agentId?: string | undefined
  args: Record<string, unknown>
  toolContext?: {
    currentChannelId?: string | number | null | undefined
    currentThreadTs?: string | number | null | undefined
    currentMessageId?: string | number | null | undefined
  }
}): Promise<InlineThreadReplyTarget | null> {
  const rawThreadId =
    readFlexibleId(params.args, "threadId") ??
    readStringParam(params.args, "threadId")
  if (rawThreadId) {
    const chatId = parseInlineId(rawThreadId, "threadId")
    const route = await lookupInlineReplyThreadRouteByThreadId({
      accountId: params.accountId,
      threadId: chatId,
    })
    return {
      chatId,
      resolvedBy: "threadId",
      ...(route ? { parentChatId: parseInlineId(route.parentChatId, "parentChatId") } : {}),
      ...(route?.parentMessageId != null
        ? { parentMessageId: parseInlineId(route.parentMessageId, "parentMessageId") }
        : {}),
    }
  }

  const currentThreadId = resolveToolContextThreadId(params.toolContext)
  if (currentThreadId) {
    const chatId = parseInlineId(currentThreadId, "threadId")
    const route = await lookupInlineReplyThreadRouteByThreadId({
      accountId: params.accountId,
      threadId: chatId,
    })
    return {
      chatId,
      resolvedBy: "current-thread",
      ...(route ? { parentChatId: parseInlineId(route.parentChatId, "parentChatId") } : {}),
      ...(route?.parentMessageId != null
        ? { parentMessageId: parseInlineId(route.parentMessageId, "parentMessageId") }
        : {}),
    }
  }

  const parentChatId = resolveOptionalChatIdFromParams(params.args) ?? resolveToolContextChatId(params.toolContext)
  if (parentChatId == null) {
    return null
  }

  const parentMessageHint = resolveThreadReplyRouteParentMessageHint({
    args: params.args,
    ...(params.toolContext != null
      ? { toolContext: { currentMessageId: params.toolContext.currentMessageId } }
      : {}),
  })
  const parentMessageId = parseOptionalInlineId(parentMessageHint.value, "parentMessageId")
  const lookupRoute = async (routeParentMessageId?: bigint) =>
    await lookupInlineReplyThreadRoute({
      accountId: params.accountId,
      parentChatId,
      ...(routeParentMessageId != null ? { parentMessageId: routeParentMessageId } : {}),
      ...(params.agentId ? { agentId: params.agentId } : {}),
    }).catch((error) => {
      throw new Error(`inline thread-reply route lookup failed: ${getErrorMessage(error)}`)
    })

  let route = await lookupRoute(parentMessageId)
  let resolvedParentMessageId = parentMessageId ?? null
  if (!route && parentMessageId != null && parentMessageHint.source === "context") {
    route = await lookupRoute()
    resolvedParentMessageId = parseOptionalInlineId(route?.parentMessageId, "parentMessageId") ?? null
  }
  if (!route) {
    return null
  }

  return {
    chatId: parseInlineId(route.threadId, "threadId"),
    resolvedBy: "route",
    parentChatId,
    parentMessageId: resolvedParentMessageId,
  }
}

function isDuplicateReactionError(error: unknown): boolean {
  const text = getErrorMessage(error).toLowerCase()
  return (
    text.includes("unique_reaction_per_emoji") ||
    (text.includes("duplicate") && text.includes("reaction")) ||
    text.includes("duplicate key value violates unique constraint")
  )
}

async function reactionAlreadyExists(params: {
  client: InlineSdkClient
  chatId: bigint
  messageId: bigint
  emoji: string
}): Promise<boolean> {
  const me = await params.client.getMe().catch(() => null)
  if (!me?.userId) return false
  const myId = String(me.userId)
  const reactions = await loadMessageReactions(params).catch(() => [])
  return reactions.some((reaction) => reaction.emoji === params.emoji && reaction.userIds.includes(myId))
}

async function findMessageById(params: {
  client: InlineSdkClient
  chatId: bigint
  messageId: bigint
}): Promise<Message | null> {
  const directResult = await params.client
    .invokeRaw(GET_MESSAGES_METHOD, {
      oneofKind: "getMessages",
      getMessages: {
        peerId: buildChatPeer(params.chatId),
        messageIds: [params.messageId],
      },
    })
    .catch(() => null)
  if (directResult?.oneofKind === "getMessages") {
    return (directResult.getMessages.messages ?? []).find((message) => message.id === params.messageId) ?? null
  }

  const result = await params.client.invokeRaw(Method.GET_CHAT_HISTORY, {
    oneofKind: "getChatHistory",
    getChatHistory: {
      peerId: buildChatPeer(params.chatId),
      offsetId: params.messageId + 1n,
      limit: 8,
    },
  })
  if (result.oneofKind !== "getChatHistory") {
    throw new Error(`inline action: expected getChatHistory result, got ${String(result.oneofKind)}`)
  }
  return (result.getChatHistory.messages ?? []).find((message) => message.id === params.messageId) ?? null
}

async function withInlineClient<T>(params: {
  cfg: OpenClawConfig
  accountId: string | null | undefined
  fn: (client: InlineSdkClient, account: ReturnType<typeof resolveInlineAccount>) => Promise<T>
}): Promise<T> {
  const account = resolveInlineAccount({ cfg: params.cfg, accountId: params.accountId ?? null })
  if (!account.configured || !account.baseUrl) {
    throw new Error(`Inline not configured for account "${account.accountId}" (missing token or baseUrl)`)
  }
  const token = await resolveInlineToken(account)
  const client = new InlineSdkClient({
    baseUrl: account.baseUrl,
    token,
  })
  await client.connect()
  try {
    return await params.fn(client, account)
  } finally {
    await client.close().catch(() => {})
  }
}

function toJsonSafe(value: unknown): unknown {
  if (typeof value === "bigint") return value.toString()
  if (Array.isArray(value)) return value.map((item) => toJsonSafe(item))
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {}
    for (const [key, current] of Object.entries(value as Record<string, unknown>)) {
      out[key] = toJsonSafe(current)
    }
    return out
  }
  return value
}

function buildDialogMap(dialogs: Dialog[]): Map<string, Dialog> {
  const map = new Map<string, Dialog>()
  for (const dialog of dialogs) {
    const chatId = dialog.chatId
    if (chatId != null) {
      map.set(String(chatId), dialog)
      continue
    }
    const peer = dialog.peer?.type
    if (peer?.oneofKind === "chat") {
      map.set(String(peer.chat.chatId), dialog)
    }
  }
  return map
}

function buildUserMap(users: User[]): Map<string, User> {
  const map = new Map<string, User>()
  for (const user of users) {
    map.set(String(user.id), user)
  }
  return map
}

async function resolveSpaceIdFromParams(params: {
  client: InlineSdkClient
  action: string
  rawParams: Record<string, unknown>
}): Promise<bigint> {
  const directSpaceId = parseOptionalInlineId(
    readFlexibleId(params.rawParams, "spaceId") ??
      readFlexibleId(params.rawParams, "space") ??
      readStringParam(params.rawParams, "spaceId"),
    "spaceId",
  )
  if (directSpaceId != null) return directSpaceId

  const chatTarget =
    readFlexibleId(params.rawParams, "chatId") ??
    readFlexibleId(params.rawParams, "channelId") ??
    readFlexibleId(params.rawParams, "to") ??
    readStringParam(params.rawParams, "to")
  if (!chatTarget) {
    throw new Error(`inline action: ${params.action} requires spaceId (or a chat target in a space)`)
  }

  const chatId = BigInt(normalizeChatId(chatTarget))
  const chatResult = await params.client.invokeRaw(Method.GET_CHAT, {
    oneofKind: "getChat",
    getChat: { peerId: buildChatPeer(chatId) },
  })
  if (chatResult.oneofKind !== "getChat") {
    throw new Error(`inline action: expected getChat result, got ${String(chatResult.oneofKind)}`)
  }

  const inferredSpaceId = chatResult.getChat.chat?.spaceId ?? chatResult.getChat.dialog?.spaceId
  if (inferredSpaceId == null) {
    throw new Error(`inline action: ${params.action} requires a spaceId or a chat that belongs to a space`)
  }
  return inferredSpaceId
}

function listAllActions(): InlineMessageActionName[] {
  const out = new Set<InlineMessageActionName>()
  for (const group of ACTION_GROUPS) {
    for (const action of group.actions) {
      out.add(action)
    }
  }
  return Array.from(out)
}

function listEnabledInlineActions(
  cfg: OpenClawConfig,
  accountId?: string | null,
): InlineMessageActionName[] {
  const accountIds = accountId == null ? listInlineAccountIds(cfg) : [accountId]
  const gates = accountIds
    .map((id) => resolveInlineAccount({ cfg, accountId: id }))
    .filter((account) => account.enabled && account.configured)
    .map((account) =>
      createActionGate((account.config.actions ?? {}) as Record<string, boolean | undefined>),
    )
  if (gates.length === 0) return []

  const actions = new Set<InlineMessageActionName>()
  for (const group of ACTION_GROUPS) {
    if (!gates.some((gate) => gate(group.key, group.defaultEnabled))) continue
    for (const action of group.actions) {
      actions.add(action)
    }
  }
  return Array.from(actions)
}

export function supportsInlineMessageButtons(actions: readonly InlineMessageActionName[]): boolean {
  return actions.some((action) => action === "send" || action === "reply" || action === "thread-reply" || action === "edit")
}

function resolveInlineTranslateLanguage(params: Record<string, unknown>): string {
  const language =
    readStringParam(params, "language") ??
    readStringParam(params, "lang") ??
    readStringParam(params, "targetLanguage") ??
    readStringParam(params, "toLanguage")
  const trimmed = language?.trim()
  if (!trimmed) {
    throw new Error("inline action: translate requires language")
  }
  return trimmed
}

function resolveInlineTranslateMessageIds(
  params: Record<string, unknown>,
  toolContext?: { currentMessageId?: string | number | null | undefined },
): bigint[] {
  const messageIds = [
    ...parseInlineIdListFromParams(params, "messageIds"),
    ...parseInlineIdListFromParams(params, "messages"),
    ...parseInlineIdListFromParams(params, "ids"),
  ]
  if (messageIds.length === 0) {
    const rawMessageId =
      readFlexibleId(params, "messageId") ??
      readStringParam(params, "messageId") ??
      (typeof toolContext?.currentMessageId === "number" && Number.isFinite(toolContext.currentMessageId)
        ? String(Math.trunc(toolContext.currentMessageId))
        : typeof toolContext?.currentMessageId === "string"
          ? toolContext.currentMessageId.trim() || undefined
          : undefined)
    messageIds.push(parseInlineId(rawMessageId, "messageId"))
  }
  return Array.from(new Set(messageIds.map((id) => id.toString()))).map((id) => BigInt(id))
}

function resolveInlineGetMessageIds(
  params: Record<string, unknown>,
  toolContext?: { currentMessageId?: string | number | null | undefined },
): bigint[] {
  const messageIds = [
    ...parseInlineIdListFromParams(params, "messageIds"),
    ...parseInlineIdListFromParams(params, "messages"),
    ...parseInlineIdListFromParams(params, "ids"),
  ]
  if (messageIds.length === 0) {
    const rawMessageId =
      readFlexibleId(params, "messageId") ??
      readStringParam(params, "messageId") ??
      (typeof toolContext?.currentMessageId === "number" && Number.isFinite(toolContext.currentMessageId)
        ? String(Math.trunc(toolContext.currentMessageId))
        : typeof toolContext?.currentMessageId === "string"
          ? toolContext.currentMessageId.trim() || undefined
          : undefined)
    messageIds.push(parseInlineId(rawMessageId, "messageId"))
  }
  return Array.from(new Set(messageIds.map((id) => id.toString()))).map((id) => BigInt(id))
}

function clampInlineReadLimit(raw: number | undefined, fallback: number, min: number): number {
  const value = raw ?? fallback
  return Math.max(min, Math.min(100, value))
}

function resolveInlineHistoryMessageId(
  params: Record<string, unknown>,
  keys: string[],
  label: string,
): bigint | undefined {
  const raw = keys.reduce<string | undefined>((current, key) => {
    if (current) return current
    return readFlexibleId(params, key) ?? readStringParam(params, key)
  }, undefined)
  return parseOptionalInlineId(raw, label)
}

function safeToolContextThreadChatId(
  toolContext: { currentThreadTs?: string | number | null | undefined } | undefined,
): bigint | undefined {
  const raw = resolveToolContextThreadId(toolContext)
  if (!raw) return undefined
  try {
    return parseInlineId(raw, "threadId")
  } catch {
    return undefined
  }
}

function resolveInlineReadTarget(
  params: Record<string, unknown>,
  toolContext?: {
    currentChannelId?: string | number | null | undefined
    currentThreadTs?: string | number | null | undefined
  },
) {
  const rawThreadId =
    readFlexibleId(params, "threadId") ??
    readStringParam(params, "threadId")
  if (rawThreadId) {
    const threadId = parseInlineId(rawThreadId, "threadId")
    return {
      target: String(threadId),
      peerId: buildChatPeer(threadId),
      chatId: threadId,
      threadId,
      usedCurrentChatDefault: false,
      usedCurrentThreadDefault: false,
    }
  }

  const direct =
    readFlexibleId(params, "to") ??
    readStringParam(params, "to") ??
    readFlexibleId(params, "target") ??
    readStringParam(params, "target")
  const chatId =
    readFlexibleId(params, "chatId") ??
    readFlexibleId(params, "channelId") ??
    readStringParam(params, "chatId") ??
    readStringParam(params, "channelId")
  const userId =
    readFlexibleId(params, "userId") ??
    readStringParam(params, "userId")
  const threadFallback = safeToolContextThreadChatId(toolContext)
  const chatFallback = resolveToolContextChatId(toolContext)
  const target = resolveInlinePeerTarget({
    label: "read target",
    direct,
    chatId,
    userId,
    fallbackChatId: threadFallback ?? chatFallback,
  })
  const peer = target.peerId.type
  const resolvedChatId = peer.oneofKind === "chat" ? peer.chat.chatId : undefined
  return {
    ...target,
    chatId: resolvedChatId,
    threadId: target.usedFallback && threadFallback != null ? threadFallback : undefined,
    usedCurrentChatDefault: target.usedFallback && threadFallback == null,
    usedCurrentThreadDefault: target.usedFallback && threadFallback != null,
  }
}

function resolveInlineHistoryRequest(params: Record<string, unknown>): {
  mode: "latest" | "older" | "newer" | "around"
  input: {
    mode: number
    limit: number
    offsetId?: bigint
    beforeId?: bigint
    afterId?: bigint
    anchorId?: bigint
    beforeLimit?: number
    afterLimit?: number
    includeAnchor?: boolean
  }
  cursor: {
    beforeId?: bigint
    afterId?: bigint
    anchorId?: bigint
    includeAnchor?: boolean
  }
} {
  const limit = clampInlineReadLimit(readNumberParam(params, "limit", { integer: true }), 20, 1)
  const beforeLimitRaw =
    readNumberParam(params, "beforeLimit", { integer: true }) ??
    readNumberParam(params, "before_limit", { integer: true })
  const afterLimitRaw =
    readNumberParam(params, "afterLimit", { integer: true }) ??
    readNumberParam(params, "after_limit", { integer: true })
  const beforeLimit =
    beforeLimitRaw !== undefined ? clampInlineReadLimit(beforeLimitRaw, beforeLimitRaw, 0) : undefined
  const afterLimit =
    afterLimitRaw !== undefined ? clampInlineReadLimit(afterLimitRaw, afterLimitRaw, 0) : undefined
  const includeAnchor = readBooleanParam(params, "includeAnchor") ?? true

  const anchorId = resolveInlineHistoryMessageId(
    params,
    ["anchorId", "aroundId", "messageId", "around"],
    "messageId",
  )
  const beforeId = resolveInlineHistoryMessageId(
    params,
    ["beforeId", "beforeMessageId", "before", "offsetId"],
    "beforeMessageId",
  )
  const afterId = resolveInlineHistoryMessageId(
    params,
    ["afterId", "afterMessageId", "after"],
    "afterMessageId",
  )

  if (anchorId != null && (beforeId != null || afterId != null)) {
    throw new Error("inline action: read messageId/anchorId cannot be combined with before or after")
  }
  if (beforeId != null && afterId != null) {
    throw new Error("inline action: read accepts only one of before or after")
  }

  if (anchorId != null) {
    return {
      mode: "around",
      input: {
        mode: HISTORY_MODE_AROUND,
        anchorId,
        limit,
        ...(beforeLimit !== undefined ? { beforeLimit } : {}),
        ...(afterLimit !== undefined ? { afterLimit } : {}),
        includeAnchor,
      },
      cursor: {
        anchorId,
        includeAnchor,
      },
    }
  }

  if (afterId != null) {
    return {
      mode: "newer",
      input: {
        mode: HISTORY_MODE_NEWER,
        afterId,
        limit,
      },
      cursor: { afterId },
    }
  }

  if (beforeId != null) {
    return {
      mode: "older",
      input: {
        mode: HISTORY_MODE_OLDER,
        beforeId,
        offsetId: beforeId,
        limit,
      },
      cursor: { beforeId },
    }
  }

  return {
    mode: "latest",
    input: {
      mode: HISTORY_MODE_LATEST,
      limit,
    },
    cursor: {},
  }
}

type InlineSpaceInviteRole = {
  role: {
    oneofKind: "member"
    member: {
      canAccessPublicChats: boolean
    }
  } | {
    oneofKind: "admin"
    admin: Record<string, never>
  }
}

type InlineSpaceInviteVia = {
  oneofKind: "userId"
  userId: bigint
} | {
  oneofKind: "email"
  email: string
} | {
  oneofKind: "phoneNumber"
  phoneNumber: string
}

function resolveInlineSpaceInviteRole(params: Record<string, unknown>): InlineSpaceInviteRole {
  const roleValue = readStringParam(params, "role")?.trim().toLowerCase() || "member"
  if (roleValue === "admin") {
    return {
      role: {
        oneofKind: "admin",
        admin: {},
      },
    }
  }
  if (roleValue === "member") {
    return {
      role: {
        oneofKind: "member",
        member: {
          canAccessPublicChats: readBooleanParam(params, "canAccessPublicChats") ?? true,
        },
      },
    }
  }
  throw new Error("inline action: invite-to-space role must be \"admin\" or \"member\"")
}

async function resolveInlineSpaceInviteVia(params: {
  client: InlineSdkClient
  rawParams: Record<string, unknown>
}): Promise<InlineSpaceInviteVia> {
  const email = readStringParam(params.rawParams, "email")?.trim()
  const phoneNumber = (
    readStringParam(params.rawParams, "phoneNumber") ??
    readStringParam(params.rawParams, "phone")
  )?.trim()
  const userRefs = parseInlineListValuesFromParams(params.rawParams, [
    "userId",
    "user",
    "participant",
    "participantId",
    "memberId",
  ])

  const targetModeCount = [userRefs.length > 0, Boolean(email), Boolean(phoneNumber)].filter(Boolean).length
  if (targetModeCount === 0) {
    throw new Error("inline action: invite-to-space requires exactly one of userId/user/participant, email, or phoneNumber")
  }
  if (targetModeCount > 1) {
    throw new Error("inline action: invite-to-space accepts only one invite target")
  }

  if (email) {
    return {
      oneofKind: "email",
      email,
    }
  }
  if (phoneNumber) {
    return {
      oneofKind: "phoneNumber",
      phoneNumber,
    }
  }
  if (userRefs.length > 1) {
    throw new Error("inline action: invite-to-space accepts exactly one user")
  }

  const userIds = await resolveInlineUserIdsFromParams({
    client: params.client,
    values: userRefs,
    label: "invitee",
  })
  if (userIds.length !== 1 || userIds[0] == null) {
    throw new Error("inline action: invite-to-space accepts exactly one user")
  }

  return {
    oneofKind: "userId",
    userId: userIds[0],
  }
}

function summarizeInlineSpaceInviteVia(via: InlineSpaceInviteVia) {
  if (via.oneofKind === "userId") {
    return {
      kind: "userId",
      userId: String(via.userId),
    }
  }
  if (via.oneofKind === "email") {
    return {
      kind: "email",
      email: via.email,
    }
  }
  return {
    kind: "phoneNumber",
    phoneNumber: via.phoneNumber,
  }
}

function resolveInlineActionText(
  params: Record<string, unknown>,
  options: { includeCaption?: boolean; required?: boolean } = {},
): string | undefined {
  const explicit =
    readStringParam(params, "message", { allowEmpty: true }) ??
    readStringParam(params, "text", { allowEmpty: true }) ??
    (options.includeCaption ? readStringParam(params, "caption", { allowEmpty: true }) : undefined)
  const fallback = resolveInlineInteractiveTextFallback({
    text: explicit,
    interactive: params.interactive,
    presentation: params.presentation,
  })
  const text = fallback ?? explicit
  if (text !== undefined) {
    return text
  }
  if (options.required) {
    return readStringParam(params, "text", { required: true, allowEmpty: true })
  }
  return undefined
}

export function supportsInlineMessageButtonsForConfig(
  cfg: OpenClawConfig,
  accountId?: string | null,
): boolean {
  return supportsInlineMessageButtons(listEnabledInlineActions(cfg, accountId))
}

export function supportsInlineReactionsForConfig(
  cfg: OpenClawConfig,
  accountId?: string | null,
): boolean {
  return listEnabledInlineActions(cfg, accountId).includes("react")
}

function describeInlineMessageTool({
  cfg,
  accountId,
}: Parameters<NonNullable<ChannelMessageActionAdapter["describeMessageTool"]>>[0]): ChannelMessageToolDiscovery {
  const actions = listEnabledInlineActions(cfg, accountId ?? null)
  if (actions.length === 0) {
    return {
      actions: [],
      capabilities: [],
      schema: null,
    }
  }

  const buttonsEnabled = supportsInlineMessageButtons(actions)
  const sendEnabled = actions.includes("send")
  const capabilities: ChannelMessageToolDiscovery["capabilities"] = buttonsEnabled ? ["presentation"] : []
  const schema: ChannelMessageToolSchemaContribution[] = []

  if (buttonsEnabled) {
    schema.push({
      properties: {
        buttons: inlineMessageButtonsSchema as unknown as ChannelMessageToolSchemaContribution["properties"][string],
      },
    })
  }

  if (sendEnabled) {
    schema.push({
      actions: ["send"],
      properties: {
        channelData: inlineBotPresenceChannelDataSchema,
      },
    })
  }

  const uploadFileSchemaActions = actions.filter(
    (item) => item === "sendAttachment" || item === "upload-file",
  )
  if (uploadFileSchemaActions.length > 0) {
    schema.push({
      actions: uploadFileSchemaActions as unknown as ChannelMessageActionName[],
      properties: inlineUploadFileSchemaProperties,
    })
  }

  const composeSchemaActions = actions.filter((item) => isInlineComposeActionName(item))
  if (composeSchemaActions.length > 0) {
    schema.push({
      actions: composeSchemaActions as unknown as ChannelMessageActionName[],
      properties: inlineComposeActionSchemaProperties,
    })
  }

  const threadCreateSchemaActions = actions.filter(
    (item): item is "channel-create" | "thread-create" =>
      item === "channel-create" || item === "thread-create",
  )
  if (threadCreateSchemaActions.length > 0) {
    schema.push({
      actions: threadCreateSchemaActions,
      properties: inlineThreadCreateSchemaProperties,
    })
  }

  const channelEditSchemaActions = actions.filter(
    (item): item is "channel-edit" | "renameGroup" =>
      item === "channel-edit" || item === "renameGroup",
  )
  if (channelEditSchemaActions.length > 0) {
    schema.push({
      actions: channelEditSchemaActions,
      properties: inlineChannelEditSchemaProperties,
    })
  }

  if (actions.includes("thread-reply")) {
    schema.push({
      actions: ["thread-reply"],
      properties: inlineThreadReplySchemaProperties,
    })
  }

  const reactionSchemaActions = actions.filter((item) => item === "react" || item === "reactions")
  if (reactionSchemaActions.length > 0) {
    schema.push({
      actions: reactionSchemaActions as unknown as ChannelMessageActionName[],
      properties: inlineReactionSchemaProperties,
    })
  }

  if (actions.includes("read")) {
    schema.push({
      actions: ["read"],
      properties: inlineReadHistorySchemaProperties,
    })
  }

  const getMessagesSchemaActions = actions.filter(
    (item) => item === "get-messages" || item === "getMessages",
  )
  if (getMessagesSchemaActions.length > 0) {
    schema.push({
      actions: getMessagesSchemaActions as unknown as ChannelMessageActionName[],
      properties: inlineGetMessagesSchemaProperties,
    })
  }

  if (actions.includes("download-file")) {
    schema.push({
      actions: ["download-file"] as unknown as ChannelMessageActionName[],
      properties: inlineDownloadFileSchemaProperties,
    })
  }

  const botCommandsSchemaActions = actions.filter(
    (item) =>
      item === "bot-commands" ||
      item === "botCommands" ||
      item === "peer-bot-commands" ||
      item === "peerBotCommands",
  )
  if (botCommandsSchemaActions.length > 0) {
    schema.push({
      actions: botCommandsSchemaActions as unknown as ChannelMessageActionName[],
      properties: inlinePeerBotCommandsSchemaProperties,
    })
  }

  const deleteAttachmentSchemaActions = actions.filter(
    (item) => item === "delete-attachment" || item === "deleteMessageAttachment",
  )
  if (deleteAttachmentSchemaActions.length > 0) {
    schema.push({
      actions: deleteAttachmentSchemaActions as unknown as ChannelMessageActionName[],
      properties: inlineDeleteAttachmentSchemaProperties,
    })
  }

  const pinMessageSchemaActions = actions.filter((item) => item === "pin" || item === "unpin")
  if (pinMessageSchemaActions.length > 0) {
    schema.push({
      actions: pinMessageSchemaActions as unknown as ChannelMessageActionName[],
      properties: inlinePinMessageSchemaProperties,
    })
  }

  if (actions.includes("list-pins")) {
    schema.push({
      actions: ["list-pins"],
      properties: inlineListPinsSchemaProperties,
    })
  }

  const forwardSchemaActions = actions.filter(
    (item) => item === "forward" || item === "forwardMessages",
  )
  if (forwardSchemaActions.length > 0) {
    schema.push({
      actions: forwardSchemaActions as unknown as ChannelMessageActionName[],
      properties: inlineForwardMessagesSchemaProperties,
    })
  }

  const translateSchemaActions = actions.filter(
    (item) => item === "translate" || item === "translateMessages",
  )
  if (translateSchemaActions.length > 0) {
    schema.push({
      actions: translateSchemaActions as unknown as ChannelMessageActionName[],
      properties: inlineTranslateSchemaProperties,
    })
  }

  const inviteSchemaActions = actions.filter(
    (item) => item === "invite-to-space" || item === "inviteToSpace",
  )
  if (inviteSchemaActions.length > 0) {
    schema.push({
      actions: inviteSchemaActions as unknown as ChannelMessageActionName[],
      properties: inlineInviteToSpaceSchemaProperties,
    })
  }

  return {
    actions: actions as ChannelMessageActionName[],
    capabilities,
    schema,
  }
}

function isActionEnabled(params: {
  cfg: OpenClawConfig
  accountId?: string | null
  action: InlineMessageActionName
}): boolean {
  const key = ACTION_TO_GATE_KEY.get(params.action)
  if (!key) return false
  const group = ACTION_GROUPS.find((item) => item.key === key)
  if (!group) return false
  const account = resolveInlineAccount({
    cfg: params.cfg,
    accountId: params.accountId ?? null,
  })
  const gate = createActionGate((account.config.actions ?? {}) as Record<string, boolean | undefined>)
  return gate(key, group.defaultEnabled)
}

type LegacyInlineMessageActionAdapter = {
  listActions?: (params: { cfg: OpenClawConfig }) => InlineMessageActionName[]
  supportsButtons?: (params: { cfg: OpenClawConfig }) => boolean
  supportsCards?: (params: { cfg: OpenClawConfig }) => boolean
}

const inlineMessageActionTargetAliases = {
  react: {
    aliases: ["to", "target", "chatId", "channelId", "threadId", "messageId", "emoji", "remove"],
  },
  reactions: {
    aliases: ["to", "target", "chatId", "channelId", "threadId", "messageId"],
  },
  "thread-reply": {
    aliases: [
      "threadId",
      "parentMessageId",
      "threadParentMessageId",
      "anchorMessageId",
      "messageId",
      "replyTo",
      "replyToId",
    ],
  },
  "thread-create": {
    aliases: [
      "chatId",
      "spaceId",
      "space",
      "parentMessageId",
      "messageId",
      "replyTo",
      "replyToId",
      "participant",
      "participants",
      "participantId",
      "participantIds",
      "userId",
      "userIds",
    ],
  },
  "channel-edit": {
    aliases: [
      "chatId",
      "channelId",
      "to",
      "title",
      "name",
      "threadName",
      "emoji",
      "isPublic",
      "public",
      "visibility",
      "privacy",
      "participant",
      "participants",
      "participantId",
      "participantIds",
      "userId",
      "userIds",
    ],
  },
  renameGroup: {
    aliases: ["chatId", "channelId", "to", "title", "name", "threadName", "emoji"],
  },
  read: {
    aliases: [
      "to",
      "target",
      "chatId",
      "channelId",
      "userId",
      "threadId",
      "before",
      "beforeId",
      "beforeMessageId",
      "after",
      "afterId",
      "afterMessageId",
      "messageId",
      "anchorId",
      "around",
      "aroundId",
      "beforeLimit",
      "afterLimit",
      "includeAnchor",
      "limit",
    ],
  },
  "get-messages": {
    aliases: [
      "to",
      "target",
      "chatId",
      "channelId",
      "userId",
      "threadId",
      "messageId",
      "messageIds",
      "messages",
      "ids",
    ],
  },
  getMessages: {
    aliases: [
      "to",
      "target",
      "chatId",
      "channelId",
      "userId",
      "threadId",
      "messageId",
      "messageIds",
      "messages",
      "ids",
    ],
  },
  "download-file": {
    aliases: [
      "to",
      "target",
      "chatId",
      "channelId",
      "userId",
      "threadId",
      "messageId",
      "mediaId",
      "attachmentId",
      "mediaUrl",
      "mediaUrls",
      "fileUrl",
      "url",
      "media",
      "file",
      "filePath",
      "path",
      "attachmentUrl",
      "fileName",
    ],
  },
  "bot-commands": {
    aliases: ["to", "target", "chatId", "channelId", "userId", "threadId"],
  },
  botCommands: {
    aliases: ["to", "target", "chatId", "channelId", "userId", "threadId"],
  },
  "peer-bot-commands": {
    aliases: ["to", "target", "chatId", "channelId", "userId", "threadId"],
  },
  peerBotCommands: {
    aliases: ["to", "target", "chatId", "channelId", "userId", "threadId"],
  },
  translate: {
    aliases: [
      "chatId",
      "channelId",
      "to",
      "messageId",
      "messageIds",
      "messages",
      "ids",
      "language",
      "lang",
      "targetLanguage",
      "toLanguage",
    ],
  },
  translateMessages: {
    aliases: [
      "chatId",
      "channelId",
      "to",
      "messageId",
      "messageIds",
      "messages",
      "ids",
      "language",
      "lang",
      "targetLanguage",
      "toLanguage",
    ],
  },
  "delete-attachment": {
    aliases: ["chatId", "channelId", "to", "messageId", "attachmentId"],
  },
  deleteMessageAttachment: {
    aliases: ["chatId", "channelId", "to", "messageId", "attachmentId"],
  },
  pin: {
    aliases: ["to", "target", "chatId", "channelId", "threadId", "messageId"],
  },
  unpin: {
    aliases: ["to", "target", "chatId", "channelId", "threadId", "messageId"],
  },
  "list-pins": {
    aliases: ["to", "target", "chatId", "channelId", "threadId"],
  },
  sendAttachment: {
    aliases: [
      "to",
      "target",
      "chatId",
      "channelId",
      "userId",
      "filePath",
      "path",
      "media",
      "mediaUrl",
      "mediaUrls",
      "url",
      "file",
      "files",
      "filePaths",
      "message",
      "text",
      "caption",
      "messageId",
      "replyTo",
      "replyToId",
    ],
  },
  "upload-file": {
    aliases: [
      "to",
      "target",
      "chatId",
      "channelId",
      "userId",
      "filePath",
      "path",
      "media",
      "mediaUrl",
      "mediaUrls",
      "url",
      "file",
      "files",
      "filePaths",
      "message",
      "text",
      "caption",
      "messageId",
      "replyTo",
      "replyToId",
    ],
  },
  "compose-action": {
    aliases: [...INLINE_COMPOSE_TARGET_ALIASES],
  },
  typing: {
    aliases: [...INLINE_COMPOSE_TARGET_ALIASES],
  },
  "stop-typing": {
    aliases: [...INLINE_COMPOSE_TARGET_ALIASES],
  },
  "uploading-photo": {
    aliases: [...INLINE_COMPOSE_TARGET_ALIASES],
  },
  "uploading-document": {
    aliases: [...INLINE_COMPOSE_TARGET_ALIASES],
  },
  "uploading-video": {
    aliases: [...INLINE_COMPOSE_TARGET_ALIASES],
  },
  "recording-voice": {
    aliases: [...INLINE_COMPOSE_TARGET_ALIASES],
  },
  forward: {
    aliases: [
      "to",
      "target",
      "destination",
      "chatId",
      "channelId",
      "toChatId",
      "destinationChatId",
      "userId",
      "toUserId",
      "destinationUserId",
      "from",
      "source",
      "fromChatId",
      "sourceChatId",
      "fromChannelId",
      "sourceChannelId",
      "fromUserId",
      "sourceUserId",
      "messageId",
      "messageIds",
      "messages",
      "ids",
      "shareForwardHeader",
      "includeForwardHeader",
    ],
  },
  forwardMessages: {
    aliases: [
      "to",
      "target",
      "destination",
      "chatId",
      "channelId",
      "toChatId",
      "destinationChatId",
      "userId",
      "toUserId",
      "destinationUserId",
      "from",
      "source",
      "fromChatId",
      "sourceChatId",
      "fromChannelId",
      "sourceChannelId",
      "fromUserId",
      "sourceUserId",
      "messageId",
      "messageIds",
      "messages",
      "ids",
      "shareForwardHeader",
      "includeForwardHeader",
    ],
  },
  "invite-to-space": {
    aliases: [
      "spaceId",
      "space",
      "chatId",
      "channelId",
      "to",
      "userId",
      "user",
      "participant",
      "participantId",
      "memberId",
      "email",
      "phoneNumber",
      "phone",
      "role",
    ],
  },
  inviteToSpace: {
    aliases: [
      "spaceId",
      "space",
      "chatId",
      "channelId",
      "to",
      "userId",
      "user",
      "participant",
      "participantId",
      "memberId",
      "email",
      "phoneNumber",
      "phone",
      "role",
    ],
  },
} as unknown as NonNullable<ChannelMessageActionAdapter["messageActionTargetAliases"]>

export const inlineMessageActions = {
  describeMessageTool: describeInlineMessageTool,
  listActions: ({ cfg, accountId }: { cfg: OpenClawConfig; accountId?: string | null }) =>
    listEnabledInlineActions(cfg, accountId ?? null),
  supportsButtons: ({ cfg, accountId }: { cfg: OpenClawConfig; accountId?: string | null }) =>
    supportsInlineMessageButtons(listEnabledInlineActions(cfg, accountId ?? null)),
  supportsCards: () => false,
  supportsAction: ({ action }) => SUPPORTED_ACTIONS.includes(action as InlineMessageActionName),
  messageActionTargetAliases: inlineMessageActionTargetAliases,
  extractToolSend: ({ args }) => {
    const action = typeof args.action === "string" ? args.action.trim() : ""
    if (action !== "sendMessage") return null
    const to = typeof args.to === "string" ? args.to.trim() : ""
    if (!to) return null
    const normalized = normalizeInlineTarget(to) ?? to
    if (!/^(user:)?[0-9]+$/i.test(normalized)) return null
    return { to: normalized }
  },
  handleAction: async ({
    action,
    params,
    cfg,
    accountId,
    mediaAccess,
    mediaLocalRoots,
    mediaReadFile,
    toolContext,
  }) => {
    if (!SUPPORTED_ACTIONS.includes(action as InlineMessageActionName)) {
      throw new Error(`Action ${action} is not supported for provider inline.`)
    }
    if (!isActionEnabled({ cfg, accountId: accountId ?? null, action: action as InlineMessageActionName })) {
      if (action === "react") {
        return jsonResult({
          ok: false,
          reason: "disabled",
          hint: "Inline reactions are disabled via channels.inline.actions.reactions. Do not retry.",
        })
      }
      throw new Error(`inline action: ${action} is disabled by channels.inline.actions`)
    }

    const normalizedAction = action as InlineMessageActionName
    const actionAgentId = resolveInlineActionAgentId({
      args: params,
      toolContext: toolContext as Record<string, unknown> | null | undefined,
    })

    if (isInlineComposeActionName(normalizedAction)) {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const target = resolveInlineComposePeer(
            params,
            toolContext != null
              ? {
                  currentChannelId: toolContext.currentChannelId,
                }
              : undefined,
          )
          const compose = resolveInlineComposeAction({ action: normalizedAction, rawParams: params })
          const result = await client.invokeRaw(SEND_COMPOSE_ACTION_METHOD, {
            oneofKind: "sendComposeAction",
            sendComposeAction: {
              peerId: target.peerId,
              action: compose.rpcAction,
            },
          })
          if (result.oneofKind !== "sendComposeAction") {
            throw new Error(
              `inline action: expected sendComposeAction result, got ${String(result.oneofKind)}`,
            )
          }
          return jsonResult({
            ok: true,
            target: target.target,
            composeAction: compose.label,
            action: compose.label,
            rpcAction: compose.rpcAction,
            usedCurrentChatDefault: target.usedFallback,
          })
        },
      })
    }

    if (normalizedAction === "send" || normalizedAction === "sendAttachment" || normalizedAction === "upload-file") {
      const parseMarkdown =
        resolveInlineAccount({ cfg, accountId: accountId ?? null }).config.parseMarkdown ?? true
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const target = resolveMessageSendTargetFromParams(params)
          const actions = resolveInlineMessageActionsParam(params)
          const sendTarget =
            target.chatId != null ? { chatId: target.chatId } : target.userId != null ? { userId: target.userId } : null
          if (!sendTarget) {
            throw new Error("inline action: missing message target")
          }
          const mediaSources = resolveInlineOutboundMediaInputs(params)
          const text = resolveInlineActionText(params, { includeCaption: true }) ?? ""
          const caption = sanitizeVisibleActionText(text)
          const replyToMsgId = parseOptionalInlineId(
            readFlexibleId(params, "messageId") ??
              readFlexibleId(params, "replyTo") ??
              readFlexibleId(params, "replyToId") ??
              readStringParam(params, "messageId") ??
              readStringParam(params, "replyTo") ??
              readStringParam(params, "replyToId"),
            "messageId",
          )

          if ((normalizedAction === "sendAttachment" || normalizedAction === "upload-file") && mediaSources.length === 0) {
            throw new Error(`inline action: ${normalizedAction} requires media/file input`)
          }

          if (mediaSources.length === 0) {
            const message = resolveInlineActionText(params, { required: true })
            const visibleMessage = sanitizeVisibleActionText(message)
            if (visibleMessage.shouldSkip) {
              return suppressedInternalTextResult()
            }
            const sent = await client.sendMessage({
              ...sendTarget,
              text: visibleMessage.text,
              ...(actions !== undefined ? { actions } : {}),
              ...(replyToMsgId != null ? { replyToMsgId } : {}),
              parseMarkdown,
            })
            return jsonResult({
              ok: true,
              target: target.target,
              messageId: sent.messageId != null ? String(sent.messageId) : null,
              replyToId: replyToMsgId != null ? String(replyToMsgId) : null,
            })
          }

          let lastSent: { messageId?: bigint | null } | null = null
          for (let index = 0; index < mediaSources.length; index += 1) {
            const mediaUrl = mediaSources[index]
            if (!mediaUrl) continue
            const media = await uploadInlineMediaFromUrl({
              client,
              cfg,
              accountId: accountId ?? null,
              mediaUrl,
              ...(mediaAccess ? { mediaAccess } : {}),
              ...(mediaLocalRoots ? { mediaLocalRoots } : {}),
              ...(mediaReadFile ? { mediaReadFile } : {}),
            })
            lastSent = await client.sendMessage({
              ...sendTarget,
              ...(index === 0 && !caption.shouldSkip && caption.text ? { text: caption.text } : {}),
              media,
              ...(index === 0 && actions !== undefined ? { actions } : {}),
              ...(index === 0 && replyToMsgId != null ? { replyToMsgId } : {}),
              ...(index === 0 && !caption.shouldSkip && caption.text ? { parseMarkdown } : {}),
            })
          }
          return jsonResult({
            ok: true,
            target: target.target,
            messageId: lastSent?.messageId != null ? String(lastSent.messageId) : null,
            ...(mediaSources.length === 1 ? { mediaUrl: mediaSources[0] } : { mediaUrls: mediaSources }),
            replyToId: replyToMsgId != null ? String(replyToMsgId) : null,
          })
        },
      })
    }

    if (normalizedAction === "forward" || normalizedAction === "forwardMessages") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const destination = resolveInlineForwardDestinationPeer(params)
          const source = resolveInlineForwardSourcePeer(
            params,
            toolContext != null
              ? {
                  currentChannelId: toolContext.currentChannelId,
                }
              : undefined,
          )
          const messageIds = resolveInlineForwardMessageIds(
            params,
            toolContext != null
              ? {
                  currentMessageId: toolContext.currentMessageId,
                }
              : undefined,
          )
          const shareForwardHeader =
            readBooleanParam(params, "shareForwardHeader") ??
            readBooleanParam(params, "includeForwardHeader")

          const result = await client.invokeRaw(FORWARD_MESSAGES_METHOD, {
            oneofKind: "forwardMessages",
            forwardMessages: {
              fromPeerId: source.peerId,
              toPeerId: destination.peerId,
              messageIds,
              ...(shareForwardHeader !== undefined ? { shareForwardHeader } : {}),
            },
          })
          if (result.oneofKind !== "forwardMessages") {
            throw new Error(
              `inline action: expected forwardMessages result, got ${String(result.oneofKind)}`,
            )
          }

          const forwardedMessageIds = extractNewMessageIdsFromUpdates(result.forwardMessages.updates)
          return jsonResult({
            ok: true,
            from: source.target,
            to: destination.target,
            messageIds: messageIds.map((id) => String(id)),
            shareForwardHeader: shareForwardHeader ?? true,
            usedCurrentChatDefault: source.usedFallback,
            forwardedMessageIds,
            forwardedMessageId: forwardedMessageIds[0] ?? null,
          })
        },
      })
    }

    if (normalizedAction === "reply" || normalizedAction === "thread-reply") {
      const parseMarkdown =
        resolveInlineAccount({ cfg, accountId: accountId ?? null }).config.parseMarkdown ?? true
      const isThreadReply = normalizedAction === "thread-reply"
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client, account) => {
          const actions = resolveInlineMessageActionsParam(params)
          if (isThreadReply) {
            const target = await resolveInlineThreadReplyTarget({
              accountId: account.accountId,
              ...(actionAgentId ? { agentId: actionAgentId } : {}),
              args: params,
              ...(toolContext != null
                ? {
                    toolContext: {
                      currentChannelId: toolContext.currentChannelId,
                      currentThreadTs: toolContext.currentThreadTs,
                      currentMessageId: toolContext.currentMessageId,
                    },
                  }
                : {}),
            })
            if (!target) {
              throw new Error(
                "inline thread-reply: threadId is required unless the current turn is already in a reply thread or a saved parent thread route exists. Pass threadId, or pass to/chatId plus parentMessageId after thread-create.",
              )
            }
            const chatId = target.chatId
            const replyToMsgId = parseOptionalInlineId(
              readFlexibleId(params, "messageId") ??
                readFlexibleId(params, "replyTo") ??
                readFlexibleId(params, "replyToId") ??
                readStringParam(params, "messageId") ??
                readStringParam(params, "replyTo") ??
                readStringParam(params, "replyToId"),
              "messageId",
            )
            const text = resolveInlineActionText(params, { required: true })
            const visibleText = sanitizeVisibleActionText(text)
            if (visibleText.shouldSkip) {
              return suppressedInternalTextResult()
            }
            const sent = await client.sendMessage({
              chatId,
              text: visibleText.text,
              ...(actions !== undefined ? { actions } : {}),
              ...(replyToMsgId != null ? { replyToMsgId } : {}),
              parseMarkdown,
            })
            if (target.parentChatId != null) {
              recordInlineThreadParticipation(
                account.accountId,
                target.parentChatId,
                chatId,
                actionAgentId ? { agentId: actionAgentId } : undefined,
              )
            }
            return jsonResult({
              ok: true,
              chatId: String(chatId),
              threadId: String(chatId),
              resolvedBy: target.resolvedBy,
              parentChatId: target.parentChatId != null ? String(target.parentChatId) : null,
              parentMessageId: target.parentMessageId != null ? String(target.parentMessageId) : null,
              messageId: sent.messageId != null ? String(sent.messageId) : null,
              replyToId: replyToMsgId != null ? String(replyToMsgId) : null,
            })
          }
          const replyParams = params
          const chatId = resolveChatIdFromParams(replyParams)
          const replyToMsgId = parseInlineId(
            readFlexibleId(replyParams, "messageId") ??
              readFlexibleId(replyParams, "replyTo") ??
              readFlexibleId(replyParams, "replyToId") ??
              readStringParam(replyParams, "messageId") ??
              readStringParam(replyParams, "replyTo") ??
              readStringParam(replyParams, "replyToId", { required: true }),
            "messageId",
          )
          const text = resolveInlineActionText(replyParams, { required: true })
          const visibleText = sanitizeVisibleActionText(text)
          if (visibleText.shouldSkip) {
            return suppressedInternalTextResult()
          }
          const sent = await client.sendMessage({
            chatId,
            text: visibleText.text,
            ...(actions !== undefined ? { actions } : {}),
            replyToMsgId,
            parseMarkdown,
          })
          return jsonResult({
            ok: true,
            chatId: String(chatId),
            messageId: sent.messageId != null ? String(sent.messageId) : null,
            replyToId: String(replyToMsgId),
          })
        },
      })
    }

    if (normalizedAction === "react") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const target = resolveInlineCurrentChatTarget({
            args: params,
            toolContext,
            label: "inline action: react",
          })
          const rawMessageId = resolveMessageIdFromParamsOrContext(
            toolContext != null
              ? { args: params, toolContext }
              : { args: params },
          )
          if (!rawMessageId) {
            return jsonResult({
              ok: false,
              reason: "missing_message_id",
              hint: "Inline reaction requires a valid messageId (or inbound context fallback). Do not retry.",
            })
          }
          let messageId: bigint
          try {
            messageId = parseInlineId(rawMessageId, "messageId")
          } catch {
            return jsonResult({
              ok: false,
              reason: "missing_message_id",
              hint: "Inline reaction requires a valid messageId (or inbound context fallback). Do not retry.",
            })
          }
          const { emoji, remove, isEmpty } = readReactionParams(params, {
            removeErrorMessage: "Emoji is required to remove an Inline reaction.",
          })
          if (isEmpty) {
            throw new Error("inline action: react requires emoji")
          }

          if (remove) {
            try {
              const result = await client.invokeRaw(Method.DELETE_REACTION, {
                oneofKind: "deleteReaction",
                deleteReaction: {
                  emoji,
                  peerId: buildChatPeer(target.chatId),
                  messageId,
                },
              })
              if (result.oneofKind !== "deleteReaction") {
                throw new Error(
                  `inline action: expected deleteReaction result, got ${String(result.oneofKind)}`,
                )
              }
            } catch {
              return jsonResult({
                ok: false,
                reason: "error",
                emoji,
                remove: true,
                hint: "Reaction failed. Do not retry.",
              })
            }
          } else {
            if (
              await reactionAlreadyExists({
                client,
                chatId: target.chatId,
                messageId,
                emoji,
              })
            ) {
              return jsonResult({
                ok: true,
                chatId: String(target.chatId),
                messageId: String(messageId),
                emoji,
                remove: false,
                alreadyPresent: true,
                usedCurrentChatDefault: target.usedCurrentChatDefault,
                usedCurrentThreadDefault: target.usedCurrentThreadDefault,
              })
            }

            try {
              const result = await client.invokeRaw(Method.ADD_REACTION, {
                oneofKind: "addReaction",
                addReaction: {
                  emoji,
                  messageId,
                  peerId: buildChatPeer(target.chatId),
                },
              })
              if (result.oneofKind !== "addReaction") {
                throw new Error(
                  `inline action: expected addReaction result, got ${String(result.oneofKind)}`,
                )
              }
            } catch (error) {
              if (!isDuplicateReactionError(error)) {
                return jsonResult({
                  ok: false,
                  reason: "error",
                  emoji,
                  hint: "Reaction failed. Do not retry.",
                })
              }
              return jsonResult({
                ok: true,
                chatId: String(target.chatId),
                messageId: String(messageId),
                emoji,
                remove: false,
                alreadyPresent: true,
                usedCurrentChatDefault: target.usedCurrentChatDefault,
                usedCurrentThreadDefault: target.usedCurrentThreadDefault,
              })
            }
          }

          return jsonResult({
            ok: true,
            chatId: String(target.chatId),
            messageId: String(messageId),
            emoji,
            remove,
            usedCurrentChatDefault: target.usedCurrentChatDefault,
            usedCurrentThreadDefault: target.usedCurrentThreadDefault,
          })
        },
      })
    }

    if (normalizedAction === "reactions") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const target = resolveInlineCurrentChatTarget({
            args: params,
            toolContext,
            label: "inline action: reactions",
          })
          const messageId = parseInlineId(
            resolveMessageIdFromParamsOrContext(
              toolContext != null
                ? { args: params, toolContext }
                : { args: params },
            ),
            "messageId",
          )
          const reactions = await loadMessageReactions({
            client,
            chatId: target.chatId,
            messageId,
          })
          return jsonResult({
            ok: true,
            chatId: String(target.chatId),
            messageId: String(messageId),
            reactions,
            usedCurrentChatDefault: target.usedCurrentChatDefault,
            usedCurrentThreadDefault: target.usedCurrentThreadDefault,
          })
        },
      })
    }

    if (normalizedAction === "read") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const target = resolveInlineReadTarget(
            params,
            toolContext != null
              ? {
                  currentChannelId: toolContext.currentChannelId,
                  currentThreadTs: toolContext.currentThreadTs,
                }
              : undefined,
          )
          const history = resolveInlineHistoryRequest(params)
          const result = await client.invokeRaw(Method.GET_CHAT_HISTORY, {
            oneofKind: "getChatHistory",
            getChatHistory: {
              peerId: target.peerId,
              ...history.input,
            },
          })
          if (result.oneofKind !== "getChatHistory") {
            throw new Error(
              `inline action: expected getChatHistory result, got ${String(result.oneofKind)}`,
            )
          }
          return jsonResult(
            toJsonSafe({
              ok: true,
              target: target.target,
              chatId: target.chatId != null ? String(target.chatId) : null,
              threadId: target.threadId != null ? String(target.threadId) : null,
              mode: history.mode,
              limit: history.input.limit,
              beforeId: history.cursor.beforeId != null ? String(history.cursor.beforeId) : null,
              afterId: history.cursor.afterId != null ? String(history.cursor.afterId) : null,
              anchorId: history.cursor.anchorId != null ? String(history.cursor.anchorId) : null,
              includeAnchor: history.cursor.includeAnchor ?? null,
              usedCurrentChatDefault: target.usedCurrentChatDefault,
              usedCurrentThreadDefault: target.usedCurrentThreadDefault,
              messages: (result.getChatHistory.messages ?? []).map((message) => mapMessage(message)),
            }),
          )
        },
      })
    }

    if (normalizedAction === "get-messages" || normalizedAction === "getMessages") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const target = resolveInlineReadTarget(
            params,
            toolContext != null
              ? {
                  currentChannelId: toolContext.currentChannelId,
                  currentThreadTs: toolContext.currentThreadTs,
                }
              : undefined,
          )
          const messageIds = resolveInlineGetMessageIds(params, {
            currentMessageId: toolContext?.currentMessageId,
          })
          const result = await client.invokeRaw(GET_MESSAGES_METHOD, {
            oneofKind: "getMessages",
            getMessages: {
              peerId: target.peerId,
              messageIds,
            },
          })
          if (result.oneofKind !== "getMessages") {
            throw new Error(
              `inline action: expected getMessages result, got ${String(result.oneofKind)}`,
            )
          }
          return jsonResult(
            toJsonSafe({
              ok: true,
              target: target.target,
              chatId: target.chatId != null ? String(target.chatId) : null,
              threadId: target.threadId != null ? String(target.threadId) : null,
              messageIds: messageIds.map((id) => String(id)),
              usedCurrentChatDefault: target.usedCurrentChatDefault,
              usedCurrentThreadDefault: target.usedCurrentThreadDefault,
              messages: (result.getMessages.messages ?? []).map((message) => mapMessage(message)),
            }),
          )
        },
      })
    }

    if (normalizedAction === "download-file") {
      const explicitUrl = resolveInlineDownloadMediaUrl(params)
      const explicitFileName = readStringParam(params, "fileName") ?? readStringParam(params, "filename")
      if (explicitUrl) {
        const downloaded = await downloadInlineMediaFromUrl({
          cfg,
          accountId: accountId ?? null,
          mediaUrl: explicitUrl,
          ...(explicitFileName ? { fileName: explicitFileName } : {}),
          ...(mediaAccess ? { mediaAccess } : {}),
          ...(mediaLocalRoots ? { mediaLocalRoots } : {}),
          ...(mediaReadFile ? { mediaReadFile } : {}),
        })
        return inlineDownloadFileResult({
          source: {
            url: explicitUrl,
            source: "explicit",
            sourceId: null,
            ...(explicitFileName ? { fileName: explicitFileName } : {}),
          },
          downloaded,
        })
      }

      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const target = resolveInlineReadTarget(
            params,
            toolContext != null
              ? {
                  currentChannelId: toolContext.currentChannelId,
                  currentThreadTs: toolContext.currentThreadTs,
                }
              : undefined,
          )
          const messageId = parseInlineId(
            resolveMessageIdFromParamsOrContext(
              toolContext != null
                ? { args: params, toolContext }
                : { args: params },
            ),
            "messageId",
          )
          const result = await client.invokeRaw(GET_MESSAGES_METHOD, {
            oneofKind: "getMessages",
            getMessages: {
              peerId: target.peerId,
              messageIds: [messageId],
            },
          })
          if (result.oneofKind !== "getMessages") {
            throw new Error(
              `inline action: expected getMessages result, got ${String(result.oneofKind)}`,
            )
          }
          const message = (result.getMessages.messages ?? []).find((item) => item.id === messageId)
          if (!message) {
            return jsonResult({
              ok: false,
              reason: "message_not_found",
              error: "File could not be downloaded because the source message was not found or inaccessible.",
              target: target.target,
              chatId: target.chatId != null ? String(target.chatId) : null,
              threadId: target.threadId != null ? String(target.threadId) : null,
              messageId: String(messageId),
            })
          }

          const mapped = mapMessage(message)
          const mediaId = readFlexibleId(params, "mediaId") ?? readStringParam(params, "mediaId")
          const attachmentId =
            readFlexibleId(params, "attachmentId") ?? readStringParam(params, "attachmentId")
          const source = selectInlineDownloadSource({
            message: mapped,
            ...(mediaId ? { mediaId } : {}),
            ...(attachmentId ? { attachmentId } : {}),
          })
          if (!source) {
            return jsonResult({
              ok: false,
              reason: "no_downloadable_media",
              error: "File could not be downloaded because the message has no downloadable media or matching preview image.",
              target: target.target,
              chatId: target.chatId != null ? String(target.chatId) : null,
              threadId: target.threadId != null ? String(target.threadId) : null,
              messageId: String(messageId),
              mediaId: mediaId ?? null,
              attachmentId: attachmentId ?? null,
            })
          }

          const fileName = explicitFileName ?? source.fileName ?? undefined
          const downloaded = await downloadInlineMediaFromUrl({
            cfg,
            accountId: accountId ?? null,
            mediaUrl: source.url,
            ...(fileName ? { fileName } : {}),
            ...(mediaAccess ? { mediaAccess } : {}),
            ...(mediaLocalRoots ? { mediaLocalRoots } : {}),
            ...(mediaReadFile ? { mediaReadFile } : {}),
          })
          return inlineDownloadFileResult({
            target,
            messageId,
            source,
            downloaded,
          })
        },
      })
    }

    if (
      normalizedAction === "bot-commands" ||
      normalizedAction === "botCommands" ||
      normalizedAction === "peer-bot-commands" ||
      normalizedAction === "peerBotCommands"
    ) {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const target = resolveInlineReadTarget(
            params,
            toolContext != null
              ? {
                  currentChannelId: toolContext.currentChannelId,
                  currentThreadTs: toolContext.currentThreadTs,
                }
              : undefined,
          )
          const result = await client.invokeRaw(GET_PEER_BOT_COMMANDS_METHOD, {
            oneofKind: "getPeerBotCommands",
            getPeerBotCommands: {
              peerId: target.peerId,
            },
          })
          if (result.oneofKind !== "getPeerBotCommands") {
            throw new Error(
              `inline action: expected getPeerBotCommands result, got ${String(result.oneofKind)}`,
            )
          }
          const bots = (result.getPeerBotCommands.bots ?? []).map(mapPeerBotCommandGroup)
          return jsonResult(
            toJsonSafe({
              ok: true,
              target: target.target,
              chatId: target.chatId != null ? String(target.chatId) : null,
              threadId: target.threadId != null ? String(target.threadId) : null,
              usedCurrentChatDefault: target.usedCurrentChatDefault,
              usedCurrentThreadDefault: target.usedCurrentThreadDefault,
              count: bots.length,
              commandsCount: bots.reduce((sum, bot) => sum + bot.count, 0),
              bots,
            }),
          )
        },
      })
    }

    if (normalizedAction === "search") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const query =
            readStringParam(params, "query") ??
            readStringParam(params, "q") ??
            readStringParam(params, "message", { required: true })
          const limit = Math.max(1, Math.min(100, readNumberParam(params, "limit", { integer: true }) ?? 20))
          const offsetId = parseOptionalInlineId(readFlexibleId(params, "offsetId"), "offsetId")
          const result = await client.invokeRaw(Method.SEARCH_MESSAGES, {
            oneofKind: "searchMessages",
            searchMessages: {
              peerId: buildChatPeer(chatId),
              queries: [query],
              limit,
              ...(offsetId != null ? { offsetId } : {}),
            },
          })
          if (result.oneofKind !== "searchMessages") {
            throw new Error(
              `inline action: expected searchMessages result, got ${String(result.oneofKind)}`,
            )
          }
          return jsonResult(
            toJsonSafe({
              ok: true,
              chatId: String(chatId),
              query,
              messages: (result.searchMessages.messages ?? []).map((message) => mapMessage(message)),
            }),
          )
        },
      })
    }

    if (normalizedAction === "translate" || normalizedAction === "translateMessages") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const language = resolveInlineTranslateLanguage(params)
          const messageIds = resolveInlineTranslateMessageIds(
            params,
            toolContext != null
              ? {
                  currentMessageId: toolContext.currentMessageId,
                }
              : undefined,
          )
          const result = await client.invokeRaw(Method.TRANSLATE_MESSAGES, {
            oneofKind: "translateMessages",
            translateMessages: {
              peerId: buildChatPeer(chatId),
              messageIds,
              language,
            },
          })
          if (result.oneofKind !== "translateMessages") {
            throw new Error(
              `inline action: expected translateMessages result, got ${String(result.oneofKind)}`,
            )
          }
          return jsonResult(
            toJsonSafe({
              ok: true,
              chatId: String(chatId),
              messageIds: messageIds.map((id) => String(id)),
              language,
              translations: (
                (result.translateMessages.translations ?? []) as Array<Parameters<typeof mapTranslation>[0]>
              ).map((translation) => mapTranslation(translation)),
            }),
          )
        },
      })
    }

    if (normalizedAction === "edit") {
      const parseMarkdown =
        resolveInlineAccount({ cfg, accountId: accountId ?? null }).config.parseMarkdown ?? true
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const actions = resolveInlineMessageActionsParam(params)
          const messageId = parseInlineId(
            readFlexibleId(params, "messageId") ??
              readStringParam(params, "messageId", { required: true }),
            "messageId",
          )
          const text = resolveInlineActionText(params, { required: true })
          const visibleText = sanitizeVisibleActionText(text)
          if (visibleText.shouldSkip) {
            return suppressedInternalTextResult()
          }
          const result = await client.invokeRaw(Method.EDIT_MESSAGE, {
            oneofKind: "editMessage",
            editMessage: {
              messageId,
              peerId: buildChatPeer(chatId),
              text: visibleText.text,
              ...(actions !== undefined ? { actions } : {}),
              parseMarkdown,
            },
          })
          if (result.oneofKind !== "editMessage") {
            throw new Error(`inline action: expected editMessage result, got ${String(result.oneofKind)}`)
          }
          return jsonResult(
            toJsonSafe({
              ok: true,
              chatId: String(chatId),
              messageId: String(messageId),
              text: visibleText.text,
              parseMarkdown,
            }),
          )
        },
      })
    }

    if (normalizedAction === "channel-info") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const result = await client.invokeRaw(Method.GET_CHAT, {
            oneofKind: "getChat",
            getChat: { peerId: buildChatPeer(chatId) },
          })
          if (result.oneofKind !== "getChat") {
            throw new Error(`inline action: expected getChat result, got ${String(result.oneofKind)}`)
          }
          return jsonResult(
            toJsonSafe({
              ok: true,
              chatId: String(chatId),
              chat: result.getChat.chat ?? null,
              dialog: result.getChat.dialog ?? null,
              pinnedMessageIds: (result.getChat.pinnedMessageIds ?? []).map((id) => String(id)),
            }),
          )
        },
      })
    }

    if (normalizedAction === "channel-edit" || normalizedAction === "renameGroup") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const title = optionalVisibleActionText(
            readStringParam(params, "title") ??
              readStringParam(params, "name") ??
              readStringParam(params, "threadName") ??
              readStringParam(params, "message"),
            "title",
          )
          const emoji = optionalVisibleActionText(readStringParam(params, "emoji"), "emoji")
          const isPublic = resolveInlineVisibilityParam(params)
          if (title == null && emoji == null && isPublic == null) {
            throw new Error("inline action: channel-edit requires title/name/threadName/message, emoji, or visibility")
          }

          let infoChat: unknown = null
          if (title != null || emoji != null) {
            const result = await client.invokeRaw(Method.UPDATE_CHAT_INFO, {
              oneofKind: "updateChatInfo",
              updateChatInfo: {
                chatId,
                ...(title != null ? { title } : {}),
                ...(emoji != null ? { emoji } : {}),
              },
            })
            if (result.oneofKind !== "updateChatInfo") {
              throw new Error(
                `inline action: expected updateChatInfo result, got ${String(result.oneofKind)}`,
              )
            }
            infoChat = result.updateChatInfo.chat ?? null
          }

          let visibilityChat: unknown = null
          if (isPublic != null) {
            const participantRefs = parseInlineListValuesFromParams(params, [
              "participants",
              "participantIds",
              "participantId",
              "participant",
              "userIds",
              "userId",
            ])
            if (isPublic && participantRefs.length > 0) {
              throw new Error("inline action: public channel-edit visibility must not include participants")
            }
            if (!isPublic && participantRefs.length === 0) {
              throw new Error("inline action: private channel-edit visibility requires participant/participants")
            }
            const participants = isPublic
              ? []
              : await resolveInlineUserIdsFromParams({
                  client,
                  values: participantRefs,
                  label: "participant",
                })
            const result = await client.invokeRaw(UPDATE_CHAT_VISIBILITY_METHOD, {
              oneofKind: "updateChatVisibility",
              updateChatVisibility: {
                chatId,
                isPublic,
                participants: participants.map((userId) => ({ userId })),
              },
            })
            if (result.oneofKind !== "updateChatVisibility") {
              throw new Error(
                `inline action: expected updateChatVisibility result, got ${String(result.oneofKind)}`,
              )
            }
            visibilityChat = result.updateChatVisibility.chat ?? null
          }

          return jsonResult(
            toJsonSafe({
              ok: true,
              chatId: String(chatId),
              ...(title != null ? { title } : {}),
              ...(emoji != null ? { emoji } : {}),
              ...(isPublic != null ? { isPublic } : {}),
              infoUpdated: title != null || emoji != null,
              visibilityUpdated: isPublic != null,
              chat: visibilityChat ?? infoChat,
            }),
          )
        },
      })
    }

    if (normalizedAction === "channel-list" || normalizedAction === "thread-list") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const query = readStringParam(params, "query") ?? readStringParam(params, "q") ?? undefined
          const limit = Math.max(1, Math.min(200, readNumberParam(params, "limit", { integer: true }) ?? 50))
          const scope = (readStringParam(params, "scope") ?? readStringParam(params, "kind") ?? "all").toLowerCase()
          const result = await client.invokeRaw(Method.GET_CHATS, {
            oneofKind: "getChats",
            getChats: {},
          })
          if (result.oneofKind !== "getChats") {
            throw new Error(`inline action: expected getChats result, got ${String(result.oneofKind)}`)
          }

          const dialogByChatId = buildDialogMap(result.getChats.dialogs ?? [])
          const usersById = buildUserMap(result.getChats.users ?? [])
          const chats = (result.getChats.chats ?? []).map((chat) => mapChatEntry({ chat, dialogByChatId, usersById }))
          const groups = chats.filter((entry) => entry.peer?.kind !== "user")
          const peers = (result.getChats.users ?? []).map((user) => mapUserPeerEntry(user))

          const normalizedQuery = normalizeInlineListQuery(query)
          const filteredChats = chats.filter((entry) =>
            matchesInlineListQuery(
              [entry.id, entry.target, entry.title, entry.peer?.kind === "user" ? entry.peer.username ?? "" : "", entry.peer?.kind === "user" ? entry.peer.name ?? "" : ""].join(
                "\n",
              ),
              normalizedQuery,
            ),
          )
          const filteredGroups = groups.filter((entry) =>
            matchesInlineListQuery([entry.id, entry.target, entry.title].join("\n"), normalizedQuery),
          )
          const filteredPeers = peers.filter((entry) =>
            matchesInlineListQuery([entry.id, entry.target, entry.username ?? "", entry.name ?? ""].join("\n"), normalizedQuery),
          )

          return jsonResult(
            toJsonSafe({
              ok: true,
              scope,
              query: query ?? null,
              count: filteredChats.length,
              groupsCount: filteredGroups.length,
              peersCount: filteredPeers.length,
              chats:
                scope === "groups" || scope === "group" || scope === "channels" || scope === "channel"
                  ? []
                  : scope === "peers" || scope === "peer" || scope === "members" || scope === "member" || scope === "users" || scope === "user"
                    ? []
                    : filteredChats.slice(0, limit),
              groups:
                scope === "peers" || scope === "peer" || scope === "members" || scope === "member" || scope === "users" || scope === "user"
                  ? []
                  : filteredGroups.slice(0, limit),
              peers:
                scope === "groups" || scope === "group" || scope === "channels" || scope === "channel"
                  ? []
                  : filteredPeers.slice(0, limit),
            }),
          )
        },
      })
    }

    if (normalizedAction === "channel-create" || normalizedAction === "thread-create") {
      const isThreadCreate = normalizedAction === "thread-create"
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client, account) => {
          const title = requireVisibleActionText(
            readStringParam(params, "title") ??
              readStringParam(params, "name") ??
              readStringParam(params, "threadName") ??
              readStringParam(params, "message", { required: true }),
            "title",
          )
          const description = optionalVisibleActionText(readStringParam(params, "description"), "description")
          const emoji = readStringParam(params, "emoji")
          const spaceId = parseOptionalInlineId(
            readOptionalInlineIdParam(params, ["spaceId", "space"]),
            "spaceId",
          )
          const participantRefs = parseInlineListValuesFromParams(
            params,
            [
              "participants",
              "participantIds",
              "participantId",
              "participant",
              "userIds",
              "userId",
            ],
          ).filter((value) => normalizeOptionalInlineId(value) != null)
          const dedupedParticipants = await resolveInlineUserIdsFromParams({
            client,
            values: participantRefs,
            label: "participant",
          })
          const explicitIsPublic = readBooleanParam(params, "isPublic")
          const explicitParentMessageId = isThreadCreate ? resolveThreadParentMessageIdFromArgs(params) : undefined
          const hasTopLevelThreadIntent =
            isThreadCreate &&
            (explicitIsPublic === true ||
              (spaceId != null && explicitParentMessageId == null) ||
              (dedupedParticipants.length > 0 && !(spaceId != null && explicitParentMessageId != null)))
          const explicitParentChatId =
            isThreadCreate && !hasTopLevelThreadIntent ? resolveOptionalChatIdFromParams(params) : undefined
          const contextParentChatId =
            isThreadCreate &&
            !hasTopLevelThreadIntent &&
            explicitParentChatId == null &&
            explicitParentMessageId != null
              ? resolveToolContextChatId(
                  toolContext != null
                    ? { currentChannelId: toolContext.currentChannelId }
                    : undefined,
                )
              : undefined
          const parentChatId = explicitParentChatId ?? contextParentChatId
          const isPublic =
            explicitIsPublic ??
            (isThreadCreate && parentChatId == null && spaceId != null && dedupedParticipants.length === 0)

          if (
            isThreadCreate &&
            !hasTopLevelThreadIntent &&
            explicitParentMessageId != null &&
            parentChatId == null
          ) {
            throw new Error(
              "inline action: thread-create with parentMessageId/messageId requires to/chatId/channelId or current channel context",
            )
          }

          if (isThreadCreate && parentChatId != null) {
            const parentMessageId = parseOptionalInlineId(
              explicitParentMessageId ??
                (explicitParentChatId != null
                  ? resolveThreadParentMessageId({
                      args: params,
                      ...(toolContext != null
                        ? { toolContext: { currentMessageId: toolContext.currentMessageId } }
                        : {}),
                    })
                  : undefined),
              "parentMessageId",
            )

            const result = await client.invokeRaw(CREATE_SUBTHREAD_METHOD, {
              oneofKind: "createSubthread",
              createSubthread: {
                parentChatId,
                ...(parentMessageId != null ? { parentMessageId } : {}),
                title,
                ...(description ? { description } : {}),
                ...(emoji ? { emoji } : {}),
                participants: dedupedParticipants.map((userId) => ({ userId })),
              },
            })
            if (result.oneofKind !== "createSubthread") {
              throw new Error(
                `inline action: expected createSubthread result, got ${String(result.oneofKind)}`,
              )
            }
            const createdChat = result.createSubthread.chat ?? null
            if (createdChat?.id != null) {
              const routeParentMessageId = createdChat.parentMessageId ?? parentMessageId
              rememberInlineReplyThreadRoute({
                accountId: account.accountId,
                parentChatId: createdChat.parentChatId ?? parentChatId,
                threadId: createdChat.id,
                title: createdChat.title ?? title,
                ...(actionAgentId ? { agentId: actionAgentId } : {}),
                ...(routeParentMessageId != null ? { parentMessageId: routeParentMessageId } : {}),
              })
            }
            return jsonResult(
              toJsonSafe({
                ok: true,
                mode: "reply-thread",
                title,
                parentChatId: String(parentChatId),
                parentMessageId: parentMessageId != null ? String(parentMessageId) : null,
                participants: dedupedParticipants.map((id) => String(id)),
                chat: createdChat,
                dialog: result.createSubthread.dialog ?? null,
                anchorMessage: result.createSubthread.anchorMessage ?? null,
              }),
            )
          }

          if (isThreadCreate && isPublic && spaceId == null) {
            throw new Error("inline action: public thread-create requires spaceId")
          }
          if (isThreadCreate && !isPublic && dedupedParticipants.length === 0) {
            throw new Error(
              "inline action: private thread-create requires participant/participants or a parent chat target",
            )
          }

          const result = await client.invokeRaw(Method.CREATE_CHAT, {
            oneofKind: "createChat",
            createChat: {
              title,
              ...(spaceId != null ? { spaceId } : {}),
              ...(description ? { description } : {}),
              ...(emoji ? { emoji } : {}),
              isPublic,
              participants: isPublic ? [] : dedupedParticipants.map((userId) => ({ userId })),
            },
          })
          if (result.oneofKind !== "createChat") {
            throw new Error(`inline action: expected createChat result, got ${String(result.oneofKind)}`)
          }
          return jsonResult(
            toJsonSafe({
              ok: true,
              ...(isThreadCreate ? { mode: "top-level" } : {}),
              title,
              spaceId: spaceId != null ? String(spaceId) : null,
              isPublic,
              participants: dedupedParticipants.map((id) => String(id)),
              chat: result.createChat.chat ?? null,
              dialog: result.createChat.dialog ?? null,
            }),
          )
        },
      })
    }

    if (normalizedAction === "channel-delete") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const result = await client.invokeRaw(Method.DELETE_CHAT, {
            oneofKind: "deleteChat",
            deleteChat: {
              peerId: buildChatPeer(chatId),
            },
          })
          if (result.oneofKind !== "deleteChat") {
            throw new Error(`inline action: expected deleteChat result, got ${String(result.oneofKind)}`)
          }
          return jsonResult({
            ok: true,
            chatId: String(chatId),
          })
        },
      })
    }

    if (normalizedAction === "channel-move") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const rawSpace = readStringParam(params, "spaceId") ?? readStringParam(params, "toSpaceId")
          const normalizedSpace = rawSpace?.trim().toLowerCase()
          const moveToHome =
            normalizedSpace === "" ||
            normalizedSpace === "home" ||
            normalizedSpace === "none" ||
            normalizedSpace === "null"
          const parsedSpace = moveToHome
            ? undefined
            : parseOptionalInlineId(
                readFlexibleId(params, "spaceId") ?? readFlexibleId(params, "toSpaceId"),
                "spaceId",
              )
          const result = await client.invokeRaw(Method.MOVE_THREAD, {
            oneofKind: "moveThread",
            moveThread: {
              chatId,
              ...(parsedSpace != null ? { spaceId: parsedSpace } : {}),
            },
          })
          if (result.oneofKind !== "moveThread") {
            throw new Error(`inline action: expected moveThread result, got ${String(result.oneofKind)}`)
          }
          return jsonResult(
            toJsonSafe({
              ok: true,
              chatId: String(chatId),
              spaceId: parsedSpace != null ? String(parsedSpace) : null,
              chat: result.moveThread.chat ?? null,
            }),
          )
        },
      })
    }

    if (normalizedAction === "invite-to-space" || normalizedAction === "inviteToSpace") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const spaceId = await resolveSpaceIdFromParams({
            client,
            action: "invite-to-space",
            rawParams: params,
          })
          const role = resolveInlineSpaceInviteRole(params)
          const via = await resolveInlineSpaceInviteVia({
            client,
            rawParams: params,
          })
          const result = await client.invokeRaw(INVITE_TO_SPACE_METHOD, {
            oneofKind: "inviteToSpace",
            inviteToSpace: {
              spaceId,
              role,
              via,
            },
          })
          if (result.oneofKind !== "inviteToSpace") {
            throw new Error(
              `inline action: expected inviteToSpace result, got ${String(result.oneofKind)}`,
            )
          }

          return jsonResult(
            toJsonSafe({
              ok: true,
              spaceId: String(spaceId),
              role: role.role.oneofKind,
              canAccessPublicChats:
                role.role.oneofKind === "member" ? role.role.member.canAccessPublicChats : null,
              invite: summarizeInlineSpaceInviteVia(via),
              user: result.inviteToSpace.user ?? null,
              member: result.inviteToSpace.member ?? null,
              chat: result.inviteToSpace.chat ?? null,
              dialog: result.inviteToSpace.dialog ?? null,
            }),
          )
        },
      })
    }

    if (normalizedAction === "addParticipant") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const participantRefs = parseInlineListValuesFromParams(params, [
            "userId",
            "participant",
            "participantId",
            "memberId",
          ])
          if (participantRefs.length === 0) {
            readStringParam(params, "userId", { required: true })
          }
          const participantIds = await resolveInlineUserIdsFromParams({
            client,
            values: participantRefs,
            label: "user",
          })
          if (participantIds.length === 0) {
            throw new Error("inline action: missing user")
          }
          if (participantIds.length > 1) {
            throw new Error("inline action: addParticipant accepts exactly one user")
          }
          const userId = participantIds[0]
          if (!userId) {
            throw new Error("inline action: missing user")
          }
          const result = await client.invokeRaw(Method.ADD_CHAT_PARTICIPANT, {
            oneofKind: "addChatParticipant",
            addChatParticipant: {
              chatId,
              userId,
            },
          })
          if (result.oneofKind !== "addChatParticipant") {
            throw new Error(
              `inline action: expected addChatParticipant result, got ${String(result.oneofKind)}`,
            )
          }
          return jsonResult(
            toJsonSafe({
              ok: true,
              chatId: String(chatId),
              userId: String(userId),
              participant: result.addChatParticipant.participant ?? null,
            }),
          )
        },
      })
    }

    if (normalizedAction === "removeParticipant" || normalizedAction === "kick") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const participantRefs = parseInlineListValuesFromParams(params, [
            "userId",
            "participant",
            "participantId",
            "memberId",
          ])
          if (participantRefs.length === 0) {
            readStringParam(params, "userId", { required: true })
          }
          const participantIds = await resolveInlineUserIdsFromParams({
            client,
            values: participantRefs,
            label: "user",
          })
          if (participantIds.length === 0) {
            throw new Error("inline action: missing user")
          }
          if (participantIds.length > 1) {
            throw new Error("inline action: removeParticipant accepts exactly one user")
          }
          const userId = participantIds[0]
          if (!userId) {
            throw new Error("inline action: missing user")
          }
          const result = await client.invokeRaw(Method.REMOVE_CHAT_PARTICIPANT, {
            oneofKind: "removeChatParticipant",
            removeChatParticipant: {
              chatId,
              userId,
            },
          })
          if (result.oneofKind !== "removeChatParticipant") {
            throw new Error(
              `inline action: expected removeChatParticipant result, got ${String(result.oneofKind)}`,
            )
          }
          return jsonResult({
            ok: true,
            chatId: String(chatId),
            userId: String(userId),
          })
        },
      })
    }

    if (normalizedAction === "leaveGroup") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const me = await client.getMe()
          const userId = me.userId
          const result = await client.invokeRaw(Method.REMOVE_CHAT_PARTICIPANT, {
            oneofKind: "removeChatParticipant",
            removeChatParticipant: {
              chatId,
              userId,
            },
          })
          if (result.oneofKind !== "removeChatParticipant") {
            throw new Error(
              `inline action: expected removeChatParticipant result, got ${String(result.oneofKind)}`,
            )
          }
          return jsonResult({
            ok: true,
            chatId: String(chatId),
            userId: String(userId),
            left: true,
          })
        },
      })
    }

    if (normalizedAction === "member-info") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const userId = parseInlineId(
            readFlexibleId(params, "userId") ??
              readStringParam(params, "userId", { required: true }),
            "userId",
          )
          const result = await client.invokeRaw(Method.GET_CHAT_PARTICIPANTS, {
            oneofKind: "getChatParticipants",
            getChatParticipants: { chatId },
          })
          if (result.oneofKind !== "getChatParticipants") {
            throw new Error(
              `inline action: expected getChatParticipants result, got ${String(result.oneofKind)}`,
            )
          }
          const user =
            (result.getChatParticipants.users ?? []).find((candidate) => candidate.id === userId) ?? null
          const participant =
            (result.getChatParticipants.participants ?? []).find(
              (candidate) => candidate.userId === userId,
            ) ?? null
          return jsonResult(
            toJsonSafe({
              ok: true,
              chatId: String(chatId),
              userId: String(userId),
              user,
              participant,
            }),
          )
        },
      })
    }

    if (normalizedAction === "delete-attachment" || normalizedAction === "deleteMessageAttachment") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const messageId = parseInlineId(
            readFlexibleId(params, "messageId") ??
              readStringParam(params, "messageId", { required: true }),
            "messageId",
          )
          const attachmentId = parseInlineId(
            readFlexibleId(params, "attachmentId") ??
              readFlexibleId(params, "attachment") ??
              readStringParam(params, "attachmentId"),
            "attachmentId",
          )
          const result = await client.invokeRaw(DELETE_MESSAGE_ATTACHMENT_METHOD, {
            oneofKind: "deleteMessageAttachment",
            deleteMessageAttachment: {
              peerId: buildChatPeer(chatId),
              messageId,
              attachmentId,
            },
          })
          if (result.oneofKind !== "deleteMessageAttachment") {
            throw new Error(
              `inline action: expected deleteMessageAttachment result, got ${String(result.oneofKind)}`,
            )
          }
          return jsonResult({
            ok: true,
            chatId: String(chatId),
            messageId: String(messageId),
            attachmentId: String(attachmentId),
          })
        },
      })
    }

    if (normalizedAction === "delete" || normalizedAction === "unsend") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const messageIds = [
            ...parseInlineIdListFromParams(params, "messageIds"),
            ...parseInlineIdListFromParams(params, "messages"),
            ...parseInlineIdListFromParams(params, "ids"),
          ]
          if (messageIds.length === 0) {
            messageIds.push(
              parseInlineId(
                readFlexibleId(params, "messageId") ??
                  readStringParam(params, "messageId", { required: true }),
                "messageId",
              ),
            )
          }

          const deduped = Array.from(new Set(messageIds.map((id) => id.toString()))).map((id) => BigInt(id))

          const result = await client.invokeRaw(Method.DELETE_MESSAGES, {
            oneofKind: "deleteMessages",
            deleteMessages: {
              peerId: buildChatPeer(chatId),
              messageIds: deduped,
            },
          })
          if (result.oneofKind !== "deleteMessages") {
            throw new Error(
              `inline action: expected deleteMessages result, got ${String(result.oneofKind)}`,
            )
          }
          return jsonResult({
            ok: true,
            chatId: String(chatId),
            messageIds: deduped.map((id) => String(id)),
          })
        },
      })
    }

    if (normalizedAction === "pin" || normalizedAction === "unpin") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const target = resolveInlineCurrentChatTarget({
            args: params,
            toolContext,
            label: `inline action: ${normalizedAction}`,
          })
          const messageId = parseInlineId(
            resolveMessageIdFromParamsOrContext(
              toolContext != null
                ? { args: params, toolContext }
                : { args: params },
            ),
            "messageId",
          )
          const unpin =
            normalizedAction === "unpin" || readBooleanParam(params, "unpin") === true
          const result = await client.invokeRaw(Method.PIN_MESSAGE, {
            oneofKind: "pinMessage",
            pinMessage: {
              peerId: buildChatPeer(target.chatId),
              messageId,
              unpin,
            },
          })
          if (result.oneofKind !== "pinMessage") {
            throw new Error(`inline action: expected pinMessage result, got ${String(result.oneofKind)}`)
          }
          return jsonResult({
            ok: true,
            chatId: String(target.chatId),
            messageId: String(messageId),
            unpin,
            usedCurrentChatDefault: target.usedCurrentChatDefault,
            usedCurrentThreadDefault: target.usedCurrentThreadDefault,
          })
        },
      })
    }

    if (normalizedAction === "list-pins") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const target = resolveInlineCurrentChatTarget({
            args: params,
            toolContext,
            label: "inline action: list-pins",
          })
          const result = await client.invokeRaw(Method.GET_CHAT, {
            oneofKind: "getChat",
            getChat: { peerId: buildChatPeer(target.chatId) },
          })
          if (result.oneofKind !== "getChat") {
            throw new Error(`inline action: expected getChat result, got ${String(result.oneofKind)}`)
          }

          const pinnedMessageIds = (result.getChat.pinnedMessageIds ?? []).map((id) => String(id))
          return jsonResult({
            ok: true,
            chatId: String(target.chatId),
            pinnedMessageIds,
            usedCurrentChatDefault: target.usedCurrentChatDefault,
            usedCurrentThreadDefault: target.usedCurrentThreadDefault,
          })
        },
      })
    }

    if (normalizedAction === "permissions") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const spaceId = await resolveSpaceIdFromParams({
            client,
            action: "permissions",
            rawParams: params,
          })

          const userIdRaw =
            readFlexibleId(params, "userId") ??
            readFlexibleId(params, "memberId") ??
            readStringParam(params, "userId")
          const userId = userIdRaw ? parseInlineId(userIdRaw, "userId") : undefined
          const roleValue = readStringParam(params, "role")?.trim().toLowerCase()
          const canAccessPublicChats = readBooleanParam(params, "canAccessPublicChats")

          if (userId != null && roleValue) {
            const role =
              roleValue === "admin"
                ? { role: { oneofKind: "admin" as const, admin: {} } }
                : roleValue === "member"
                  ? {
                      role: {
                        oneofKind: "member" as const,
                        member: {
                          canAccessPublicChats: canAccessPublicChats ?? true,
                        },
                      },
                    }
                  : null
            if (!role) {
              throw new Error("inline action: role must be \"admin\" or \"member\"")
            }

            const updateResult = await client.invokeRaw(Method.UPDATE_MEMBER_ACCESS, {
              oneofKind: "updateMemberAccess",
              updateMemberAccess: {
                spaceId,
                userId,
                role,
              },
            })
            if (updateResult.oneofKind !== "updateMemberAccess") {
              throw new Error(
                `inline action: expected updateMemberAccess result, got ${String(updateResult.oneofKind)}`,
              )
            }
          }

          const members = await getSpaceMembersWithUsers({
            client,
            spaceId,
          })

          const filteredMembers =
            userId != null ? members.filter((member) => member.userId === String(userId)) : members

          return jsonResult(
            toJsonSafe({
              ok: true,
              chatId: String(chatId),
              spaceId: String(spaceId),
              members: filteredMembers,
            }),
          )
        },
      })
    }

    throw new Error(`Action ${action} is not supported for provider inline.`)
  },
} satisfies ChannelMessageActionAdapter & LegacyInlineMessageActionAdapter

export const inlineSupportedActions = listAllActions()
