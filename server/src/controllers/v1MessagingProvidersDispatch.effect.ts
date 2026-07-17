import { Effect, Schema } from "effect"
import {
  AddReactionInput,
  CreatePrivateChatInput,
  CreateThreadInput,
  DeleteMessageInput,
  GetAlphaTextInput,
  GetChatHistoryInput,
  GetDialogsInput,
  GetDraftInput,
  GetPrivateChatsInput,
  ReadMessagesInput,
  SendComposeActionInput,
  SendMessage20250509Input,
  SendMessageInput,
  UpdateDialogInput,
} from "./v1MessagingSchemas.effect"
import type {
  V1MessagingOperationsShape,
  V1MessagingProvidersContext,
} from "./v1MessagingOperations.effect"
import type {
  V1MessagingProvidersOperationError,
} from "./v1MessagingProvidersErrors.effect"
import type {
  V1MessagingProvidersOperation,
} from "./v1MessagingProvidersContracts.effect"
import {
  CreateLinearIssueInput,
  CreateNotionTaskInput,
  DeleteAttachmentInput,
  DisconnectIntegrationInput,
  GetIntegrationsInput,
  GetLinearTeamsInput,
  GetNotionDatabasesInput,
  SaveLinearTeamIdInput,
  SaveNotionDatabaseIdInput,
} from "./v1ProviderSchemas.effect"
import type {
  V1ProviderOperationsShape,
} from "./v1ProviderOperations.effect"
import {
  UploadFileInput,
} from "./v1UploadSchemas.effect"
import type {
  V1UploadOperationsShape,
} from "./v1UploadOperations.effect"

export interface V1MessagingProvidersServices {
  readonly messaging: V1MessagingOperationsShape
  readonly providers: V1ProviderOperationsShape
  readonly uploads: V1UploadOperationsShape
}

export interface PreparedV1MessagingProvidersOperation {
  readonly run: (
    context: V1MessagingProvidersContext,
    services: V1MessagingProvidersServices,
  ) => Effect.Effect<
    unknown,
    V1MessagingProvidersOperationError
  >
  readonly success: (value: unknown) => unknown
}

const withResult = <A>(value: A) => ({
  ok: true,
  result: value,
})

const emptySuccess = () => ({ ok: true })

const prepare = <Input, Output>(
  schema: Schema.Decoder<Input>,
  rawInput: unknown,
  run: (
    input: Input,
    context: V1MessagingProvidersContext,
    services: V1MessagingProvidersServices,
  ) => Effect.Effect<
    Output,
    V1MessagingProvidersOperationError
  >,
  success: (value: Output) => unknown = withResult,
): Effect.Effect<
  PreparedV1MessagingProvidersOperation,
  Schema.SchemaError
> =>
  Schema.decodeUnknownEffect(schema)(rawInput).pipe(
    Effect.map((input) => ({
      run: (context, services) =>
        run(input, context, services),
      success: (value) =>
        success(value as Output),
    })),
  )

/**
 * Decodes once before authentication, preserving the existing validation
 * precedence, and returns a typed operation closure for the authenticated
 * transport boundary.
 */
export const prepareV1MessagingProvidersOperation = (
  operation: V1MessagingProvidersOperation,
  rawInput: unknown,
): Effect.Effect<
  PreparedV1MessagingProvidersOperation,
  Schema.SchemaError
> => {
  switch (operation) {
    case "addReaction":
      return prepare(
        AddReactionInput,
        rawInput,
        (input, context, services) =>
          services.messaging.addReaction(
            input,
            context,
          ),
      )
    case "createLinearIssue":
      return prepare(
        CreateLinearIssueInput,
        rawInput,
        (input, context, services) =>
          services.providers.createLinearIssue(
            input,
            context,
          ),
      )
    case "createNotionTask":
      return prepare(
        CreateNotionTaskInput,
        rawInput,
        (input, context, services) =>
          services.providers.createNotionTask(
            input,
            context,
          ),
      )
    case "createPrivateChat":
      return prepare(
        CreatePrivateChatInput,
        rawInput,
        (input, context, services) =>
          services.messaging.createPrivateChat(
            input,
            context,
          ),
      )
    case "createThread":
      return prepare(
        CreateThreadInput,
        rawInput,
        (input, context, services) =>
          services.messaging.createThread(
            input,
            context,
          ),
      )
    case "deleteAttachment":
      return prepare(
        DeleteAttachmentInput,
        rawInput,
        (input, context, services) =>
          services.providers.deleteAttachment(
            input,
            context,
          ),
      )
    case "deleteMessage":
      return prepare(
        DeleteMessageInput,
        rawInput,
        (input, context, services) =>
          services.messaging.deleteMessage(
            input,
            context,
          ),
        emptySuccess,
      )
    case "disconnectIntegration":
      return prepare(
        DisconnectIntegrationInput,
        rawInput,
        (input, context, services) =>
          services.providers.disconnectIntegration(
            input,
            context,
          ),
      )
    case "getAlphaText":
      return prepare(
        GetAlphaTextInput,
        rawInput,
        (input, context, services) =>
          services.messaging.getAlphaText(
            input,
            context,
          ),
      )
    case "getChatHistory":
      return prepare(
        GetChatHistoryInput,
        rawInput,
        (input, context, services) =>
          services.messaging.getChatHistory(
            input,
            context,
          ),
      )
    case "getDialogs":
      return prepare(
        GetDialogsInput,
        rawInput,
        (input, context, services) =>
          services.messaging.getDialogs(
            input,
            context,
          ),
      )
    case "getDraft":
      return prepare(
        GetDraftInput,
        rawInput,
        (input, context, services) =>
          services.messaging.getDraft(
            input,
            context,
          ),
      )
    case "getIntegrations":
      return prepare(
        GetIntegrationsInput,
        rawInput,
        (input, context, services) =>
          services.providers.getIntegrations(
            input,
            context,
          ),
      )
    case "getLinearTeams":
      return prepare(
        GetLinearTeamsInput,
        rawInput,
        (input, context, services) =>
          services.providers.getLinearTeams(
            input,
            context,
          ),
      )
    case "getNotionDatabases":
      return prepare(
        GetNotionDatabasesInput,
        rawInput,
        (input, context, services) =>
          services.providers.getNotionDatabases(
            input,
            context,
          ),
      )
    case "getPrivateChats":
      return prepare(
        GetPrivateChatsInput,
        rawInput,
        (input, context, services) =>
          services.messaging.getPrivateChats(
            input,
            context,
          ),
      )
    case "readMessages":
      return prepare(
        ReadMessagesInput,
        rawInput,
        (input, context, services) =>
          services.messaging.readMessages(
            input,
            context,
          ),
      )
    case "saveLinearTeamId":
      return prepare(
        SaveLinearTeamIdInput,
        rawInput,
        (input, context, services) =>
          services.providers.saveLinearTeamId(
            input,
            context,
          ),
        emptySuccess,
      )
    case "saveNotionDatabaseId":
      return prepare(
        SaveNotionDatabaseIdInput,
        rawInput,
        (input, context, services) =>
          services.providers.saveNotionDatabaseId(
            input,
            context,
          ),
        emptySuccess,
      )
    case "sendComposeAction":
      return prepare(
        SendComposeActionInput,
        rawInput,
        (input, context, services) =>
          services.messaging.sendComposeAction(
            input,
            context,
          ),
        emptySuccess,
      )
    case "sendMessage":
      return prepare(
        SendMessageInput,
        rawInput,
        (input, context, services) =>
          services.messaging.sendMessage(
            input,
            context,
          ),
      )
    case "sendMessage20250509":
      return prepare(
        SendMessage20250509Input,
        rawInput,
        (input, context, services) =>
          services.messaging.sendMessage20250509(
            input,
            context,
          ),
      )
    case "updateDialog":
      return prepare(
        UpdateDialogInput,
        rawInput,
        (input, context, services) =>
          services.messaging.updateDialog(
            input,
            context,
          ),
      )
    case "uploadFile":
      return prepare(
        UploadFileInput,
        rawInput,
        (input, context, services) =>
          services.uploads.uploadFile(
            input,
            context,
          ),
      )
  }
}
