import { Schema } from "effect"
import {
  CreateLinearIssueResult,
  CreateNotionTaskResult,
  DeleteAttachmentResult,
  DisconnectIntegrationResult,
  GetIntegrationsResult,
  GetLinearTeamsResult,
  GetNotionDatabasesResult,
  type CreateLinearIssueInput,
  type CreateNotionTaskInput,
  type DeleteAttachmentInput,
  type DisconnectIntegrationInput,
  type GetIntegrationsInput,
  type GetLinearTeamsInput,
  type GetNotionDatabasesInput,
  type SaveLinearTeamIdInput,
  type SaveNotionDatabaseIdInput,
} from "./v1ProviderSchemas.effect"
import type { V1MessagingProvidersContext } from "./v1MessagingOperations.effect"
import { invokeLegacyV1Operation } from "./v1MessagingProvidersOperationsAdapter.effect"
import type { V1ProviderOperationsShape } from "./v1ProviderOperations.effect"

export interface LegacyV1ProviderOperations {
  readonly authorizeLinearIssue: (
    input: CreateLinearIssueInput,
    context: V1MessagingProvidersContext,
  ) => Promise<void>
  readonly authorizeNotionTask: (
    input: CreateNotionTaskInput,
    context: V1MessagingProvidersContext,
  ) => Promise<void>
  readonly authorizeNotionSpace: (
    input: GetNotionDatabasesInput,
    context: V1MessagingProvidersContext,
  ) => Promise<void>
  readonly createLinearIssue: (
    input: CreateLinearIssueInput,
    context: V1MessagingProvidersContext,
  ) => Promise<unknown>
  readonly createNotionTask: (
    input: CreateNotionTaskInput,
    context: V1MessagingProvidersContext,
  ) => Promise<unknown>
  readonly deleteAttachment: (
    input: DeleteAttachmentInput,
    context: V1MessagingProvidersContext,
  ) => Promise<unknown>
  readonly disconnectIntegration: (
    input: DisconnectIntegrationInput,
    context: V1MessagingProvidersContext,
  ) => Promise<unknown>
  readonly getIntegrations: (
    input: GetIntegrationsInput,
    context: V1MessagingProvidersContext,
  ) => Promise<unknown>
  readonly getLinearTeams: (
    input: GetLinearTeamsInput,
    context: V1MessagingProvidersContext,
  ) => Promise<unknown>
  readonly getNotionDatabases: (
    input: GetNotionDatabasesInput,
    context: V1MessagingProvidersContext,
  ) => Promise<unknown>
  readonly saveLinearTeamId: (
    input: SaveLinearTeamIdInput,
    context: V1MessagingProvidersContext,
  ) => Promise<unknown>
  readonly saveNotionDatabaseId: (
    input: SaveNotionDatabaseIdInput,
    context: V1MessagingProvidersContext,
  ) => Promise<unknown>
}

export const makeV1ProviderOperations = (legacy: LegacyV1ProviderOperations): V1ProviderOperationsShape => ({
  createLinearIssue: (input, context) =>
    invokeLegacyV1Operation("v1.createLinearIssue", CreateLinearIssueResult, async () => {
      await legacy.authorizeLinearIssue(input, context)
      return legacy.createLinearIssue(input, context)
    }),
  createNotionTask: (input, context) =>
    invokeLegacyV1Operation("v1.createNotionTask", CreateNotionTaskResult, async () => {
      await legacy.authorizeNotionTask(input, context)
      return legacy.createNotionTask(input, context)
    }),
  deleteAttachment: (input, context) =>
    invokeLegacyV1Operation("v1.deleteAttachment", DeleteAttachmentResult, () =>
      legacy.deleteAttachment(input, context),
    ),
  disconnectIntegration: (input, context) =>
    invokeLegacyV1Operation("v1.disconnectIntegration", DisconnectIntegrationResult, () =>
      legacy.disconnectIntegration(input, context),
    ),
  getIntegrations: (input, context) =>
    invokeLegacyV1Operation("v1.getIntegrations", GetIntegrationsResult, () =>
      legacy.getIntegrations(input, context),
    ),
  getLinearTeams: (input, context) =>
    invokeLegacyV1Operation("v1.getLinearTeams", GetLinearTeamsResult, () =>
      legacy.getLinearTeams(input, context),
    ),
  getNotionDatabases: (input, context) =>
    invokeLegacyV1Operation("v1.getNotionDatabases", GetNotionDatabasesResult, async () => {
      await legacy.authorizeNotionSpace(input, context)
      return legacy.getNotionDatabases(input, context)
    }),
  saveLinearTeamId: (input, context) =>
    invokeLegacyV1Operation("v1.saveLinearTeamId", Schema.Undefined, () =>
      legacy.saveLinearTeamId(input, context),
    ),
  saveNotionDatabaseId: (input, context) =>
    invokeLegacyV1Operation("v1.saveNotionDatabaseId", Schema.Undefined, () =>
      legacy.saveNotionDatabaseId(input, context),
    ),
})
