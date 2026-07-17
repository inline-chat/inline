import type {
  DeleteMessageParams,
  EditMessageTextParams,
  GetChatHistoryParams,
  GetChatParams,
  SendMessageParams,
  SendReactionParams,
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
import {
  BOT_API_ID,
  makeBotApiBase,
  requireOpenApiRequestHeader,
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
  BotGetChatHistorySuccess,
  BotGetChatHistoryRuntimeSuccess,
  BotGetChatSuccess,
  BotGetMyCommandsSuccess,
  BotMessageSuccess,
  BotMessageRuntimeSuccess,
  DeleteMessageInput,
  EditMessageTextInput,
  GetChatHistoryInput,
  GetChatInput,
  SendMessageInput,
  SendReactionInput,
  SetMyCommandsInput,
  botApiErrorAt,
  botApiErrors,
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

const optionalRequestBody = OpenApi.annotations({
  transform: (operation) => {
    if (operation["requestBody"] !== undefined) {
      operation["requestBody"].required = false
    }
    return operation
  },
})

const botEndpoint = (
  summary: string,
) =>
  OpenApi.annotations({
    summary,
    description:
      "Returns the compact Inline Bot API envelope. POST query parameters are accepted for compatibility; JSON is recommended.",
  })

const headerGet = <
  const Identifier extends string,
  const Path extends `/${string}`,
  const Success extends Schema.Top,
  Query extends Schema.Struct.Fields,
>(
  identifier: Identifier,
  path: Path,
  summary: string,
  options: {
    readonly success: Success
    readonly query: Query
  },
) =>
  HttpApiEndpoint.get(identifier, path, {
    headers: AuthorizationHeader,
    query: options.query,
    success: options.success,
    error: botApiErrors,
  }).annotateMerge(
    botEndpoint(summary),
  ).annotateMerge(
    requireOpenApiRequestHeader(
      "authorization",
      "Required bot token using the Bearer scheme.",
    ),
  )

const pathGet = <
  const Identifier extends string,
  const Path extends `/${string}`,
  const Success extends Schema.Top,
  Query extends Schema.Struct.Fields,
>(
  identifier: Identifier,
  path: Path,
  summary: string,
  options: {
    readonly success: Success
    readonly query: Query
  },
) =>
  HttpApiEndpoint.get(identifier, path, {
    params: TokenPath,
    headers: AuthorizationHeader,
    query: options.query,
    success: options.success,
    error: botApiErrors,
  }).annotateMerge(botEndpoint(summary))

const headerPost = <
  const Identifier extends string,
  const Path extends `/${string}`,
  const Success extends Schema.Top,
  Payload extends Schema.Top = never,
>(
  identifier: Identifier,
  path: Path,
  summary: string,
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
    botEndpoint(summary),
  ).annotateMerge(
    requireOpenApiRequestHeader(
      "authorization",
      "Required bot token using the Bearer scheme.",
    ),
  ).annotateMerge(optionalRequestBody)

const pathPost = <
  const Identifier extends string,
  const Path extends `/${string}`,
  const Success extends Schema.Top,
  Payload extends Schema.Top = never,
>(
  identifier: Identifier,
  path: Path,
  summary: string,
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
    botEndpoint(summary),
  ).annotateMerge(optionalRequestBody)

const HeaderBotEndpoints = {
  getMe: headerGet(
    "headerGetMe",
    "/bot/getMe",
    "Get the current bot",
    {
      query: {},
      success: BotGetMeSuccess,
    },
  ),
  sendMessage: headerPost(
    "headerSendMessage",
    "/bot/sendMessage",
    "Send a message",
    {
      payload: SendMessageInput,
      success: BotMessageSuccess,
    },
  ),
  getChat: headerGet(
    "headerGetChat",
    "/bot/getChat",
    "Get a chat",
    {
      query: GetChatInput.fields,
      success: BotGetChatSuccess,
    },
  ),
  getChatHistory: headerGet(
    "headerGetChatHistory",
    "/bot/getChatHistory",
    "Get chat history",
    {
      query: GetChatHistoryInput.fields,
      success: BotGetChatHistorySuccess,
    },
  ),
  editMessageText: headerPost(
    "headerEditMessageText",
    "/bot/editMessageText",
    "Edit message text",
    {
      payload: EditMessageTextInput,
      success: BotMessageSuccess,
    },
  ),
  deleteMessage: headerPost(
    "headerDeleteMessage",
    "/bot/deleteMessage",
    "Delete a message",
    {
      payload: DeleteMessageInput,
      success: BotEmptySuccess,
    },
  ),
  sendReaction: headerPost(
    "headerSendReaction",
    "/bot/sendReaction",
    "Send a reaction",
    {
      payload: SendReactionInput,
      success: BotEmptySuccess,
    },
  ),
  getMyCommands: headerGet(
    "headerGetMyCommands",
    "/bot/getMyCommands",
    "Get bot commands",
    {
      query: {},
      success: BotGetMyCommandsSuccess,
    },
  ),
  setMyCommands: headerPost(
    "headerSetMyCommands",
    "/bot/setMyCommands",
    "Replace bot commands",
    {
      payload: SetMyCommandsInput,
      success: BotEmptySuccess,
    },
  ),
  deleteMyCommands: headerPost(
    "headerDeleteMyCommands",
    "/bot/deleteMyCommands",
    "Delete bot commands",
    { success: BotEmptySuccess },
  ),
} as const

const PathBotEndpoints = {
  getMe: pathGet(
    "pathGetMe",
    "/bot:token/getMe",
    "Get the current bot using a path token",
    {
      query: {},
      success: BotGetMeSuccess,
    },
  ),
  sendMessage: pathPost(
    "pathSendMessage",
    "/bot:token/sendMessage",
    "Send a message using a path token",
    {
      payload: SendMessageInput,
      success: BotMessageSuccess,
    },
  ),
  getChat: pathGet(
    "pathGetChat",
    "/bot:token/getChat",
    "Get a chat using a path token",
    {
      query: GetChatInput.fields,
      success: BotGetChatSuccess,
    },
  ),
  getChatHistory: pathGet(
    "pathGetChatHistory",
    "/bot:token/getChatHistory",
    "Get chat history using a path token",
    {
      query: GetChatHistoryInput.fields,
      success: BotGetChatHistorySuccess,
    },
  ),
  editMessageText: pathPost(
    "pathEditMessageText",
    "/bot:token/editMessageText",
    "Edit message text using a path token",
    {
      payload: EditMessageTextInput,
      success: BotMessageSuccess,
    },
  ),
  deleteMessage: pathPost(
    "pathDeleteMessage",
    "/bot:token/deleteMessage",
    "Delete a message using a path token",
    {
      payload: DeleteMessageInput,
      success: BotEmptySuccess,
    },
  ),
  sendReaction: pathPost(
    "pathSendReaction",
    "/bot:token/sendReaction",
    "Send a reaction using a path token",
    {
      payload: SendReactionInput,
      success: BotEmptySuccess,
    },
  ),
  getMyCommands: pathGet(
    "pathGetMyCommands",
    "/bot:token/getMyCommands",
    "Get bot commands using a path token",
    {
      query: {},
      success: BotGetMyCommandsSuccess,
    },
  ),
  setMyCommands: pathPost(
    "pathSetMyCommands",
    "/bot:token/setMyCommands",
    "Replace bot commands using a path token",
    {
      payload: SetMyCommandsInput,
      success: BotEmptySuccess,
    },
  ),
  deleteMyCommands: pathPost(
    "pathDeleteMyCommands",
    "/bot:token/deleteMyCommands",
    "Delete bot commands using a path token",
    { success: BotEmptySuccess },
  ),
} as const

const BotMethodNotFound =
  botApiErrorAt(404).annotate({
    identifier: "BotMethodNotFound",
  })

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
  const normalized = { ...input }
  if ("limit" in normalized) {
    normalized["limit"] = integerForValidation(
      normalized["limit"],
    )
  }
  if (
    operation === "sendMessage" ||
    operation === "editMessageText"
  ) {
    if ("entities" in normalized) {
      normalized["entities"] = parseCompatibilityJson(
        normalized["entities"],
      )
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
      ? commands.map((command) => {
          if (!isRecord(command) || !("sort_order" in command)) {
            return command
          }
          return {
            ...command,
            sort_order: integerForValidation(
              command["sort_order"],
            ),
          }
        })
      : commands
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
    }
  }

  return normalized.pipe(
    Effect.flatMap(decode),
    Effect.mapError(
      () => new InvalidBotPayload({ reason: "schema" }),
    ),
    // TODO(effect-cutover): pass decoded branded/schema values once every Bot
    // operation is Effect-native and no retained operation owns coercion.
    // Until then the executable guard validates the compatibility view.
    Effect.as(input),
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
    }
  })

const validateSuccessEnvelope = (
  operation: BotOperation,
  result: unknown,
) => {
  const envelope = { ok: true, result }
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
      case "deleteMessage":
      case "sendReaction":
      case "setMyCommands":
      case "deleteMyCommands":
        return Schema.decodeUnknownEffect(
          BotEmptySuccess,
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
    yield* validateInput(operation, input)
    const requestContext = yield* HttpRequestContext
    const result = yield* runOperation(
      operation,
      input,
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
