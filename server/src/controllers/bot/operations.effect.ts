import type {
  CreateReplyThreadParams,
  CreateReplyThreadResult,
  CreateThreadParams,
  CreateThreadResult,
  AnswerMessageActionParams,
  DeleteReactionParams,
  DeleteWebhookParams,
  DeleteWebhookResult,
  DeleteMessageParams,
  EditMessageTextParams,
  EmptyResult,
  ForwardMessageParams,
  ForwardMessageResult,
  GetChatHistoryParams,
  GetChatHistoryResult,
  GetChatParams,
  GetChatResult,
  GetFileParams,
  GetFileResult,
  GetMeResult,
  CreateAgentParams,
  CreateAgentResult,
  GetAgentParams,
  GetAgentResult,
  GetMyAgentsResult,
  GetMessagesParams,
  GetMessagesResult,
  GetUpdatesParams,
  GetUpdatesResult,
  GetWebhookInfoResult,
  GetMyCommandsResult,
  GetChatParticipantParams,
  GetChatParticipantResult,
  GetChatParticipantCountParams,
  GetChatParticipantCountResult,
  PinMessageParams,
  SendMessageParams,
  SendMessageResult,
  SendReactionParams,
  SendChatActionParams,
  SearchMessagesParams,
  SearchMessagesResult,
  SetMyCommandsParams,
  SetThreadTitleParams,
  SetWebhookParams,
  SetWebhookResult,
  UnpinMessageParams,
  UploadFileResult,
} from "@inline-chat/bot-api-types"
import type { UploadFileOperationInput } from "@in/server/methods/uploadFileOperation"
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
  | "createAgent"
  | "getAgent"
  | "getMyAgents"
  | "sendMessage"
  | "getChat"
  | "getChatHistory"
  | "getMessages"
  | "searchMessages"
  | "createThread"
  | "createReplyThread"
  | "editMessageText"
  | "deleteMessage"
  | "sendReaction"
  | "deleteReaction"
  | "answerMessageAction"
  | "sendChatAction"
  | "getFile"
  | "getUpdates"
  | "setWebhook"
  | "deleteWebhook"
  | "getWebhookInfo"
  | "getMyCommands"
  | "setMyCommands"
  | "deleteMyCommands"
  | "forwardMessage"
  | "pinMessage"
  | "unpinMessage"
  | "getChatParticipant"
  | "getChatParticipantCount"
  | "setThreadTitle"
  | "uploadFile"

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
  readonly createAgent: (input: CreateAgentParams, context: BotOperationContext) => Effect.Effect<CreateAgentResult, BotOperationError>
  readonly getAgent: (input: GetAgentParams, context: BotOperationContext) => Effect.Effect<GetAgentResult, BotOperationError>
  readonly getMyAgents: (context: BotOperationContext) => Effect.Effect<GetMyAgentsResult, BotOperationError>
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
  readonly getMessages: (
    input: GetMessagesParams,
    context: BotOperationContext,
  ) => Effect.Effect<GetMessagesResult, BotOperationError>
  readonly searchMessages: (
    input: SearchMessagesParams,
    context: BotOperationContext,
  ) => Effect.Effect<SearchMessagesResult, BotOperationError>
  readonly createThread: (
    input: CreateThreadParams,
    context: BotOperationContext,
  ) => Effect.Effect<CreateThreadResult, BotOperationError>
  readonly createReplyThread: (
    input: CreateReplyThreadParams,
    context: BotOperationContext,
  ) => Effect.Effect<CreateReplyThreadResult, BotOperationError>
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
  readonly deleteReaction: (input: DeleteReactionParams, context: BotOperationContext) => Effect.Effect<EmptyResult, BotOperationError>
  readonly answerMessageAction: (input: AnswerMessageActionParams, context: BotOperationContext) => Effect.Effect<EmptyResult, BotOperationError>
  readonly sendChatAction: (input: SendChatActionParams, context: BotOperationContext) => Effect.Effect<EmptyResult, BotOperationError>
  readonly getFile: (input: GetFileParams, context: BotOperationContext) => Effect.Effect<GetFileResult, BotOperationError>
  readonly getUpdates: (input: GetUpdatesParams, context: BotOperationContext) => Effect.Effect<GetUpdatesResult, BotOperationError>
  readonly setWebhook: (input: SetWebhookParams, context: BotOperationContext) => Effect.Effect<SetWebhookResult, BotOperationError>
  readonly deleteWebhook: (input: DeleteWebhookParams, context: BotOperationContext) => Effect.Effect<DeleteWebhookResult, BotOperationError>
  readonly getWebhookInfo: (context: BotOperationContext) => Effect.Effect<GetWebhookInfoResult, BotOperationError>
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
  readonly forwardMessage: (input: ForwardMessageParams, context: BotOperationContext) => Effect.Effect<ForwardMessageResult, BotOperationError>
  readonly pinMessage: (input: PinMessageParams, context: BotOperationContext) => Effect.Effect<EmptyResult, BotOperationError>
  readonly unpinMessage: (input: UnpinMessageParams, context: BotOperationContext) => Effect.Effect<EmptyResult, BotOperationError>
  readonly getChatParticipant: (input: GetChatParticipantParams, context: BotOperationContext) => Effect.Effect<GetChatParticipantResult, BotOperationError>
  readonly getChatParticipantCount: (input: GetChatParticipantCountParams, context: BotOperationContext) => Effect.Effect<GetChatParticipantCountResult, BotOperationError>
  readonly setThreadTitle: (input: SetThreadTitleParams, context: BotOperationContext) => Effect.Effect<EmptyResult, BotOperationError>
  readonly uploadFile: (input: UploadFileOperationInput, context: BotOperationContext) => Effect.Effect<UploadFileResult, BotOperationError>
}

export class BotOperations extends Context.Service<
  BotOperations,
  BotOperationsShape
>()("@inline/server/bot/BotOperations") {}

export interface BotOperationHandlers {
  readonly getMe: (
    context: BotOperationContext,
  ) => Promise<GetMeResult>
  readonly createAgent: (input: CreateAgentParams, context: BotOperationContext) => Promise<CreateAgentResult>
  readonly getAgent: (input: GetAgentParams, context: BotOperationContext) => Promise<GetAgentResult>
  readonly getMyAgents: (context: BotOperationContext) => Promise<GetMyAgentsResult>
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
  readonly getMessages: (
    input: GetMessagesParams,
    context: BotOperationContext,
  ) => Promise<GetMessagesResult>
  readonly searchMessages: (
    input: SearchMessagesParams,
    context: BotOperationContext,
  ) => Promise<SearchMessagesResult>
  readonly createThread: (
    input: CreateThreadParams,
    context: BotOperationContext,
  ) => Promise<CreateThreadResult>
  readonly createReplyThread: (
    input: CreateReplyThreadParams,
    context: BotOperationContext,
  ) => Promise<CreateReplyThreadResult>
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
  readonly deleteReaction: (input: DeleteReactionParams, context: BotOperationContext) => Promise<EmptyResult>
  readonly answerMessageAction: (input: AnswerMessageActionParams, context: BotOperationContext) => Promise<EmptyResult>
  readonly sendChatAction: (input: SendChatActionParams, context: BotOperationContext) => Promise<EmptyResult>
  readonly getFile: (input: GetFileParams, context: BotOperationContext) => Promise<GetFileResult>
  readonly getUpdates: (input: GetUpdatesParams, context: BotOperationContext) => Promise<GetUpdatesResult>
  readonly setWebhook: (input: SetWebhookParams, context: BotOperationContext) => Promise<SetWebhookResult>
  readonly deleteWebhook: (input: DeleteWebhookParams, context: BotOperationContext) => Promise<DeleteWebhookResult>
  readonly getWebhookInfo: (context: BotOperationContext) => Promise<GetWebhookInfoResult>
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
  readonly forwardMessage: (input: ForwardMessageParams, context: BotOperationContext) => Promise<ForwardMessageResult>
  readonly pinMessage: (input: PinMessageParams, context: BotOperationContext) => Promise<EmptyResult>
  readonly unpinMessage: (input: UnpinMessageParams, context: BotOperationContext) => Promise<EmptyResult>
  readonly getChatParticipant: (input: GetChatParticipantParams, context: BotOperationContext) => Promise<GetChatParticipantResult>
  readonly getChatParticipantCount: (input: GetChatParticipantCountParams, context: BotOperationContext) => Promise<GetChatParticipantCountResult>
  readonly setThreadTitle: (input: SetThreadTitleParams, context: BotOperationContext) => Promise<EmptyResult>
  readonly uploadFile: (input: UploadFileOperationInput, context: BotOperationContext) => Promise<UploadFileResult>
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
  createAgent: (input, context) => adapt("createAgent", () => handlers.createAgent(input, context)),
  getAgent: (input, context) => adapt("getAgent", () => handlers.getAgent(input, context)),
  getMyAgents: (context) => adapt("getMyAgents", () => handlers.getMyAgents(context)),
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
  getMessages: (input, context) =>
    adapt("getMessages", () => handlers.getMessages(input, context)),
  searchMessages: (input, context) =>
    adapt("searchMessages", () => handlers.searchMessages(input, context)),
  createThread: (input, context) =>
    adapt("createThread", () => handlers.createThread(input, context)),
  createReplyThread: (input, context) =>
    adapt("createReplyThread", () => handlers.createReplyThread(input, context)),
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
  deleteReaction: (input, context) => adapt("deleteReaction", () => handlers.deleteReaction(input, context)),
  answerMessageAction: (input, context) => adapt("answerMessageAction", () => handlers.answerMessageAction(input, context)),
  sendChatAction: (input, context) => adapt("sendChatAction", () => handlers.sendChatAction(input, context)),
  getFile: (input, context) => adapt("getFile", () => handlers.getFile(input, context)),
  getUpdates: (input, context) => adapt("getUpdates", () => handlers.getUpdates(input, context)),
  setWebhook: (input, context) => adapt("setWebhook", () => handlers.setWebhook(input, context)),
  deleteWebhook: (input, context) => adapt("deleteWebhook", () => handlers.deleteWebhook(input, context)),
  getWebhookInfo: (context) => adapt("getWebhookInfo", () => handlers.getWebhookInfo(context)),
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
  forwardMessage: (input, context) => adapt("forwardMessage", () => handlers.forwardMessage(input, context)),
  pinMessage: (input, context) => adapt("pinMessage", () => handlers.pinMessage(input, context)),
  unpinMessage: (input, context) => adapt("unpinMessage", () => handlers.unpinMessage(input, context)),
  getChatParticipant: (input, context) => adapt("getChatParticipant", () => handlers.getChatParticipant(input, context)),
  getChatParticipantCount: (input, context) => adapt("getChatParticipantCount", () => handlers.getChatParticipantCount(input, context)),
  setThreadTitle: (input, context) => adapt("setThreadTitle", () => handlers.setThreadTitle(input, context)),
  uploadFile: (input, context) => adapt("uploadFile", () => handlers.uploadFile(input, context)),
})
