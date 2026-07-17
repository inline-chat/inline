import { Context, Effect } from "effect"
import type { V1MessagingProvidersContext } from "./v1MessagingOperations.effect"
import type { V1MessagingProvidersOperationError } from "./v1MessagingProvidersErrors.effect"
import type {
  CreateLinearIssueInput,
  CreateLinearIssueResult,
  CreateNotionTaskInput,
  CreateNotionTaskResult,
  DeleteAttachmentInput,
  DeleteAttachmentResult,
  DisconnectIntegrationInput,
  DisconnectIntegrationResult,
  GetIntegrationsInput,
  GetIntegrationsResult,
  GetLinearTeamsInput,
  GetLinearTeamsResult,
  GetNotionDatabasesInput,
  GetNotionDatabasesResult,
  SaveLinearTeamIdInput,
  SaveNotionDatabaseIdInput,
} from "./v1ProviderSchemas.effect"

export interface V1ProviderOperationsShape {
  readonly createLinearIssue: (
    input: CreateLinearIssueInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<CreateLinearIssueResult, V1MessagingProvidersOperationError>
  readonly createNotionTask: (
    input: CreateNotionTaskInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<CreateNotionTaskResult, V1MessagingProvidersOperationError>
  readonly deleteAttachment: (
    input: DeleteAttachmentInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<DeleteAttachmentResult, V1MessagingProvidersOperationError>
  readonly disconnectIntegration: (
    input: DisconnectIntegrationInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<DisconnectIntegrationResult, V1MessagingProvidersOperationError>
  readonly getIntegrations: (
    input: GetIntegrationsInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<GetIntegrationsResult, V1MessagingProvidersOperationError>
  readonly getLinearTeams: (
    input: GetLinearTeamsInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<GetLinearTeamsResult, V1MessagingProvidersOperationError>
  readonly getNotionDatabases: (
    input: GetNotionDatabasesInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<GetNotionDatabasesResult, V1MessagingProvidersOperationError>
  readonly saveLinearTeamId: (
    input: SaveLinearTeamIdInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<void, V1MessagingProvidersOperationError>
  readonly saveNotionDatabaseId: (
    input: SaveNotionDatabaseIdInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<void, V1MessagingProvidersOperationError>
}

export class V1ProviderOperations extends Context.Service<
  V1ProviderOperations,
  V1ProviderOperationsShape
>()("@inline/server/v1/V1ProviderOperations") {}

