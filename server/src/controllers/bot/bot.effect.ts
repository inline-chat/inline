import type {
  DeleteMessageParams,
  EditMessageTextParams,
  GetChatHistoryParams,
  GetChatParams,
  SendMessageParams,
  SendReactionParams,
  SetMyCapabilitiesParams,
  SetMyCommandsParams,
} from "@inline-chat/bot-api-types"
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
  BotEmptyRuntimeSuccess,
  BotGetChatHistorySuccess,
  BotGetChatHistoryRuntimeSuccess,
  BotGetChatSuccess,
  BotGetMyCommandsSuccess,
  BotGetMyCapabilitiesSuccess,
  BotMessageSuccess,
  BotMessageRuntimeSuccess,
  DeleteMessageInput,
  EditMessageTextInput,
  GetChatHistoryInput,
  GetChatInput,
  SendMessageInput,
  SendReactionInput,
  SetMyCommandsInput,
  SetMyCapabilitiesInput,
  botTargetFieldDescriptions,
  botApiErrorAt,
  botApiErrors,
  getChatHistoryFieldDescriptions,
} from "./types.effect"
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
            options.queryDescriptions?.[parameter.name]
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
  getMyCommands: {
    summary: "Get bot commands",
    description:
      "Returns the command list currently published by the authenticated bot.",
  },
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
  getMyCapabilities: {
    summary: "Get bot capabilities",
    description: "Returns the capabilities currently advertised by the authenticated bot.",
  },
  setMyCapabilities: {
    summary: "Replace bot capabilities",
    description: "Replaces the authenticated bot's complete capability list.",
  },
  deleteMyCapabilities: {
    summary: "Delete bot capabilities",
    description: "Clears every capability advertised by the authenticated bot.",
  },
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
  getMyCommands: headerGet(
    "headerGetMyCommands",
    "/bot/getMyCommands",
    BotMethodDocumentation.getMyCommands,
    {
      query: {},
      success: BotGetMyCommandsSuccess,
    },
  ),
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
  getMyCapabilities: headerGet(
    "headerGetMyCapabilities",
    "/bot/getMyCapabilities",
    BotMethodDocumentation.getMyCapabilities,
    { query: {}, success: BotGetMyCapabilitiesSuccess },
  ),
  setMyCapabilities: headerPost(
    "headerSetMyCapabilities",
    "/bot/setMyCapabilities",
    BotMethodDocumentation.setMyCapabilities,
    { payload: SetMyCapabilitiesInput, success: BotGetMyCapabilitiesSuccess },
  ),
  deleteMyCapabilities: headerPost(
    "headerDeleteMyCapabilities",
    "/bot/deleteMyCapabilities",
    BotMethodDocumentation.deleteMyCapabilities,
    { success: BotEmptySuccess },
  ),
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
  getMyCommands: pathGet(
    "pathGetMyCommands",
    "/bot:token/getMyCommands",
    BotMethodDocumentation.getMyCommands,
    {
      query: {},
      success: BotGetMyCommandsSuccess,
    },
  ),
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
  getMyCapabilities: pathGet(
    "pathGetMyCapabilities",
    "/bot:token/getMyCapabilities",
    BotMethodDocumentation.getMyCapabilities,
    { query: {}, success: BotGetMyCapabilitiesSuccess },
  ),
  setMyCapabilities: pathPost(
    "pathSetMyCapabilities",
    "/bot:token/setMyCapabilities",
    BotMethodDocumentation.setMyCapabilities,
    { payload: SetMyCapabilitiesInput, success: BotGetMyCapabilitiesSuccess },
  ),
  deleteMyCapabilities: pathPost(
    "pathDeleteMyCapabilities",
    "/bot:token/deleteMyCapabilities",
    BotMethodDocumentation.deleteMyCapabilities,
    { success: BotEmptySuccess },
  ),
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
    HeaderBotEndpoints.editMessageText,
    HeaderBotEndpoints.deleteMessage,
    HeaderBotEndpoints.sendReaction,
    HeaderBotEndpoints.getMyCommands,
    HeaderBotEndpoints.setMyCommands,
    HeaderBotEndpoints.deleteMyCommands,
    HeaderBotEndpoints.getMyCapabilities,
    HeaderBotEndpoints.setMyCapabilities,
    HeaderBotEndpoints.deleteMyCapabilities,
    PathBotEndpoints.getMe,
    PathBotEndpoints.sendMessage,
    PathBotEndpoints.getChat,
    PathBotEndpoints.getChatHistory,
    PathBotEndpoints.editMessageText,
    PathBotEndpoints.deleteMessage,
    PathBotEndpoints.sendReaction,
    PathBotEndpoints.getMyCommands,
    PathBotEndpoints.setMyCommands,
    PathBotEndpoints.deleteMyCommands,
    PathBotEndpoints.getMyCapabilities,
    PathBotEndpoints.setMyCapabilities,
    PathBotEndpoints.deleteMyCapabilities,
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
    operation === "getChatHistory"
  const normalized = usesQueryIdCodecs
    ? { ...input }
    : normalizeIntegerFields(input, [
        "user_id",
        "chat_id",
        "message_id",
        "reply_to_message_id",
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
  if (operation === "setMyCommands") {
    const commands = parseCompatibilityJson(
      normalized["commands"],
    )
    normalized["commands"] = Array.isArray(commands)
      ? commands.map(normalizeBotCommandForSchema)
      : commands
  }
  if (operation === "setMyCapabilities") {
    normalized["capabilities"] = parseCompatibilityJson(normalized["capabilities"])
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
      case "deleteMyCommands":
      case "getMyCapabilities":
      case "deleteMyCapabilities":
        return Effect.succeed(value)
      case "sendMessage":
        return Schema.decodeUnknownEffect(SendMessageInput)(value)
      case "getChat":
        return Schema.decodeUnknownEffect(GetChatInput)(value)
      case "getChatHistory":
        return Schema.decodeUnknownEffect(
          GetChatHistoryInput,
        )(value)
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
      case "setMyCommands":
        return Schema.decodeUnknownEffect(
          SetMyCommandsInput,
        )(value)
      case "setMyCapabilities":
        return Schema.decodeUnknownEffect(SetMyCapabilitiesInput)(value)
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
    operation === "deleteMyCommands"
    || operation === "getMyCapabilities"
    || operation === "deleteMyCapabilities"
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
      case "getMyCommands":
        return operations.getMyCommands(context)
      case "setMyCommands":
        return operations.setMyCommands(
          input as SetMyCommandsParams,
          context,
        )
      case "deleteMyCommands":
        return operations.deleteMyCommands(context)
      case "getMyCapabilities":
        return operations.getMyCapabilities(context)
      case "setMyCapabilities":
        return operations.setMyCapabilities(input as SetMyCapabilitiesParams, context)
      case "deleteMyCapabilities":
        return operations.deleteMyCapabilities(context)
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
      case "getMyCommands":
        return Schema.decodeUnknownEffect(
          BotGetMyCommandsSuccess,
        )(envelope)
      case "getMyCapabilities":
      case "setMyCapabilities":
        return Schema.decodeUnknownEffect(BotGetMyCapabilitiesSuccess)(envelope)
      case "deleteMessage":
      case "sendReaction":
      case "setMyCommands":
      case "deleteMyCommands":
      case "deleteMyCapabilities":
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
    const input = yield* prepareInput(
      operation,
      webRequest,
    )
    const identity = yield* authenticateBotRequest(
      webRequest,
      pathToken,
    )
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
          .handleRaw(
            "headerGetMyCommands",
            ({ request }) =>
              execute(
                "getMyCommands",
                request,
                undefined,
              ),
          )
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
          .handleRaw(
            "headerGetMyCapabilities",
            ({ request }) => execute("getMyCapabilities", request, undefined),
          )
          .handleRaw(
            "headerSetMyCapabilities",
            ({ request }) => execute("setMyCapabilities", request, undefined),
          )
          .handleRaw(
            "headerDeleteMyCapabilities",
            ({ request }) => execute("deleteMyCapabilities", request, undefined),
          )
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
          .handleRaw(
            "pathGetMyCommands",
            ({ params, request }) =>
              execute(
                "getMyCommands",
                request,
                params.token,
              ),
          )
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
          .handleRaw(
            "pathGetMyCapabilities",
            ({ params, request }) => execute("getMyCapabilities", request, params.token),
          )
          .handleRaw(
            "pathSetMyCapabilities",
            ({ params, request }) => execute("setMyCapabilities", request, params.token),
          )
          .handleRaw(
            "pathDeleteMyCapabilities",
            ({ params, request }) => execute("deleteMyCapabilities", request, params.token),
          )
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
