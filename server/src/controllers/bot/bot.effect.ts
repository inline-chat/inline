import type {
  CreateReplyThreadParams,
  CreateThreadParams,
  CreateAgentParams,
  AnswerMessageActionParams,
  DeleteReactionParams,
  DeleteWebhookParams,
  DeleteMessageParams,
  EditMessageTextParams,
  GetChatHistoryParams,
  GetChatParticipantCountParams,
  GetChatParticipantParams,
  GetChatParams,
  GetFileParams,
  GetMessagesParams,
  GetUpdatesParams,
  GetAgentParams,
  ForwardMessageParams,
  PinMessageParams,
  SendMessageParams,
  SendReactionParams,
  SendChatActionParams,
  SearchMessagesParams,
  SetMyCommandsParams,
  SetThreadTitleParams,
  SetWebhookParams,
  UnpinMessageParams,
} from "@inline-chat/bot-api-types"
import type { UploadFileOperationInput } from "@in/server/methods/uploadFileOperation"
import * as BunFileSystem from "@effect/platform-bun/BunFileSystem"
import * as BunPath from "@effect/platform-bun/BunPath"
import {
  Cause,
  Data,
  Effect,
  Schema,
} from "effect"
import {
  HttpServerRequest,
  HttpServerResponse,
} from "effect/unstable/http"
import {
  HttpApiBuilder,
  HttpApiEndpoint,
  HttpApiGroup,
  OpenApi,
} from "effect/unstable/httpapi"
import { parseLegacyElysiaBody } from "../../core/http/legacyElysiaBody"
import { omitUndefinedObjectProperties } from "../../core/http/jsonResponseCompatibility"
import {
  BOT_API_ID,
  makeBotApiBase,
} from "../../core/http/openApi"
import { HttpRequestContext } from "../../core/http/requestContext"
import { defineHttpRouteGroup } from "../../core/http/routeGroup"
import {
  ErrorReporter,
  reportUnexpectedError,
} from "../../core/errors/errorReporter"
import { normalizeToken } from "@in/server/utils/auth"
import { recordApiError } from "@in/server/utils/metrics"
import {
  SessionAuthentication,
  SessionAuthenticationFailure,
  SessionAuthenticationRejected,
} from "../plugins.effect"
import {
  BotAuthorization,
  BotAuthorizationFailure,
  BotAuthorizationRejected,
  missingBotAuthentication,
} from "./auth.effect"
import {
  BotOperationFailure,
  BotOperations,
  BotPublicError,
  type BotOperation,
  type BotOperationContext,
  type BotOperationError,
} from "./operations.effect"
import {
  BotEmptySuccess,
  BotUploadFilePayload,
  BotEmptyRuntimeSuccess,
  BotGetChatHistorySuccess,
  BotGetChatHistoryRuntimeSuccess,
  BotGetChatSuccess,
  BotCreateThreadSuccess,
  BotGetMyCommandsSuccess,
  BotCreateAgentSuccess,
  BotGetAgentSuccess,
  BotGetMyAgentsSuccess,
  BotGetChatParticipantSuccess,
  BotGetChatParticipantCountSuccess,
  BotGetFileSuccess,
  BotGetUpdatesSuccess,
  BotWebhookInfoSuccess,
  BotTrueSuccess,
  BotMessageSuccess,
  BotMessageRuntimeSuccess,
  BotMessagesRuntimeSuccess,
  BotMessagesSuccess,
  CreateReplyThreadInput,
  CreateThreadInput,
  CreateAgentInput,
  AnswerMessageActionInput,
  DeleteReactionInput,
  DeleteWebhookInput,
  DeleteMessageInput,
  EditMessageTextInput,
  GetChatHistoryInput,
  GetChatInput,
  GetFileInput,
  GetMessagesInput,
  GetUpdatesInput,
  GetAgentInput,
  SearchMessagesInput,
  SendMessageInput,
  SendReactionInput,
  SendChatActionInput,
  SetWebhookInput,
  SetMyCommandsInput,
  ForwardMessageInput,
  PinMessageInput,
  GetChatParticipantInput,
  GetChatParticipantCountInput,
  SetThreadTitleInput,
  botTargetFieldDescriptions,
  botApiErrorAt,
  botApiErrors,
  getChatHistoryFieldDescriptions,
} from "./types.effect"
import { UploadFileInput as UploadFileRequestInput } from "../v1UploadSchemas.effect"
import { parseV1UploadRequest } from "../v1UploadRequest.effect"
import {
  BotGetMeSuccess,
} from "../../core/schema/bot"

const AuthorizationHeader = {
  authorization: Schema.optionalKey(Schema.String),
} as const

const TokenPath = {
  token: Schema.String,
} as const

const botOperationParameters = (options: {
  readonly authorizationHeader:
    | "required"
    | "optional-with-path-token"
  readonly optionalRequestBody?: boolean
  readonly queryDescriptions?: Readonly<
    Record<string, string>
  >
}) =>
  OpenApi.annotations({
    transform: (operation) => {
      if (
        options.optionalRequestBody &&
        operation["requestBody"] !== undefined
      ) {
        operation["requestBody"].required = false
      }
      for (const parameter of operation["parameters"] ?? []) {
        if (!("name" in parameter)) continue
        if (
          "in" in parameter &&
          parameter.in === "header" &&
          parameter.name.toLowerCase() === "authorization"
        ) {
          if (options.authorizationHeader === "required") {
            parameter.required = true
            parameter.description ??=
              "Required bot token using the Bearer scheme."
          } else {
            parameter.required = false
            parameter.description ??=
              "Optional bot token using the Bearer scheme. When supplied, it takes precedence over the token in the URL."
          }
        }
        if (
          "in" in parameter &&
          parameter.in === "query"
        ) {
          parameter.description ??=
            options.queryDescriptions?.[parameter.name] ??
            "Bot method parameter."
        }
        if (
          options.authorizationHeader ===
            "optional-with-path-token" &&
          "in" in parameter &&
          parameter.in === "path" &&
          parameter.name === "token"
        ) {
          parameter.description ??=
            "Required bot token included in the URL path."
        }
      }
      return operation
    },
  })

interface BotEndpointDocumentation {
  readonly summary: string
  readonly description: string
}

const BotMethodDocumentation = {
  getMe: {
    summary: "Get the current bot",
    description:
      "A simple method for testing bot authentication. Returns basic information about the bot account associated with the supplied token.",
  },
  sendMessage: {
    summary: "Send a message",
    description:
      "Sends a text message to a private user or chat. Supply exactly one of user_id or chat_id. On success, returns the sent message.",
  },
  getChat: {
    summary: "Get a chat",
    description:
      "Returns current information about a private conversation or chat, including its latest message when available. Supply exactly one of user_id or chat_id.",
  },
  getChatHistory: {
    summary: "Get chat history",
    description:
      "Returns a page of messages from a private conversation or chat. Supply exactly one of user_id or chat_id, and use offset_message_id to request older messages.",
  },
  getMessages: {
    summary: "Get exact messages",
    description: "Returns up to 100 requested messages from one accessible chat, in request order.",
  },
  searchMessages: {
    summary: "Search one chat",
    description: "Searches messages within exactly one accessible chat, newest first.",
  },
  createThread: {
    summary: "Create a thread",
    description: "Creates a normal home or space thread using Inline's existing access rules.",
  },
  createReplyThread: {
    summary: "Create a reply thread",
    description: "Creates or returns the reply thread anchored to one message.",
  },
  editMessageText: {
    summary: "Edit message text",
    description:
      "Replaces the text and formatting of a message in a private conversation or chat. On success, returns the updated message.",
  },
  deleteMessage: {
    summary: "Delete a message",
    description:
      "Deletes a message from a private conversation or chat. Returns an empty result when the message is deleted.",
  },
  sendReaction: {
    summary: "Send a reaction",
    description:
      "Adds the bot's emoji reaction to a message. Returns an empty result when the reaction is applied.",
  },
  deleteReaction: { summary: "Delete a reaction", description: "Removes the bot's emoji reaction from one message." },
  answerMessageAction: { summary: "Answer a message action", description: "Acknowledges an action interaction and optionally shows a short toast." },
  sendChatAction: { summary: "Send a chat action", description: "Publishes a short-lived typing or upload indicator." },
  getFile: { summary: "Get a file", description: "Returns metadata and a short-lived download URL for a bot-owned file." },
  getUpdates: { summary: "Get updates", description: "Long-polls the authenticated bot's durable ordered update stream." },
  setWebhook: { summary: "Set webhook", description: "Enables or replaces webhook delivery for the same durable update stream." },
  deleteWebhook: { summary: "Delete webhook", description: "Disables webhook delivery while preserving pending updates unless explicitly dropped." },
  getWebhookInfo: { summary: "Get webhook info", description: "Returns effective delivery settings and pending/error counters without exposing the secret." },
  getMyCommands: {
    summary: "Get bot commands",
    description:
      "Returns the command list currently published by the authenticated bot.",
  },
  createAgent: { summary: "Create an Agent", description: "Creates a named specialization owned by the authenticated bot. Skill and instructions are independently optional." },
  getAgent: { summary: "Get an Agent", description: "Returns one globally identified Agent and its backing bot." },
  getMyAgents: { summary: "List my Agents", description: "Returns Agents owned by the authenticated bot." },
  setMyCommands: {
    summary: "Replace bot commands",
    description:
      "Replaces the authenticated bot's complete command list. Commands appear to users in sort_order; send an empty array to clear the list.",
  },
  deleteMyCommands: {
    summary: "Delete bot commands",
    description:
      "Deletes every command published by the authenticated bot. Returns an empty result when the command list is cleared.",
  },
  forwardMessage: { summary: "Forward a message", description: "Forwards one accessible message into another accessible chat." },
  pinMessage: { summary: "Pin a message", description: "Pins one message in a chat." },
  unpinMessage: { summary: "Unpin a message", description: "Unpins one message in a chat." },
  getChatParticipant: { summary: "Get a chat participant", description: "Returns one participant of an accessible chat, with space membership when applicable." },
  getChatParticipantCount: { summary: "Get chat participant count", description: "Returns the number of participants in an accessible chat." },
  setThreadTitle: { summary: "Set thread title", description: "Changes the title of a thread. Direct-message chats are not threads and cannot be renamed." },
  uploadFile: { summary: "Upload a file", description: "Uploads bot media using multipart/form-data and returns a reusable bot file." },
} satisfies Readonly<
  Record<BotOperation, BotEndpointDocumentation>
>

const botEndpoint = (
  documentation: BotEndpointDocumentation,
) =>
  OpenApi.annotations({
    summary: documentation.summary,
    description: documentation.description,
  })

const headerGet = <
  const Identifier extends string,
  const Path extends `/${string}`,
  const Success extends Schema.Top,
  Query extends Schema.Struct.Fields,
>(
  identifier: Identifier,
  path: Path,
  documentation: BotEndpointDocumentation,
  options: {
    readonly success: Success
    readonly query: Query
    readonly queryDescriptions?: Readonly<
      Record<Extract<keyof Query, string>, string>
    >
  },
) =>
  HttpApiEndpoint.get(identifier, path, {
    headers: AuthorizationHeader,
    query: options.query,
    success: options.success,
    error: botApiErrors,
  }).annotateMerge(
    botEndpoint(documentation),
  ).annotateMerge(
    botOperationParameters({
      authorizationHeader: "required",
      queryDescriptions: options.queryDescriptions,
    }),
  )

const pathGet = <
  const Identifier extends string,
  const Path extends `/${string}`,
  const Success extends Schema.Top,
  Query extends Schema.Struct.Fields,
>(
  identifier: Identifier,
  path: Path,
  documentation: BotEndpointDocumentation,
  options: {
    readonly success: Success
    readonly query: Query
    readonly queryDescriptions?: Readonly<
      Record<Extract<keyof Query, string>, string>
    >
  },
) =>
  HttpApiEndpoint.get(identifier, path, {
    params: TokenPath,
    headers: AuthorizationHeader,
    query: options.query,
    success: options.success,
    error: botApiErrors,
  }).annotateMerge(
    botEndpoint(documentation),
  ).annotateMerge(
    botOperationParameters({
      authorizationHeader: "optional-with-path-token",
      queryDescriptions: options.queryDescriptions,
    }),
  )

const headerPost = <
  const Identifier extends string,
  const Path extends `/${string}`,
  const Success extends Schema.Top,
  Payload extends Schema.Top = never,
>(
  identifier: Identifier,
  path: Path,
  documentation: BotEndpointDocumentation,
  options: {
    readonly success: Success
    readonly payload?: Payload | undefined
  },
) =>
  HttpApiEndpoint.post(identifier, path, {
    headers: AuthorizationHeader,
    ...(options.payload === undefined
      ? {}
      : { payload: options.payload }),
    success: options.success,
    error: botApiErrors,
  }).annotateMerge(
    botEndpoint(documentation),
  ).annotateMerge(
    botOperationParameters({
      authorizationHeader: "required",
      optionalRequestBody: true,
    }),
  )

const pathPost = <
  const Identifier extends string,
  const Path extends `/${string}`,
  const Success extends Schema.Top,
  Payload extends Schema.Top = never,
>(
  identifier: Identifier,
  path: Path,
  documentation: BotEndpointDocumentation,
  options: {
    readonly success: Success
    readonly payload?: Payload | undefined
  },
) =>
  HttpApiEndpoint.post(identifier, path, {
    params: TokenPath,
    headers: AuthorizationHeader,
    ...(options.payload === undefined
      ? {}
      : { payload: options.payload }),
    success: options.success,
    error: botApiErrors,
  }).annotateMerge(
    botEndpoint(documentation),
  ).annotateMerge(
    botOperationParameters({
      authorizationHeader: "optional-with-path-token",
      optionalRequestBody: true,
    }),
  )

const HeaderBotEndpoints = {
  getMe: headerGet(
    "headerGetMe",
    "/bot/getMe",
    BotMethodDocumentation.getMe,
    {
      query: {},
      success: BotGetMeSuccess,
    },
  ),
  sendMessage: headerPost(
    "headerSendMessage",
    "/bot/sendMessage",
    BotMethodDocumentation.sendMessage,
    {
      payload: SendMessageInput,
      success: BotMessageSuccess,
    },
  ),
  getChat: headerGet(
    "headerGetChat",
    "/bot/getChat",
    BotMethodDocumentation.getChat,
    {
      query: GetChatInput.fields,
      queryDescriptions: botTargetFieldDescriptions,
      success: BotGetChatSuccess,
    },
  ),
  getChatHistory: headerGet(
    "headerGetChatHistory",
    "/bot/getChatHistory",
    BotMethodDocumentation.getChatHistory,
    {
      query: GetChatHistoryInput.fields,
      queryDescriptions:
        getChatHistoryFieldDescriptions,
      success: BotGetChatHistorySuccess,
    },
  ),
  getMessages: headerPost(
    "headerGetMessages",
    "/bot/getMessages",
    BotMethodDocumentation.getMessages,
    { payload: GetMessagesInput, success: BotMessagesSuccess },
  ),
  searchMessages: headerPost(
    "headerSearchMessages",
    "/bot/searchMessages",
    BotMethodDocumentation.searchMessages,
    { payload: SearchMessagesInput, success: BotMessagesSuccess },
  ),
  createThread: headerPost(
    "headerCreateThread",
    "/bot/createThread",
    BotMethodDocumentation.createThread,
    { payload: CreateThreadInput, success: BotCreateThreadSuccess },
  ),
  createReplyThread: headerPost(
    "headerCreateReplyThread",
    "/bot/createReplyThread",
    BotMethodDocumentation.createReplyThread,
    { payload: CreateReplyThreadInput, success: BotCreateThreadSuccess },
  ),
  editMessageText: headerPost(
    "headerEditMessageText",
    "/bot/editMessageText",
    BotMethodDocumentation.editMessageText,
    {
      payload: EditMessageTextInput,
      success: BotMessageSuccess,
    },
  ),
  deleteMessage: headerPost(
    "headerDeleteMessage",
    "/bot/deleteMessage",
    BotMethodDocumentation.deleteMessage,
    {
      payload: DeleteMessageInput,
      success: BotEmptySuccess,
    },
  ),
  sendReaction: headerPost(
    "headerSendReaction",
    "/bot/sendReaction",
    BotMethodDocumentation.sendReaction,
    {
      payload: SendReactionInput,
      success: BotEmptySuccess,
    },
  ),
  deleteReaction: headerPost("headerDeleteReaction", "/bot/deleteReaction", BotMethodDocumentation.deleteReaction, { payload: DeleteReactionInput, success: BotEmptySuccess }),
  answerMessageAction: headerPost("headerAnswerMessageAction", "/bot/answerMessageAction", BotMethodDocumentation.answerMessageAction, { payload: AnswerMessageActionInput, success: BotEmptySuccess }),
  sendChatAction: headerPost("headerSendChatAction", "/bot/sendChatAction", BotMethodDocumentation.sendChatAction, { payload: SendChatActionInput, success: BotEmptySuccess }),
  getFile: headerGet("headerGetFile", "/bot/getFile", BotMethodDocumentation.getFile, { query: GetFileInput.fields, success: BotGetFileSuccess }),
  getUpdates: headerGet("headerGetUpdates", "/bot/getUpdates", BotMethodDocumentation.getUpdates, { query: GetUpdatesInput.fields, success: BotGetUpdatesSuccess }),
  setWebhook: headerPost("headerSetWebhook", "/bot/setWebhook", BotMethodDocumentation.setWebhook, { payload: SetWebhookInput, success: BotTrueSuccess }),
  deleteWebhook: headerPost("headerDeleteWebhook", "/bot/deleteWebhook", BotMethodDocumentation.deleteWebhook, { payload: DeleteWebhookInput, success: BotTrueSuccess }),
  getWebhookInfo: headerGet("headerGetWebhookInfo", "/bot/getWebhookInfo", BotMethodDocumentation.getWebhookInfo, { query: {}, success: BotWebhookInfoSuccess }),
  getMyCommands: headerGet(
    "headerGetMyCommands",
    "/bot/getMyCommands",
    BotMethodDocumentation.getMyCommands,
    {
      query: {},
      success: BotGetMyCommandsSuccess,
    },
  ),
  createAgent: headerPost("headerCreateAgent", "/bot/createAgent", BotMethodDocumentation.createAgent, { payload: CreateAgentInput, success: BotCreateAgentSuccess }),
  getAgent: headerGet("headerGetAgent", "/bot/getAgent", BotMethodDocumentation.getAgent, { query: GetAgentInput.fields, success: BotGetAgentSuccess }),
  getMyAgents: headerGet("headerGetMyAgents", "/bot/getMyAgents", BotMethodDocumentation.getMyAgents, { query: {}, success: BotGetMyAgentsSuccess }),
  setMyCommands: headerPost(
    "headerSetMyCommands",
    "/bot/setMyCommands",
    BotMethodDocumentation.setMyCommands,
    {
      payload: SetMyCommandsInput,
      success: BotEmptySuccess,
    },
  ),
  deleteMyCommands: headerPost(
    "headerDeleteMyCommands",
    "/bot/deleteMyCommands",
    BotMethodDocumentation.deleteMyCommands,
    { success: BotEmptySuccess },
  ),
  forwardMessage: headerPost("headerForwardMessage", "/bot/forwardMessage", BotMethodDocumentation.forwardMessage, { payload: ForwardMessageInput, success: BotMessageSuccess }),
  pinMessage: headerPost("headerPinMessage", "/bot/pinMessage", BotMethodDocumentation.pinMessage, { payload: PinMessageInput, success: BotEmptySuccess }),
  unpinMessage: headerPost("headerUnpinMessage", "/bot/unpinMessage", BotMethodDocumentation.unpinMessage, { payload: PinMessageInput, success: BotEmptySuccess }),
  getChatParticipant: headerGet("headerGetChatParticipant", "/bot/getChatParticipant", BotMethodDocumentation.getChatParticipant, { query: GetChatParticipantInput.fields, success: BotGetChatParticipantSuccess }),
  getChatParticipantCount: headerGet("headerGetChatParticipantCount", "/bot/getChatParticipantCount", BotMethodDocumentation.getChatParticipantCount, { query: GetChatParticipantCountInput.fields, success: BotGetChatParticipantCountSuccess }),
  setThreadTitle: headerPost("headerSetThreadTitle", "/bot/setThreadTitle", BotMethodDocumentation.setThreadTitle, { payload: SetThreadTitleInput, success: BotEmptySuccess }),
  uploadFile: headerPost("headerUploadFile", "/bot/uploadFile", BotMethodDocumentation.uploadFile, { payload: BotUploadFilePayload, success: BotGetFileSuccess }),
} as const

const PathBotEndpoints = {
  getMe: pathGet(
    "pathGetMe",
    "/bot:token/getMe",
    BotMethodDocumentation.getMe,
    {
      query: {},
      success: BotGetMeSuccess,
    },
  ),
  sendMessage: pathPost(
    "pathSendMessage",
    "/bot:token/sendMessage",
    BotMethodDocumentation.sendMessage,
    {
      payload: SendMessageInput,
      success: BotMessageSuccess,
    },
  ),
  getChat: pathGet(
    "pathGetChat",
    "/bot:token/getChat",
    BotMethodDocumentation.getChat,
    {
      query: GetChatInput.fields,
      queryDescriptions: botTargetFieldDescriptions,
      success: BotGetChatSuccess,
    },
  ),
  getChatHistory: pathGet(
    "pathGetChatHistory",
    "/bot:token/getChatHistory",
    BotMethodDocumentation.getChatHistory,
    {
      query: GetChatHistoryInput.fields,
      queryDescriptions:
        getChatHistoryFieldDescriptions,
      success: BotGetChatHistorySuccess,
    },
  ),
  getMessages: pathPost(
    "pathGetMessages",
    "/bot:token/getMessages",
    BotMethodDocumentation.getMessages,
    { payload: GetMessagesInput, success: BotMessagesSuccess },
  ),
  searchMessages: pathPost(
    "pathSearchMessages",
    "/bot:token/searchMessages",
    BotMethodDocumentation.searchMessages,
    { payload: SearchMessagesInput, success: BotMessagesSuccess },
  ),
  createThread: pathPost(
    "pathCreateThread",
    "/bot:token/createThread",
    BotMethodDocumentation.createThread,
    { payload: CreateThreadInput, success: BotCreateThreadSuccess },
  ),
  createReplyThread: pathPost(
    "pathCreateReplyThread",
    "/bot:token/createReplyThread",
    BotMethodDocumentation.createReplyThread,
    { payload: CreateReplyThreadInput, success: BotCreateThreadSuccess },
  ),
  editMessageText: pathPost(
    "pathEditMessageText",
    "/bot:token/editMessageText",
    BotMethodDocumentation.editMessageText,
    {
      payload: EditMessageTextInput,
      success: BotMessageSuccess,
    },
  ),
  deleteMessage: pathPost(
    "pathDeleteMessage",
    "/bot:token/deleteMessage",
    BotMethodDocumentation.deleteMessage,
    {
      payload: DeleteMessageInput,
      success: BotEmptySuccess,
    },
  ),
  sendReaction: pathPost(
    "pathSendReaction",
    "/bot:token/sendReaction",
    BotMethodDocumentation.sendReaction,
    {
      payload: SendReactionInput,
      success: BotEmptySuccess,
    },
  ),
  deleteReaction: pathPost("pathDeleteReaction", "/bot:token/deleteReaction", BotMethodDocumentation.deleteReaction, { payload: DeleteReactionInput, success: BotEmptySuccess }),
  answerMessageAction: pathPost("pathAnswerMessageAction", "/bot:token/answerMessageAction", BotMethodDocumentation.answerMessageAction, { payload: AnswerMessageActionInput, success: BotEmptySuccess }),
  sendChatAction: pathPost("pathSendChatAction", "/bot:token/sendChatAction", BotMethodDocumentation.sendChatAction, { payload: SendChatActionInput, success: BotEmptySuccess }),
  getFile: pathGet("pathGetFile", "/bot:token/getFile", BotMethodDocumentation.getFile, { query: GetFileInput.fields, success: BotGetFileSuccess }),
  getUpdates: pathGet("pathGetUpdates", "/bot:token/getUpdates", BotMethodDocumentation.getUpdates, { query: GetUpdatesInput.fields, success: BotGetUpdatesSuccess }),
  setWebhook: pathPost("pathSetWebhook", "/bot:token/setWebhook", BotMethodDocumentation.setWebhook, { payload: SetWebhookInput, success: BotTrueSuccess }),
  deleteWebhook: pathPost("pathDeleteWebhook", "/bot:token/deleteWebhook", BotMethodDocumentation.deleteWebhook, { payload: DeleteWebhookInput, success: BotTrueSuccess }),
  getWebhookInfo: pathGet("pathGetWebhookInfo", "/bot:token/getWebhookInfo", BotMethodDocumentation.getWebhookInfo, { query: {}, success: BotWebhookInfoSuccess }),
  getMyCommands: pathGet(
    "pathGetMyCommands",
    "/bot:token/getMyCommands",
    BotMethodDocumentation.getMyCommands,
    {
      query: {},
      success: BotGetMyCommandsSuccess,
    },
  ),
  createAgent: pathPost("pathCreateAgent", "/bot:token/createAgent", BotMethodDocumentation.createAgent, { payload: CreateAgentInput, success: BotCreateAgentSuccess }),
  getAgent: pathGet("pathGetAgent", "/bot:token/getAgent", BotMethodDocumentation.getAgent, { query: GetAgentInput.fields, success: BotGetAgentSuccess }),
  getMyAgents: pathGet("pathGetMyAgents", "/bot:token/getMyAgents", BotMethodDocumentation.getMyAgents, { query: {}, success: BotGetMyAgentsSuccess }),
  setMyCommands: pathPost(
    "pathSetMyCommands",
    "/bot:token/setMyCommands",
    BotMethodDocumentation.setMyCommands,
    {
      payload: SetMyCommandsInput,
      success: BotEmptySuccess,
    },
  ),
  deleteMyCommands: pathPost(
    "pathDeleteMyCommands",
    "/bot:token/deleteMyCommands",
    BotMethodDocumentation.deleteMyCommands,
    { success: BotEmptySuccess },
  ),
  forwardMessage: pathPost("pathForwardMessage", "/bot:token/forwardMessage", BotMethodDocumentation.forwardMessage, { payload: ForwardMessageInput, success: BotMessageSuccess }),
  pinMessage: pathPost("pathPinMessage", "/bot:token/pinMessage", BotMethodDocumentation.pinMessage, { payload: PinMessageInput, success: BotEmptySuccess }),
  unpinMessage: pathPost("pathUnpinMessage", "/bot:token/unpinMessage", BotMethodDocumentation.unpinMessage, { payload: PinMessageInput, success: BotEmptySuccess }),
  getChatParticipant: pathGet("pathGetChatParticipant", "/bot:token/getChatParticipant", BotMethodDocumentation.getChatParticipant, { query: GetChatParticipantInput.fields, success: BotGetChatParticipantSuccess }),
  getChatParticipantCount: pathGet("pathGetChatParticipantCount", "/bot:token/getChatParticipantCount", BotMethodDocumentation.getChatParticipantCount, { query: GetChatParticipantCountInput.fields, success: BotGetChatParticipantCountSuccess }),
  setThreadTitle: pathPost("pathSetThreadTitle", "/bot:token/setThreadTitle", BotMethodDocumentation.setThreadTitle, { payload: SetThreadTitleInput, success: BotEmptySuccess }),
  uploadFile: pathPost("pathUploadFile", "/bot:token/uploadFile", BotMethodDocumentation.uploadFile, { payload: BotUploadFilePayload, success: BotGetFileSuccess }),
} as const

const BotMethodNotFound =
  botApiErrorAt(
    404,
    "BotMethodNotFound",
    "The requested Bot API method was not found.",
    {
      ok: false,
      error: "METHOD_NOT_FOUND",
      error_code: 404,
      description: "Method not found",
    },
  )

const hiddenFallback = OpenApi.annotations({
  exclude: true,
})

const HeaderFallbackEndpoints = {
  get: HttpApiEndpoint.get(
    "headerFallbackGet",
    "/bot/*",
    {
      headers: AuthorizationHeader,
      success: BotMethodNotFound,
    },
  ).annotateMerge(hiddenFallback),
  post: HttpApiEndpoint.post(
    "headerFallbackPost",
    "/bot/*",
    {
      headers: AuthorizationHeader,
      success: BotMethodNotFound,
    },
  ).annotateMerge(hiddenFallback),
  put: HttpApiEndpoint.put(
    "headerFallbackPut",
    "/bot/*",
    {
      headers: AuthorizationHeader,
      success: BotMethodNotFound,
    },
  ).annotateMerge(hiddenFallback),
  delete: HttpApiEndpoint.delete(
    "headerFallbackDelete",
    "/bot/*",
    {
      headers: AuthorizationHeader,
      success: BotMethodNotFound,
    },
  ).annotateMerge(hiddenFallback),
  patch: HttpApiEndpoint.patch(
    "headerFallbackPatch",
    "/bot/*",
    {
      headers: AuthorizationHeader,
      success: BotMethodNotFound,
    },
  ).annotateMerge(hiddenFallback),
  head: HttpApiEndpoint.head(
    "headerFallbackHead",
    "/bot/*",
    {
      headers: AuthorizationHeader,
      success: BotMethodNotFound,
    },
  ).annotateMerge(hiddenFallback),
  options: HttpApiEndpoint.options(
    "headerFallbackOptions",
    "/bot/*",
    {
      headers: AuthorizationHeader,
      success: BotMethodNotFound,
    },
  ).annotateMerge(hiddenFallback),
  trace: HttpApiEndpoint.make("TRACE")(
    "headerFallbackTrace",
    "/bot/*",
    {
      headers: AuthorizationHeader,
      success: BotMethodNotFound,
    },
  ).annotateMerge(hiddenFallback),
} as const

const PathFallbackEndpoints = {
  get: HttpApiEndpoint.get(
    "pathFallbackGet",
    "/bot:token/*",
    {
      params: TokenPath,
      headers: AuthorizationHeader,
      success: BotMethodNotFound,
    },
  ).annotateMerge(hiddenFallback),
  post: HttpApiEndpoint.post(
    "pathFallbackPost",
    "/bot:token/*",
    {
      params: TokenPath,
      headers: AuthorizationHeader,
      success: BotMethodNotFound,
    },
  ).annotateMerge(hiddenFallback),
  put: HttpApiEndpoint.put(
    "pathFallbackPut",
    "/bot:token/*",
    {
      params: TokenPath,
      headers: AuthorizationHeader,
      success: BotMethodNotFound,
    },
  ).annotateMerge(hiddenFallback),
  delete: HttpApiEndpoint.delete(
    "pathFallbackDelete",
    "/bot:token/*",
    {
      params: TokenPath,
      headers: AuthorizationHeader,
      success: BotMethodNotFound,
    },
  ).annotateMerge(hiddenFallback),
  patch: HttpApiEndpoint.patch(
    "pathFallbackPatch",
    "/bot:token/*",
    {
      params: TokenPath,
      headers: AuthorizationHeader,
      success: BotMethodNotFound,
    },
  ).annotateMerge(hiddenFallback),
  head: HttpApiEndpoint.head(
    "pathFallbackHead",
    "/bot:token/*",
    {
      params: TokenPath,
      headers: AuthorizationHeader,
      success: BotMethodNotFound,
    },
  ).annotateMerge(hiddenFallback),
  options: HttpApiEndpoint.options(
    "pathFallbackOptions",
    "/bot:token/*",
    {
      params: TokenPath,
      headers: AuthorizationHeader,
      success: BotMethodNotFound,
    },
  ).annotateMerge(hiddenFallback),
  trace: HttpApiEndpoint.make("TRACE")(
    "pathFallbackTrace",
    "/bot:token/*",
    {
      params: TokenPath,
      headers: AuthorizationHeader,
      success: BotMethodNotFound,
    },
  ).annotateMerge(hiddenFallback),
} as const

export const BotApiGroup = HttpApiGroup.make("bot")
  .add(
    HeaderBotEndpoints.getMe,
    HeaderBotEndpoints.sendMessage,
    HeaderBotEndpoints.getChat,
    HeaderBotEndpoints.getChatHistory,
    HeaderBotEndpoints.getMessages,
    HeaderBotEndpoints.searchMessages,
    HeaderBotEndpoints.createThread,
    HeaderBotEndpoints.createReplyThread,
    HeaderBotEndpoints.editMessageText,
    HeaderBotEndpoints.deleteMessage,
    HeaderBotEndpoints.sendReaction,
    HeaderBotEndpoints.deleteReaction,
    HeaderBotEndpoints.answerMessageAction,
    HeaderBotEndpoints.sendChatAction,
    HeaderBotEndpoints.getFile,
    HeaderBotEndpoints.getUpdates,
    HeaderBotEndpoints.setWebhook,
    HeaderBotEndpoints.deleteWebhook,
    HeaderBotEndpoints.getWebhookInfo,
    HeaderBotEndpoints.getMyCommands,
    HeaderBotEndpoints.createAgent,
    HeaderBotEndpoints.getAgent,
    HeaderBotEndpoints.getMyAgents,
    HeaderBotEndpoints.setMyCommands,
    HeaderBotEndpoints.deleteMyCommands,
    HeaderBotEndpoints.forwardMessage,
    HeaderBotEndpoints.pinMessage,
    HeaderBotEndpoints.unpinMessage,
    HeaderBotEndpoints.getChatParticipant,
    HeaderBotEndpoints.getChatParticipantCount,
    HeaderBotEndpoints.setThreadTitle,
    HeaderBotEndpoints.uploadFile,
    PathBotEndpoints.getMe,
    PathBotEndpoints.sendMessage,
    PathBotEndpoints.getChat,
    PathBotEndpoints.getChatHistory,
    PathBotEndpoints.getMessages,
    PathBotEndpoints.searchMessages,
    PathBotEndpoints.createThread,
    PathBotEndpoints.createReplyThread,
    PathBotEndpoints.editMessageText,
    PathBotEndpoints.deleteMessage,
    PathBotEndpoints.sendReaction,
    PathBotEndpoints.deleteReaction,
    PathBotEndpoints.answerMessageAction,
    PathBotEndpoints.sendChatAction,
    PathBotEndpoints.getFile,
    PathBotEndpoints.getUpdates,
    PathBotEndpoints.setWebhook,
    PathBotEndpoints.deleteWebhook,
    PathBotEndpoints.getWebhookInfo,
    PathBotEndpoints.getMyCommands,
    PathBotEndpoints.createAgent,
    PathBotEndpoints.getAgent,
    PathBotEndpoints.getMyAgents,
    PathBotEndpoints.setMyCommands,
    PathBotEndpoints.deleteMyCommands,
    PathBotEndpoints.forwardMessage,
    PathBotEndpoints.pinMessage,
    PathBotEndpoints.unpinMessage,
    PathBotEndpoints.getChatParticipant,
    PathBotEndpoints.getChatParticipantCount,
    PathBotEndpoints.setThreadTitle,
    PathBotEndpoints.uploadFile,
    HeaderFallbackEndpoints.get,
    HeaderFallbackEndpoints.post,
    HeaderFallbackEndpoints.put,
    HeaderFallbackEndpoints.delete,
    HeaderFallbackEndpoints.patch,
    HeaderFallbackEndpoints.head,
    HeaderFallbackEndpoints.options,
    HeaderFallbackEndpoints.trace,
    PathFallbackEndpoints.get,
    PathFallbackEndpoints.post,
    PathFallbackEndpoints.put,
    PathFallbackEndpoints.delete,
    PathFallbackEndpoints.patch,
    PathFallbackEndpoints.head,
    PathFallbackEndpoints.options,
    PathFallbackEndpoints.trace,
  )
  .annotateMerge(
    OpenApi.annotations({
      title: "Bot",
      description: "Inline Bot HTTP API methods.",
    }),
  )

const json = (
  status: number,
  body: unknown,
): HttpServerResponse.HttpServerResponse =>
  HttpServerResponse.jsonUnsafe(body, { status })

const noteApiError = Effect.sync(() => {
  try {
    recordApiError()
  } catch {
    // Metrics must not replace the response being emitted.
  }
})

const publicErrorResponse = (error: {
  readonly error: string
  readonly errorCode: number
  readonly description: string | undefined
}) =>
  json(error.errorCode, {
    ok: false,
    error: error.error,
    error_code: error.errorCode,
    description: error.description ?? "Unauthorized",
  })

const invalidArgsResponse = () =>
  json(400, {
    ok: false,
    error: "INVALID_ARGS",
    error_code: 400,
    description: "Validation error",
  })

const internalOperationResponse = () =>
  json(500, {
    ok: false,
    error: "INTERNAL",
    error_code: 500,
    description: "Internal server error happened",
  })

const serverErrorResponse = () =>
  json(500, {
    ok: false,
    error: "SERVER_ERROR",
    error_code: 500,
    description: "Server error",
  })

const reportCause = (
  operation: string,
  cause: Cause.Cause<unknown>,
) =>
  HttpRequestContext.use((context) =>
    reportUnexpectedError({
      cause,
      context: {
        operation,
        requestId: context.requestId,
      },
    }),
  )

const normalizePathToken = (
  token: string,
): string | null => {
  try {
    const decoded = decodeURIComponent(token)
    const normalized = normalizeToken(decoded)
    if (normalized) return normalized
  } catch {
    // Preserve the raw-token fallback for malformed percent sequences.
  }
  return normalizeToken(token)
}

const recordFromSearchParams = (
  params: URLSearchParams,
): Record<string, unknown> => {
  const result: Record<string, unknown> = {}
  for (const [key, value] of params) {
    result[key] = value
  }
  return result
}

const isRecord = (
  value: unknown,
): value is Record<string, unknown> =>
  typeof value === "object" &&
  value !== null &&
  !Array.isArray(value)

class InvalidBotPayload extends Data.TaggedError(
  "InvalidBotPayload",
)<{
  readonly reason: "parse" | "schema"
}> {}

// TODO(effect-cutover): delete this query-string JSON coercion after supported
// Bot clients use the documented JSON request body and telemetry confirms the
// compatibility form has had no production use for 30 days.
const parseCompatibilityJson = (
  value: unknown,
): unknown => {
  if (typeof value !== "string") {
    return value
  }
  const trimmed = value.trim()
  if (
    !trimmed.startsWith("[") &&
    !trimmed.startsWith("{")
  ) {
    return value
  }
  return JSON.parse(trimmed)
}

const integerForValidation = (
  value: unknown,
): unknown => {
  if (
    typeof value !== "string" ||
    !/^[+-]?\d+$/.test(value.trim())
  ) {
    return value
  }
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) ? parsed : value
}

const normalizeIntegerFields = (
  value: Record<string, unknown>,
  fields: ReadonlyArray<string>,
): Record<string, unknown> => {
  const normalized = { ...value }
  for (const field of fields) {
    if (field in normalized) {
      normalized[field] = integerForValidation(
        normalized[field],
      )
    }
  }
  return normalized
}

const normalizeBotEntityForSchema = (
  value: unknown,
): unknown =>
  isRecord(value)
    ? normalizeIntegerFields(value, [
        "offset",
        "length",
        "user_id",
        "chat_id",
        "space_id",
      ])
    : value

const normalizeBotCommandForSchema = (
  value: unknown,
): unknown => {
  if (!isRecord(value)) return value
  const normalized = normalizeIntegerFields(value, [
    "sort_order",
  ])
  for (const field of ["command", "description"] as const) {
    if (typeof normalized[field] === "string") {
      normalized[field] = normalized[field].trim()
    }
  }
  return normalized
}

const booleanForValidation = (
  value: unknown,
): unknown => {
  if (typeof value !== "string") {
    return value
  }
  switch (value.trim().toLowerCase()) {
    case "true":
    case "1":
      return true
    case "false":
    case "0":
      return false
    default:
      return value
  }
}

const normalizeInputForSchema = (
  operation: BotOperation,
  input: Record<string, unknown>,
): Record<string, unknown> => {
  // TODO(effect-cutover): remove decimal-string POST coercion after supported
  // Bot clients use canonical numeric IDs and compatibility telemetry is quiet.
  const usesQueryIdCodecs =
    operation === "getChat" ||
    operation === "getChatHistory" ||
    operation === "getUpdates" ||
    operation === "getChatParticipant" ||
    operation === "getChatParticipantCount"
  const normalized = usesQueryIdCodecs
    ? { ...input }
    : normalizeIntegerFields(input, [
        "user_id",
        "chat_id",
        "from_chat_id",
        "message_id",
        "reply_to_message_id",
        "interaction_id",
      ])
  if (
    operation === "sendMessage" ||
    operation === "editMessageText"
  ) {
    if ("entities" in normalized) {
      const entities = parseCompatibilityJson(
        normalized["entities"],
      )
      normalized["entities"] = Array.isArray(entities)
        ? entities.map(normalizeBotEntityForSchema)
        : entities
    }
    const parseMarkdown =
      normalized["parse_markdown"] ??
      normalized["parseMarkdown"]
    if (parseMarkdown !== undefined) {
      normalized["parse_markdown"] =
        booleanForValidation(parseMarkdown)
    }
  }
  if (operation === "getMessages") {
    const ids = parseCompatibilityJson(normalized["message_ids"])
    normalized["message_ids"] = Array.isArray(ids)
      ? ids.map(integerForValidation)
      : ids
  }
  if (operation === "searchMessages") {
    if ("offset_message_id" in normalized) {
      normalized["offset_message_id"] = integerForValidation(
        normalized["offset_message_id"],
      )
    }
  }
  if (operation === "createThread" || operation === "createReplyThread") {
    if ("participant_ids" in normalized) {
      const ids = parseCompatibilityJson(normalized["participant_ids"])
      normalized["participant_ids"] = Array.isArray(ids)
        ? ids.map(integerForValidation)
        : ids
    }
    if (operation === "createThread") {
      if ("space_id" in normalized) {
        normalized["space_id"] = integerForValidation(normalized["space_id"])
      }
      if ("is_public" in normalized) {
        normalized["is_public"] = booleanForValidation(normalized["is_public"])
      }
    }
  }
  if (operation === "setMyCommands") {
    const commands = parseCompatibilityJson(
      normalized["commands"],
    )
    normalized["commands"] = Array.isArray(commands)
      ? commands.map(normalizeBotCommandForSchema)
      : commands
  }
  if (operation === "getUpdates" || operation === "setWebhook") {
    if ("allowed_updates" in normalized) {
      normalized["allowed_updates"] = parseCompatibilityJson(normalized["allowed_updates"])
    }
  }
  if (operation === "uploadFile") {
    if (normalized["is_animated"] !== undefined) {
      normalized["isAnimated"] = normalized["is_animated"]
    }
    if (normalized["has_audio"] !== undefined) {
      normalized["hasAudio"] = normalized["has_audio"]
    }
    if (normalized["waveform_base64"] !== undefined) {
      normalized["waveform"] = normalized["waveform_base64"]
    }
  }
  if (operation === "setWebhook" || operation === "deleteWebhook") {
    if ("drop_pending_updates" in normalized) {
      normalized["drop_pending_updates"] = booleanForValidation(normalized["drop_pending_updates"])
    }
  }
  return normalized
}

const validateInput = (
  operation: BotOperation,
  input: Record<string, unknown>,
) => {
  const normalized = Effect.try({
    try: () => normalizeInputForSchema(operation, input),
    catch: () =>
      new InvalidBotPayload({ reason: "schema" }),
  })
  const decode = (value: Record<string, unknown>) => {
    switch (operation) {
      case "getMe":
      case "getMyCommands":
      case "getMyAgents":
      case "deleteMyCommands":
      case "getWebhookInfo":
        return Effect.succeed(value)
      case "sendMessage":
        return Schema.decodeUnknownEffect(SendMessageInput)(value)
      case "createAgent": return Schema.decodeUnknownEffect(CreateAgentInput)(value)
      case "getAgent": return Schema.decodeUnknownEffect(GetAgentInput)(value)
      case "getChat":
        return Schema.decodeUnknownEffect(GetChatInput)(value)
      case "getChatHistory":
        return Schema.decodeUnknownEffect(
          GetChatHistoryInput,
        )(value)
      case "getMessages":
        return Schema.decodeUnknownEffect(GetMessagesInput)(value)
      case "searchMessages":
        return Schema.decodeUnknownEffect(SearchMessagesInput)(value)
      case "createThread":
        return Schema.decodeUnknownEffect(CreateThreadInput)(value)
      case "createReplyThread":
        return Schema.decodeUnknownEffect(CreateReplyThreadInput)(value)
      case "editMessageText":
        return Schema.decodeUnknownEffect(
          EditMessageTextInput,
        )(value)
      case "deleteMessage":
        return Schema.decodeUnknownEffect(
          DeleteMessageInput,
        )(value)
      case "sendReaction":
        return Schema.decodeUnknownEffect(
          SendReactionInput,
        )(value)
      case "deleteReaction": return Schema.decodeUnknownEffect(DeleteReactionInput)(value)
      case "answerMessageAction": return Schema.decodeUnknownEffect(AnswerMessageActionInput)(value)
      case "sendChatAction": return Schema.decodeUnknownEffect(SendChatActionInput)(value)
      case "getFile": return Schema.decodeUnknownEffect(GetFileInput)(value)
      case "getUpdates": return Schema.decodeUnknownEffect(GetUpdatesInput)(value)
      case "setWebhook": return Schema.decodeUnknownEffect(SetWebhookInput)(value)
      case "deleteWebhook": return Schema.decodeUnknownEffect(DeleteWebhookInput)(value)
      case "setMyCommands":
        return Schema.decodeUnknownEffect(
          SetMyCommandsInput,
        )(value)
      case "forwardMessage": return Schema.decodeUnknownEffect(ForwardMessageInput)(value)
      case "pinMessage":
      case "unpinMessage": return Schema.decodeUnknownEffect(PinMessageInput)(value)
      case "getChatParticipant": return Schema.decodeUnknownEffect(GetChatParticipantInput)(value)
      case "getChatParticipantCount": return Schema.decodeUnknownEffect(GetChatParticipantCountInput)(value)
      case "setThreadTitle": return Schema.decodeUnknownEffect(SetThreadTitleInput)(value)
      case "uploadFile": return Schema.decodeUnknownEffect(UploadFileRequestInput)(value)
    }
  }

  return normalized.pipe(
    Effect.flatMap(decode),
    Effect.mapError(
      () => new InvalidBotPayload({ reason: "schema" }),
    ),
    Effect.map((decoded) => ({
      // Preserve undocumented compatibility aliases until their telemetry
      // removal window closes, but make canonical fields schema-owned.
      ...input,
      ...decoded,
    })),
  )
}

const prepareInput = (
  operation: BotOperation,
  request: Request,
) => {
  if (
    operation === "getMe" ||
    operation === "getMyCommands" ||
    operation === "getMyAgents" ||
    operation === "deleteMyCommands"
    || operation === "getWebhookInfo"
  ) {
    return Effect.succeed({})
  }

  const query = recordFromSearchParams(
    new URL(request.url).searchParams,
  )
  if (request.method === "GET") {
    return Effect.succeed(query)
  }

  return Effect.tryPromise({
    try: () => parseLegacyElysiaBody(request),
    catch: () =>
      new InvalidBotPayload({ reason: "parse" }),
  }).pipe(
    Effect.map((body) => ({
      ...query,
      ...(isRecord(body) ? body : {}),
    })),
  )
}

const runOperation = (
  operation: BotOperation,
  input: Record<string, unknown>,
  context: BotOperationContext,
) =>
  BotOperations.use((
    operations,
  ): Effect.Effect<unknown, BotOperationError> => {
    switch (operation) {
      case "getMe":
        return operations.getMe(context)
      case "sendMessage":
        return operations.sendMessage(
          input as SendMessageParams,
          context,
        )
      case "getChat":
        return operations.getChat(
          input as GetChatParams,
          context,
        )
      case "getChatHistory":
        return operations.getChatHistory(
          input as GetChatHistoryParams,
          context,
        )
      case "getMessages":
        return operations.getMessages(input as GetMessagesParams, context)
      case "searchMessages":
        return operations.searchMessages(input as SearchMessagesParams, context)
      case "createThread":
        return operations.createThread(input as CreateThreadParams, context)
      case "createReplyThread":
        return operations.createReplyThread(input as CreateReplyThreadParams, context)
      case "editMessageText":
        return operations.editMessageText(
          input as EditMessageTextParams,
          context,
        )
      case "deleteMessage":
        return operations.deleteMessage(
          input as DeleteMessageParams,
          context,
        )
      case "sendReaction":
        return operations.sendReaction(
          input as SendReactionParams,
          context,
        )
      case "deleteReaction": return operations.deleteReaction(input as DeleteReactionParams, context)
      case "answerMessageAction": return operations.answerMessageAction(input as AnswerMessageActionParams, context)
      case "sendChatAction": return operations.sendChatAction(input as SendChatActionParams, context)
      case "getFile": return operations.getFile(input as GetFileParams, context)
      case "getUpdates": return operations.getUpdates(input as GetUpdatesParams, context)
      case "setWebhook": return operations.setWebhook(input as SetWebhookParams, context)
      case "deleteWebhook": return operations.deleteWebhook(input as DeleteWebhookParams, context)
      case "getWebhookInfo": return operations.getWebhookInfo(context)
      case "getMyCommands":
        return operations.getMyCommands(context)
      case "createAgent": return operations.createAgent(input as CreateAgentParams, context)
      case "getAgent": return operations.getAgent(input as GetAgentParams, context)
      case "getMyAgents": return operations.getMyAgents(context)
      case "setMyCommands":
        return operations.setMyCommands(
          input as SetMyCommandsParams,
          context,
        )
      case "deleteMyCommands":
        return operations.deleteMyCommands(context)
      case "forwardMessage": return operations.forwardMessage(input as ForwardMessageParams, context)
      case "pinMessage": return operations.pinMessage(input as PinMessageParams, context)
      case "unpinMessage": return operations.unpinMessage(input as UnpinMessageParams, context)
      case "getChatParticipant": return operations.getChatParticipant(input as GetChatParticipantParams, context)
      case "getChatParticipantCount": return operations.getChatParticipantCount(input as GetChatParticipantCountParams, context)
      case "setThreadTitle": return operations.setThreadTitle(input as SetThreadTitleParams, context)
      case "uploadFile": return operations.uploadFile(input as unknown as UploadFileOperationInput, context)
    }
  })

const validateSuccessEnvelope = (
  operation: BotOperation,
  result: unknown,
) => {
  const envelope = omitUndefinedObjectProperties({
    ok: true,
    result,
  })
  const decode = (() => {
    switch (operation) {
      case "getMe":
        return Schema.decodeUnknownEffect(
          BotGetMeSuccess,
        )(envelope)
      case "sendMessage":
      case "editMessageText":
      case "forwardMessage":
        return Schema.decodeUnknownEffect(
          BotMessageRuntimeSuccess,
        )(envelope)
      case "getChat":
        return Schema.decodeUnknownEffect(
          BotGetChatSuccess,
        )(envelope)
      case "getChatHistory":
        return Schema.decodeUnknownEffect(
          BotGetChatHistoryRuntimeSuccess,
        )(envelope)
      case "getMessages":
      case "searchMessages":
        return Schema.decodeUnknownEffect(BotMessagesRuntimeSuccess)(envelope)
      case "createThread":
      case "createReplyThread":
        return Schema.decodeUnknownEffect(BotCreateThreadSuccess)(envelope)
      case "getFile":
      case "uploadFile": return Schema.decodeUnknownEffect(BotGetFileSuccess)(envelope)
      case "getUpdates": return Schema.decodeUnknownEffect(BotGetUpdatesSuccess)(envelope)
      case "setWebhook":
      case "deleteWebhook": return Schema.decodeUnknownEffect(BotTrueSuccess)(envelope)
      case "getWebhookInfo": return Schema.decodeUnknownEffect(BotWebhookInfoSuccess)(envelope)
      case "getMyCommands":
        return Schema.decodeUnknownEffect(
          BotGetMyCommandsSuccess,
        )(envelope)
      case "createAgent": return Schema.decodeUnknownEffect(BotCreateAgentSuccess)(envelope)
      case "getAgent": return Schema.decodeUnknownEffect(BotGetAgentSuccess)(envelope)
      case "getMyAgents": return Schema.decodeUnknownEffect(BotGetMyAgentsSuccess)(envelope)
      case "getChatParticipant": return Schema.decodeUnknownEffect(BotGetChatParticipantSuccess)(envelope)
      case "getChatParticipantCount": return Schema.decodeUnknownEffect(BotGetChatParticipantCountSuccess)(envelope)
      case "deleteMessage":
      case "sendReaction":
      case "deleteReaction":
      case "answerMessageAction":
      case "sendChatAction":
      case "setMyCommands":
      case "deleteMyCommands":
      case "pinMessage":
      case "unpinMessage":
      case "setThreadTitle":
        return Schema.decodeUnknownEffect(
          BotEmptyRuntimeSuccess,
        )(envelope)
    }
  })()

  return decode.pipe(
    Effect.mapError(
      (cause) =>
        new BotOperationFailure({
          operation,
          cause,
        }),
    ),
  )
}

const authenticateBotRequest = (
  webRequest: Request,
  pathToken: string | undefined,
) =>
  Effect.gen(function* () {
    const headerToken = normalizeToken(
      webRequest.headers.get("authorization") ?? undefined,
    )
    const token =
      headerToken ??
      (pathToken === undefined
        ? null
        : normalizePathToken(pathToken))
    if (token === null) {
      return yield* Effect.fail(
        missingBotAuthentication(),
      )
    }

    const identity = yield* SessionAuthentication.use(
      (authentication) => authentication.authenticate(token),
    )
    yield* BotAuthorization.use((authorization) =>
      authorization.requireBot(identity.userId),
    )
    return identity
  })

export const executeBotOperation = (
  operation: BotOperation,
  request: HttpServerRequest.HttpServerRequest,
  pathToken: string | undefined,
) =>
  Effect.gen(function* () {
    const webRequest = yield* HttpServerRequest.toWeb(request)
    const uploadIdentity = operation === "uploadFile"
      ? yield* authenticateBotRequest(webRequest, pathToken)
      : undefined
    const input = operation === "uploadFile"
      ? yield* parseV1UploadRequest(request).pipe(
        Effect.mapError(() => new InvalidBotPayload({ reason: "parse" })),
        Effect.provide(BunFileSystem.layer),
        Effect.provide(BunPath.layer),
      )
      : yield* prepareInput(operation, webRequest)
    const identity = uploadIdentity ?? (yield* authenticateBotRequest(webRequest, pathToken))
    const validatedInput = yield* validateInput(
      operation,
      input,
    )
    const requestContext = yield* HttpRequestContext
    const result = yield* runOperation(
      operation,
      validatedInput,
      {
        currentUserId: identity.userId,
        currentSessionId: identity.sessionId,
        ip: requestContext.clientIp,
      },
    )
    const envelope = yield* validateSuccessEnvelope(
      operation,
      result,
    )
    return json(200, envelope)
  }).pipe(
    Effect.catchTag(
      "InvalidBotPayload",
      () =>
        noteApiError.pipe(
          Effect.as(invalidArgsResponse()),
        ),
    ),
    Effect.catchTag(
      "SessionAuthenticationRejected",
      (error: SessionAuthenticationRejected) =>
        noteApiError.pipe(
          Effect.as(publicErrorResponse(error)),
        ),
    ),
    Effect.catchTag(
      "BotAuthorizationRejected",
      (error: BotAuthorizationRejected) =>
        noteApiError.pipe(
          Effect.as(publicErrorResponse(error)),
        ),
    ),
    Effect.catchTag(
      "BotPublicError",
      (error: BotPublicError) =>
        noteApiError.pipe(
          Effect.as(publicErrorResponse(error)),
        ),
    ),
    Effect.catchTag(
      "SessionAuthenticationFailure",
      (error: SessionAuthenticationFailure) =>
        noteApiError.pipe(
          Effect.andThen(
            reportCause(
              "bot.authenticate",
              Cause.fail(error.cause),
            ),
          ),
          Effect.as(serverErrorResponse()),
        ),
    ),
    Effect.catchTag(
      "BotAuthorizationFailure",
      (error: BotAuthorizationFailure) =>
        noteApiError.pipe(
          Effect.andThen(
            reportCause(
              "bot.authorize",
              Cause.fail(error.cause),
            ),
          ),
          Effect.as(serverErrorResponse()),
        ),
    ),
    Effect.catchTag(
      "BotOperationFailure",
      (error: BotOperationFailure) =>
        noteApiError.pipe(
          Effect.andThen(
            reportCause(
              `bot.${error.operation}`,
              Cause.fail(error.cause),
            ),
          ),
          Effect.as(
            error.publicError === undefined
              ? internalOperationResponse()
              : publicErrorResponse(error.publicError),
          ),
        ),
    ),
    Effect.catchCause((cause) =>
      noteApiError.pipe(
        Effect.andThen(
          reportCause(`bot.${operation}.boundary`, cause),
        ),
        Effect.as(serverErrorResponse()),
      ),
    ),
    Effect.annotateLogs({
      "bot.operation": operation,
    }),
  )

export const executeBotNotFound = (
  request: HttpServerRequest.HttpServerRequest,
  pathToken: string | undefined,
) =>
  Effect.gen(function* () {
    const webRequest = yield* HttpServerRequest.toWeb(request)
    if (
      webRequest.method !== "GET" &&
      webRequest.method !== "HEAD" &&
      webRequest.method !== "OPTIONS" &&
      webRequest.method !== "TRACE"
    ) {
      yield* Effect.tryPromise({
        try: () => parseLegacyElysiaBody(webRequest),
        catch: () =>
          new InvalidBotPayload({ reason: "parse" }),
      })
    }
    yield* authenticateBotRequest(webRequest, pathToken)
    return yield* Effect.fail(
      new BotPublicError({
        error: "METHOD_NOT_FOUND",
        errorCode: 404,
        description: "Method not found",
      }),
    )
  }).pipe(
    Effect.catchTag(
      "InvalidBotPayload",
      () =>
        noteApiError.pipe(
          Effect.as(invalidArgsResponse()),
        ),
    ),
    Effect.catchTag(
      "SessionAuthenticationRejected",
      (error: SessionAuthenticationRejected) =>
        noteApiError.pipe(
          Effect.as(publicErrorResponse(error)),
        ),
    ),
    Effect.catchTag(
      "BotAuthorizationRejected",
      (error: BotAuthorizationRejected) =>
        noteApiError.pipe(
          Effect.as(publicErrorResponse(error)),
        ),
    ),
    Effect.catchTag(
      "BotPublicError",
      (error: BotPublicError) =>
        noteApiError.pipe(
          Effect.as(publicErrorResponse(error)),
        ),
    ),
    Effect.catchTag(
      "SessionAuthenticationFailure",
      (error: SessionAuthenticationFailure) =>
        noteApiError.pipe(
          Effect.andThen(
            reportCause(
              "bot.authenticate",
              Cause.fail(error.cause),
            ),
          ),
          Effect.as(serverErrorResponse()),
        ),
    ),
    Effect.catchTag(
      "BotAuthorizationFailure",
      (error: BotAuthorizationFailure) =>
        noteApiError.pipe(
          Effect.andThen(
            reportCause(
              "bot.authorize",
              Cause.fail(error.cause),
            ),
          ),
          Effect.as(serverErrorResponse()),
        ),
    ),
    Effect.catchCause((cause) =>
      noteApiError.pipe(
        Effect.andThen(
          reportCause("bot.methodNotFound.boundary", cause),
        ),
        Effect.as(serverErrorResponse()),
      ),
    ),
  )

export const makeBotRouteGroup = () => {
  const api = makeBotApiBase(
    "https://api.inline.chat",
  ).add(BotApiGroup)
  const handlers = HttpApiBuilder.group(
    api,
    "bot",
    (groupHandlers) =>
      Effect.gen(function* () {
        const services = yield* Effect.context<
          | BotAuthorization
          | BotOperations
          | ErrorReporter
          | SessionAuthentication
        >()
        const execute = (
          operation: BotOperation,
          request: HttpServerRequest.HttpServerRequest,
          token: string | undefined,
        ) =>
          Effect.provide(
            executeBotOperation(
              operation,
              request,
              token,
            ),
            services,
          )
        const notFound = (
          request: HttpServerRequest.HttpServerRequest,
          token: string | undefined,
        ) =>
          Effect.provide(
            executeBotNotFound(request, token),
            services,
          )

        return groupHandlers
          .handleRaw(
            "headerGetMe",
            ({ request }) =>
              execute("getMe", request, undefined),
          )
          .handleRaw(
            "headerSendMessage",
            ({ request }) =>
              execute("sendMessage", request, undefined),
          )
          .handleRaw(
            "headerGetChat",
            ({ request }) =>
              execute("getChat", request, undefined),
          )
          .handleRaw(
            "headerGetChatHistory",
            ({ request }) =>
              execute(
                "getChatHistory",
                request,
                undefined,
              ),
          )
          .handleRaw("headerGetMessages", ({ request }) =>
            execute("getMessages", request, undefined))
          .handleRaw("headerSearchMessages", ({ request }) =>
            execute("searchMessages", request, undefined))
          .handleRaw("headerCreateThread", ({ request }) =>
            execute("createThread", request, undefined))
          .handleRaw("headerCreateReplyThread", ({ request }) =>
            execute("createReplyThread", request, undefined))
          .handleRaw(
            "headerEditMessageText",
            ({ request }) =>
              execute(
                "editMessageText",
                request,
                undefined,
              ),
          )
          .handleRaw(
            "headerDeleteMessage",
            ({ request }) =>
              execute(
                "deleteMessage",
                request,
                undefined,
              ),
          )
          .handleRaw(
            "headerSendReaction",
            ({ request }) =>
              execute(
                "sendReaction",
                request,
                undefined,
              ),
          )
          .handleRaw("headerDeleteReaction", ({ request }) => execute("deleteReaction", request, undefined))
          .handleRaw("headerAnswerMessageAction", ({ request }) => execute("answerMessageAction", request, undefined))
          .handleRaw("headerSendChatAction", ({ request }) => execute("sendChatAction", request, undefined))
          .handleRaw("headerGetFile", ({ request }) => execute("getFile", request, undefined))
          .handleRaw("headerGetUpdates", ({ request }) => execute("getUpdates", request, undefined))
          .handleRaw("headerSetWebhook", ({ request }) => execute("setWebhook", request, undefined))
          .handleRaw("headerDeleteWebhook", ({ request }) => execute("deleteWebhook", request, undefined))
          .handleRaw("headerGetWebhookInfo", ({ request }) => execute("getWebhookInfo", request, undefined))
          .handleRaw(
            "headerGetMyCommands",
            ({ request }) =>
              execute(
                "getMyCommands",
                request,
                undefined,
              ),
          )
          .handleRaw("headerCreateAgent", ({ request }) => execute("createAgent", request, undefined))
          .handleRaw("headerGetAgent", ({ request }) => execute("getAgent", request, undefined))
          .handleRaw("headerGetMyAgents", ({ request }) => execute("getMyAgents", request, undefined))
          .handleRaw(
            "headerSetMyCommands",
            ({ request }) =>
              execute(
                "setMyCommands",
                request,
                undefined,
              ),
          )
          .handleRaw(
            "headerDeleteMyCommands",
            ({ request }) =>
              execute(
                "deleteMyCommands",
                request,
                undefined,
              ),
          )
          .handleRaw("headerForwardMessage", ({ request }) => execute("forwardMessage", request, undefined))
          .handleRaw("headerPinMessage", ({ request }) => execute("pinMessage", request, undefined))
          .handleRaw("headerUnpinMessage", ({ request }) => execute("unpinMessage", request, undefined))
          .handleRaw("headerGetChatParticipant", ({ request }) => execute("getChatParticipant", request, undefined))
          .handleRaw("headerGetChatParticipantCount", ({ request }) => execute("getChatParticipantCount", request, undefined))
          .handleRaw("headerSetThreadTitle", ({ request }) => execute("setThreadTitle", request, undefined))
          .handleRaw("headerUploadFile", ({ request }) => execute("uploadFile", request, undefined))
          .handleRaw(
            "pathGetMe",
            ({ params, request }) =>
              execute("getMe", request, params.token),
          )
          .handleRaw(
            "pathSendMessage",
            ({ params, request }) =>
              execute(
                "sendMessage",
                request,
                params.token,
              ),
          )
          .handleRaw(
            "pathGetChat",
            ({ params, request }) =>
              execute("getChat", request, params.token),
          )
          .handleRaw(
            "pathGetChatHistory",
            ({ params, request }) =>
              execute(
                "getChatHistory",
                request,
                params.token,
              ),
          )
          .handleRaw("pathGetMessages", ({ params, request }) =>
            execute("getMessages", request, params.token))
          .handleRaw("pathSearchMessages", ({ params, request }) =>
            execute("searchMessages", request, params.token))
          .handleRaw("pathCreateThread", ({ params, request }) =>
            execute("createThread", request, params.token))
          .handleRaw("pathCreateReplyThread", ({ params, request }) =>
            execute("createReplyThread", request, params.token))
          .handleRaw(
            "pathEditMessageText",
            ({ params, request }) =>
              execute(
                "editMessageText",
                request,
                params.token,
              ),
          )
          .handleRaw(
            "pathDeleteMessage",
            ({ params, request }) =>
              execute(
                "deleteMessage",
                request,
                params.token,
              ),
          )
          .handleRaw(
            "pathSendReaction",
            ({ params, request }) =>
              execute(
                "sendReaction",
                request,
                params.token,
              ),
          )
          .handleRaw("pathDeleteReaction", ({ params, request }) => execute("deleteReaction", request, params.token))
          .handleRaw("pathAnswerMessageAction", ({ params, request }) => execute("answerMessageAction", request, params.token))
          .handleRaw("pathSendChatAction", ({ params, request }) => execute("sendChatAction", request, params.token))
          .handleRaw("pathGetFile", ({ params, request }) => execute("getFile", request, params.token))
          .handleRaw("pathGetUpdates", ({ params, request }) => execute("getUpdates", request, params.token))
          .handleRaw("pathSetWebhook", ({ params, request }) => execute("setWebhook", request, params.token))
          .handleRaw("pathDeleteWebhook", ({ params, request }) => execute("deleteWebhook", request, params.token))
          .handleRaw("pathGetWebhookInfo", ({ params, request }) => execute("getWebhookInfo", request, params.token))
          .handleRaw(
            "pathGetMyCommands",
            ({ params, request }) =>
              execute(
                "getMyCommands",
                request,
                params.token,
              ),
          )
          .handleRaw("pathCreateAgent", ({ params, request }) => execute("createAgent", request, params.token))
          .handleRaw("pathGetAgent", ({ params, request }) => execute("getAgent", request, params.token))
          .handleRaw("pathGetMyAgents", ({ params, request }) => execute("getMyAgents", request, params.token))
          .handleRaw(
            "pathSetMyCommands",
            ({ params, request }) =>
              execute(
                "setMyCommands",
                request,
                params.token,
              ),
          )
          .handleRaw(
            "pathDeleteMyCommands",
            ({ params, request }) =>
              execute(
                "deleteMyCommands",
                request,
                params.token,
              ),
          )
          .handleRaw("pathForwardMessage", ({ params, request }) => execute("forwardMessage", request, params.token))
          .handleRaw("pathPinMessage", ({ params, request }) => execute("pinMessage", request, params.token))
          .handleRaw("pathUnpinMessage", ({ params, request }) => execute("unpinMessage", request, params.token))
          .handleRaw("pathGetChatParticipant", ({ params, request }) => execute("getChatParticipant", request, params.token))
          .handleRaw("pathGetChatParticipantCount", ({ params, request }) => execute("getChatParticipantCount", request, params.token))
          .handleRaw("pathSetThreadTitle", ({ params, request }) => execute("setThreadTitle", request, params.token))
          .handleRaw("pathUploadFile", ({ params, request }) => execute("uploadFile", request, params.token))
          .handleRaw(
            "headerFallbackGet",
            ({ request }) =>
              notFound(request, undefined),
          )
          .handleRaw(
            "headerFallbackPost",
            ({ request }) =>
              notFound(request, undefined),
          )
          .handleRaw(
            "headerFallbackPut",
            ({ request }) =>
              notFound(request, undefined),
          )
          .handleRaw(
            "headerFallbackDelete",
            ({ request }) =>
              notFound(request, undefined),
          )
          .handleRaw(
            "headerFallbackPatch",
            ({ request }) =>
              notFound(request, undefined),
          )
          .handleRaw(
            "headerFallbackHead",
            ({ request }) =>
              notFound(request, undefined),
          )
          .handleRaw(
            "headerFallbackOptions",
            ({ request }) =>
              notFound(request, undefined),
          )
          .handleRaw(
            "headerFallbackTrace",
            ({ request }) =>
              notFound(request, undefined),
          )
          .handleRaw(
            "pathFallbackGet",
            ({ params, request }) =>
              notFound(request, params.token),
          )
          .handleRaw(
            "pathFallbackPost",
            ({ params, request }) =>
              notFound(request, params.token),
          )
          .handleRaw(
            "pathFallbackPut",
            ({ params, request }) =>
              notFound(request, params.token),
          )
          .handleRaw(
            "pathFallbackDelete",
            ({ params, request }) =>
              notFound(request, params.token),
          )
          .handleRaw(
            "pathFallbackPatch",
            ({ params, request }) =>
              notFound(request, params.token),
          )
          .handleRaw(
            "pathFallbackHead",
            ({ params, request }) =>
              notFound(request, params.token),
          )
          .handleRaw(
            "pathFallbackOptions",
            ({ params, request }) =>
              notFound(request, params.token),
          )
          .handleRaw(
            "pathFallbackTrace",
            ({ params, request }) =>
              notFound(request, params.token),
          )
      }),
  )

  return defineHttpRouteGroup({
    apiId: BOT_API_ID,
    document: "bot",
    group: BotApiGroup,
    handlers,
  })
}

export const BotRouteGroup = makeBotRouteGroup()
