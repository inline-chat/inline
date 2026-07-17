import type {
  DeleteMessageParams,
  EditMessageTextParams,
  EmptyResult,
  GetChatHistoryParams,
  GetChatHistoryResult,
  GetChatParams,
  GetChatResult,
  GetMeResult,
  GetMyCommandsResult,
  SendMessageParams,
  SendMessageResult,
  SendReactionParams,
  SetMyCommandsParams,
} from "@inline-chat/bot-api-types"
import {
  Context,
  Data,
  Effect,
  ErrorReporter,
} from "effect"
import { ModelError } from "@in/server/db/models/_errors"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { InlineError } from "@in/server/types/errors"

export type BotOperation =
  | "getMe"
  | "sendMessage"
  | "getChat"
  | "getChatHistory"
  | "editMessageText"
  | "deleteMessage"
  | "sendReaction"
  | "getMyCommands"
  | "setMyCommands"
  | "deleteMyCommands"

export interface BotOperationContext {
  readonly currentUserId: number
  readonly currentSessionId: number
  readonly ip: string | undefined
}

export class BotPublicError extends Data.TaggedError(
  "BotPublicError",
)<{
  readonly error: string
  readonly errorCode: number
  readonly description: string
}> {
  override readonly [ErrorReporter.ignore] = true
}

export class BotOperationFailure extends Data.TaggedError(
  "BotOperationFailure",
)<{
  readonly operation: BotOperation
  readonly cause: unknown
  readonly publicError?: BotPublicError | undefined
}> {}

export type BotOperationError =
  | BotPublicError
  | BotOperationFailure

export interface BotOperationsShape {
  readonly getMe: (
    context: BotOperationContext,
  ) => Effect.Effect<GetMeResult, BotOperationError>
  readonly sendMessage: (
    input: SendMessageParams,
    context: BotOperationContext,
  ) => Effect.Effect<SendMessageResult, BotOperationError>
  readonly getChat: (
    input: GetChatParams,
    context: BotOperationContext,
  ) => Effect.Effect<GetChatResult, BotOperationError>
  readonly getChatHistory: (
    input: GetChatHistoryParams,
    context: BotOperationContext,
  ) => Effect.Effect<GetChatHistoryResult, BotOperationError>
  readonly editMessageText: (
    input: EditMessageTextParams,
    context: BotOperationContext,
  ) => Effect.Effect<SendMessageResult, BotOperationError>
  readonly deleteMessage: (
    input: DeleteMessageParams,
    context: BotOperationContext,
  ) => Effect.Effect<EmptyResult, BotOperationError>
  readonly sendReaction: (
    input: SendReactionParams,
    context: BotOperationContext,
  ) => Effect.Effect<EmptyResult, BotOperationError>
  readonly getMyCommands: (
    context: BotOperationContext,
  ) => Effect.Effect<GetMyCommandsResult, BotOperationError>
  readonly setMyCommands: (
    input: SetMyCommandsParams,
    context: BotOperationContext,
  ) => Effect.Effect<EmptyResult, BotOperationError>
  readonly deleteMyCommands: (
    context: BotOperationContext,
  ) => Effect.Effect<EmptyResult, BotOperationError>
}

export class BotOperations extends Context.Service<
  BotOperations,
  BotOperationsShape
>()("@inline/server/bot/BotOperations") {}

export interface BotOperationHandlers {
  readonly getMe: (
    context: BotOperationContext,
  ) => Promise<GetMeResult>
  readonly sendMessage: (
    input: SendMessageParams,
    context: BotOperationContext,
  ) => Promise<SendMessageResult>
  readonly getChat: (
    input: GetChatParams,
    context: BotOperationContext,
  ) => Promise<GetChatResult>
  readonly getChatHistory: (
    input: GetChatHistoryParams,
    context: BotOperationContext,
  ) => Promise<GetChatHistoryResult>
  readonly editMessageText: (
    input: EditMessageTextParams,
    context: BotOperationContext,
  ) => Promise<SendMessageResult>
  readonly deleteMessage: (
    input: DeleteMessageParams,
    context: BotOperationContext,
  ) => Promise<EmptyResult>
  readonly sendReaction: (
    input: SendReactionParams,
    context: BotOperationContext,
  ) => Promise<EmptyResult>
  readonly getMyCommands: (
    context: BotOperationContext,
  ) => Promise<GetMyCommandsResult>
  readonly setMyCommands: (
    input: SetMyCommandsParams,
    context: BotOperationContext,
  ) => Promise<EmptyResult>
  readonly deleteMyCommands: (
    context: BotOperationContext,
  ) => Promise<EmptyResult>
}

const publicError = (
  error: (typeof InlineError.ApiError)[
    keyof typeof InlineError.ApiError
  ],
): BotPublicError =>
  new BotPublicError({
    error: error[0],
    errorCode: error[1],
    description: error[2],
  })

const classifyFailure = (
  operation: BotOperation,
  cause: unknown,
): BotOperationError => {
  if (cause instanceof InlineError) {
    const error = new BotPublicError({
      error: cause.type,
      errorCode: cause.code,
      description:
        cause.description ?? "Internal server error happened",
    })
    return cause.code < 500
      ? error
      : new BotOperationFailure({
          operation,
          cause,
          publicError: error,
        })
  }

  if (cause instanceof ModelError) {
    switch (cause.code) {
      case ModelError.Codes.CHAT_INVALID:
        return publicError(InlineError.ApiError.PEER_INVALID)
      case ModelError.Codes.MESSAGE_INVALID:
        return publicError(
          InlineError.ApiError.MSG_ID_INVALID,
        )
      default:
        return new BotOperationFailure({
          operation,
          cause,
        })
    }
  }

  if (RealtimeRpcError.is(cause)) {
    switch (cause.code) {
      case RealtimeRpcError.Code.UNAUTHENTICATED:
        return publicError(InlineError.ApiError.UNAUTHORIZED)
      case RealtimeRpcError.Code.PEER_ID_INVALID:
        return publicError(InlineError.ApiError.PEER_INVALID)
      case RealtimeRpcError.Code.MESSAGE_ID_INVALID:
        return publicError(
          InlineError.ApiError.MSG_ID_INVALID,
        )
      case RealtimeRpcError.Code.CHAT_ID_INVALID:
        return publicError(
          InlineError.ApiError.CHAT_ID_INVALID,
        )
      case RealtimeRpcError.Code.USER_ID_INVALID:
        return publicError(InlineError.ApiError.USER_INVALID)
      case RealtimeRpcError.Code.BAD_REQUEST:
        return publicError(InlineError.ApiError.BAD_REQUEST)
      default:
        return new BotOperationFailure({
          operation,
          cause,
        })
    }
  }

  return new BotOperationFailure({
    operation,
    cause,
  })
}

const adapt = <Result>(
  operation: BotOperation,
  run: () => Promise<Result>,
): Effect.Effect<Result, BotOperationError> =>
  Effect.tryPromise({
    try: run,
    catch: (cause) => classifyFailure(operation, cause),
  })

export const makeBotOperations = (
  handlers: BotOperationHandlers,
): BotOperationsShape => ({
  getMe: (context) =>
    adapt("getMe", () => handlers.getMe(context)),
  sendMessage: (input, context) =>
    adapt("sendMessage", () =>
      handlers.sendMessage(input, context),
    ),
  getChat: (input, context) =>
    adapt("getChat", () =>
      handlers.getChat(input, context),
    ),
  getChatHistory: (input, context) =>
    adapt("getChatHistory", () =>
      handlers.getChatHistory(input, context),
    ),
  editMessageText: (input, context) =>
    adapt("editMessageText", () =>
      handlers.editMessageText(input, context),
    ),
  deleteMessage: (input, context) =>
    adapt("deleteMessage", () =>
      handlers.deleteMessage(input, context),
    ),
  sendReaction: (input, context) =>
    adapt("sendReaction", () =>
      handlers.sendReaction(input, context),
    ),
  getMyCommands: (context) =>
    adapt("getMyCommands", () =>
      handlers.getMyCommands(context),
    ),
  setMyCommands: (input, context) =>
    adapt("setMyCommands", () =>
      handlers.setMyCommands(input, context),
    ),
  deleteMyCommands: (context) =>
    adapt("deleteMyCommands", () =>
      handlers.deleteMyCommands(context),
    ),
})
