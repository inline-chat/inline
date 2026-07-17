import { Effect, Schema } from "effect"
import {
  AddReactionResult,
  CreatePrivateChatResult,
  CreateThreadResult,
  GetAlphaTextResult,
  GetChatHistoryResult,
  GetDialogsResult,
  GetDraftResult,
  GetPrivateChatsResult,
  ReadMessagesResult,
  SendMessage20250509Result,
  SendMessageResult,
  UpdateDialogResult,
  type AddReactionInput,
  type CreatePrivateChatInput,
  type CreateThreadInput,
  type DeleteMessageInput,
  type GetChatHistoryInput,
  type GetDialogsInput,
  type GetDraftInput,
  type GetPrivateChatsInput,
  type ReadMessagesInput,
  type SendComposeActionInput,
  type SendMessage20250509Input,
  type SendMessageInput,
  type UpdateDialogInput,
} from "./v1MessagingSchemas.effect"
import type {
  V1MessagingOperationsShape,
  V1MessagingProvidersContext,
} from "./v1MessagingOperations.effect"
import { invokeLegacyV1Operation } from "./v1MessagingProvidersOperationsAdapter.effect"

export interface LegacyV1MessagingOperations {
  readonly addReaction: (input: AddReactionInput, context: V1MessagingProvidersContext) => Promise<unknown>
  readonly createPrivateChat: (
    input: CreatePrivateChatInput,
    context: V1MessagingProvidersContext,
  ) => Promise<unknown>
  readonly createThread: (input: CreateThreadInput, context: V1MessagingProvidersContext) => Promise<unknown>
  readonly deleteMessage: (input: DeleteMessageInput, context: V1MessagingProvidersContext) => Promise<unknown>
  readonly getChatHistory: (input: GetChatHistoryInput, context: V1MessagingProvidersContext) => Promise<unknown>
  readonly getDialogs: (input: GetDialogsInput, context: V1MessagingProvidersContext) => Promise<unknown>
  readonly getDraft: (input: GetDraftInput, context: V1MessagingProvidersContext) => Promise<unknown>
  readonly getPrivateChats: (input: GetPrivateChatsInput, context: V1MessagingProvidersContext) => Promise<unknown>
  readonly readMessages: (input: ReadMessagesInput, context: V1MessagingProvidersContext) => Promise<unknown>
  readonly sendComposeAction: (
    input: SendComposeActionInput,
    context: V1MessagingProvidersContext,
  ) => Promise<unknown>
  readonly sendMessage: (input: SendMessageInput, context: V1MessagingProvidersContext) => Promise<unknown>
  readonly sendMessage20250509: (
    input: SendMessage20250509Input,
    context: V1MessagingProvidersContext,
  ) => Promise<unknown>
  readonly updateDialog: (input: UpdateDialogInput, context: V1MessagingProvidersContext) => Promise<unknown>
}

// TODO(effect-cutover): remove this obsolete Alpha copy endpoint after client
// telemetry confirms no supported client calls getAlphaText.
export const alphaWelcomeText = `
**Welcome to Inline Alpha**

You're one of the very first users of Inline. Exciting to build the future of work chat with you! 

Things we'll be working on next (in no particular order):
- API to send messages 
- Faster image sending and loading
- Sending video 
- Managing private group chat participants
- Better representaion of spaces (supergroups) in the home UI 
- Sync for more events (eg. deleting messages)
- "Will Do" to create tasks in Notion via AI
- Magic translate via AI 
- Edit profile and photo on macOS 
- Edit message on macOS 
- Reactions on macOS 
- Translation for the app in Chinese 
- @mentions 

What we recently shipped:
- Group chats 
- Sign up via SMS 
- Invite via email, phone number, or username

Message to @mo or @dena if you hit a bug or need a feature.
`

export const getAlphaTextEffect = Effect.succeed(
  Schema.decodeUnknownSync(GetAlphaTextResult)(alphaWelcomeText),
)

export const makeV1MessagingOperations = (legacy: LegacyV1MessagingOperations): V1MessagingOperationsShape => ({
  addReaction: (input, context) =>
    invokeLegacyV1Operation("v1.addReaction", AddReactionResult, () => legacy.addReaction(input, context)),
  createPrivateChat: (input, context) =>
    invokeLegacyV1Operation("v1.createPrivateChat", CreatePrivateChatResult, () =>
      legacy.createPrivateChat(input, context),
    ),
  createThread: (input, context) =>
    invokeLegacyV1Operation("v1.createThread", CreateThreadResult, () => legacy.createThread(input, context)),
  deleteMessage: (input, context) =>
    invokeLegacyV1Operation("v1.deleteMessage", Schema.Undefined, () => legacy.deleteMessage(input, context)),
  getAlphaText: () => getAlphaTextEffect,
  getChatHistory: (input, context) =>
    invokeLegacyV1Operation("v1.getChatHistory", GetChatHistoryResult, () => legacy.getChatHistory(input, context)),
  getDialogs: (input, context) =>
    invokeLegacyV1Operation("v1.getDialogs", GetDialogsResult, () => legacy.getDialogs(input, context)),
  getDraft: (input, context) =>
    invokeLegacyV1Operation("v1.getDraft", GetDraftResult, () => legacy.getDraft(input, context)),
  getPrivateChats: (input, context) =>
    invokeLegacyV1Operation("v1.getPrivateChats", GetPrivateChatsResult, () => legacy.getPrivateChats(input, context)),
  readMessages: (input, context) =>
    invokeLegacyV1Operation("v1.readMessages", ReadMessagesResult, () => legacy.readMessages(input, context)),
  sendComposeAction: (input, context) =>
    invokeLegacyV1Operation("v1.sendComposeAction", Schema.Undefined, () =>
      legacy.sendComposeAction(input, context),
    ),
  sendMessage: (input, context) =>
    invokeLegacyV1Operation("v1.sendMessage", SendMessageResult, () => legacy.sendMessage(input, context)),
  sendMessage20250509: (input, context) =>
    invokeLegacyV1Operation("v1.sendMessage20250509", SendMessage20250509Result, () =>
      legacy.sendMessage20250509(input, context),
    ),
  updateDialog: (input, context) =>
    invokeLegacyV1Operation("v1.updateDialog", UpdateDialogResult, () => legacy.updateDialog(input, context)),
})
