import { Context, Effect } from "effect"
import type { SessionId, UserId } from "../core/schema/identifiers"
import type {
  AddReactionInput,
  AddReactionResult,
  CreatePrivateChatInput,
  CreatePrivateChatResult,
  CreateThreadInput,
  CreateThreadResult,
  DeleteMessageInput,
  GetAlphaTextInput,
  GetAlphaTextResult,
  GetChatHistoryInput,
  GetChatHistoryResult,
  GetDialogsInput,
  GetDialogsResult,
  GetDraftInput,
  GetDraftResult,
  GetPrivateChatsInput,
  GetPrivateChatsResult,
  ReadMessagesInput,
  ReadMessagesResult,
  SendComposeActionInput,
  SendMessage20250509Input,
  SendMessage20250509Result,
  SendMessageInput,
  SendMessageResult,
  UpdateDialogInput,
  UpdateDialogResult,
} from "./v1MessagingSchemas.effect"
import type { V1MessagingProvidersOperationError } from "./v1MessagingProvidersErrors.effect"

export interface V1MessagingProvidersContext {
  readonly currentUserId: UserId
  readonly currentSessionId: SessionId
  readonly ip: string | undefined
}

export interface V1MessagingOperationsShape {
  readonly addReaction: (
    input: AddReactionInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<AddReactionResult, V1MessagingProvidersOperationError>
  readonly createPrivateChat: (
    input: CreatePrivateChatInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<CreatePrivateChatResult, V1MessagingProvidersOperationError>
  readonly createThread: (
    input: CreateThreadInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<CreateThreadResult, V1MessagingProvidersOperationError>
  readonly deleteMessage: (
    input: DeleteMessageInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<void, V1MessagingProvidersOperationError>
  readonly getAlphaText: (
    input: GetAlphaTextInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<GetAlphaTextResult, V1MessagingProvidersOperationError>
  readonly getChatHistory: (
    input: GetChatHistoryInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<GetChatHistoryResult, V1MessagingProvidersOperationError>
  readonly getDialogs: (
    input: GetDialogsInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<GetDialogsResult, V1MessagingProvidersOperationError>
  readonly getDraft: (
    input: GetDraftInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<GetDraftResult, V1MessagingProvidersOperationError>
  readonly getPrivateChats: (
    input: GetPrivateChatsInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<GetPrivateChatsResult, V1MessagingProvidersOperationError>
  readonly readMessages: (
    input: ReadMessagesInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<ReadMessagesResult, V1MessagingProvidersOperationError>
  readonly sendComposeAction: (
    input: SendComposeActionInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<void, V1MessagingProvidersOperationError>
  readonly sendMessage: (
    input: SendMessageInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<SendMessageResult, V1MessagingProvidersOperationError>
  readonly sendMessage20250509: (
    input: SendMessage20250509Input,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<SendMessage20250509Result, V1MessagingProvidersOperationError>
  readonly updateDialog: (
    input: UpdateDialogInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<UpdateDialogResult, V1MessagingProvidersOperationError>
}

export class V1MessagingOperations extends Context.Service<
  V1MessagingOperations,
  V1MessagingOperationsShape
>()("@inline/server/v1/V1MessagingOperations") {}

