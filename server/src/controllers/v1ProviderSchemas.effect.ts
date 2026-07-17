import { Schema } from "effect"
import {
  ChatId,
  MessageId,
  SpaceId,
  UserId,
} from "../core/schema/identifiers"
import { WirePositiveInteger } from "../core/schema/scalars"
import { V1InputId } from "./v1IdentitySpacesSchemas.effect"
import { V1InputPeerInfo } from "./v1MessagingSchemas.effect"

export const LinearTeamId = Schema.String.pipe(Schema.brand("LinearTeamId")).annotate({
  identifier: "LinearTeamId",
  description: "A Linear workspace team identifier",
})
export type LinearTeamId = typeof LinearTeamId.Type

export const NotionDatabaseId = Schema.String.pipe(Schema.brand("NotionDatabaseId")).annotate({
  identifier: "NotionDatabaseId",
  description: "A Notion database or data-source identifier",
})
export type NotionDatabaseId = typeof NotionDatabaseId.Type

export const CreateLinearIssueInput = Schema.Struct({
  text: Schema.String,
  messageId: MessageId,
  chatId: ChatId,
  peerId: V1InputPeerInfo,
  fromId: UserId,
  spaceId: Schema.optionalKey(SpaceId),
}).annotate({ identifier: "CreateLinearIssueInput" })
export type CreateLinearIssueInput = typeof CreateLinearIssueInput.Type
export const CreateLinearIssueResult = Schema.Struct({
  link: Schema.optionalKey(Schema.NullOr(Schema.String)),
}).annotate({ identifier: "CreateLinearIssueResult" })
export type CreateLinearIssueResult = typeof CreateLinearIssueResult.Type

export const CreateNotionTaskInput = Schema.Struct({
  spaceId: SpaceId,
  messageId: MessageId,
  chatId: ChatId,
  peerId: V1InputPeerInfo,
}).annotate({ identifier: "CreateNotionTaskInput" })
export type CreateNotionTaskInput = typeof CreateNotionTaskInput.Type
export const CreateNotionTaskResult = Schema.Struct({
  url: Schema.String,
  taskTitle: Schema.NullOr(Schema.String),
}).annotate({ identifier: "CreateNotionTaskResult" })
export type CreateNotionTaskResult = typeof CreateNotionTaskResult.Type

export const DeleteAttachmentInput = Schema.Struct({
  externalTaskId: WirePositiveInteger,
  pageId: Schema.String,
  messageId: MessageId,
  chatId: ChatId,
}).annotate({ identifier: "DeleteAttachmentInput" })
export type DeleteAttachmentInput = typeof DeleteAttachmentInput.Type
export const DeleteAttachmentResult = Schema.Struct({
  success: Schema.Boolean,
}).annotate({ identifier: "DeleteAttachmentResult" })
export type DeleteAttachmentResult = typeof DeleteAttachmentResult.Type

export const DisconnectIntegrationInput = Schema.Struct({
  spaceId: SpaceId,
  provider: Schema.Literals(["notion", "linear"]),
}).annotate({ identifier: "DisconnectIntegrationInput" })
export type DisconnectIntegrationInput = typeof DisconnectIntegrationInput.Type
export const DisconnectIntegrationResult = Schema.Struct({
  ok: Schema.Boolean,
}).annotate({ identifier: "DisconnectIntegrationResult" })
export type DisconnectIntegrationResult = typeof DisconnectIntegrationResult.Type

export const GetIntegrationsInput = Schema.Struct({
  userId: V1InputId,
  spaceId: Schema.optionalKey(V1InputId),
}).annotate({ identifier: "GetIntegrationsInput" })
export type GetIntegrationsInput = typeof GetIntegrationsInput.Type
const IntegrationSpace = Schema.Struct({
  spaceId: SpaceId,
  spaceName: Schema.String,
})
export const GetIntegrationsResult = Schema.Struct({
  hasLinearConnected: Schema.Boolean,
  hasNotionConnected: Schema.Boolean,
  hasIntegrationAccess: Schema.Boolean,
  linearTeamId: Schema.optionalKey(LinearTeamId),
  notionDatabaseId: Schema.optionalKey(NotionDatabaseId),
  notionSpaces: Schema.optionalKey(Schema.Array(IntegrationSpace)),
  linearSpaces: Schema.optionalKey(Schema.Array(IntegrationSpace)),
}).annotate({ identifier: "GetIntegrationsResult" })
export type GetIntegrationsResult = typeof GetIntegrationsResult.Type

export const GetLinearTeamsInput = Schema.Struct({
  spaceId: SpaceId,
}).annotate({ identifier: "GetLinearTeamsInput" })
export type GetLinearTeamsInput = typeof GetLinearTeamsInput.Type
export const GetLinearTeamsResult = Schema.Array(
  Schema.Struct({
    id: LinearTeamId,
    name: Schema.String,
    key: Schema.String,
  }),
).annotate({ identifier: "GetLinearTeamsResult" })
export type GetLinearTeamsResult = typeof GetLinearTeamsResult.Type

export const GetNotionDatabasesInput = Schema.Struct({
  spaceId: SpaceId,
}).annotate({ identifier: "GetNotionDatabasesInput" })
export type GetNotionDatabasesInput = typeof GetNotionDatabasesInput.Type
export const GetNotionDatabasesResult = Schema.Array(
  Schema.Struct({
    id: NotionDatabaseId,
    title: Schema.String,
    icon: Schema.optionalKey(Schema.String),
  }),
).annotate({ identifier: "GetNotionDatabasesResult" })
export type GetNotionDatabasesResult = typeof GetNotionDatabasesResult.Type

export const SaveLinearTeamIdInput = Schema.Struct({
  spaceId: Schema.String,
  teamId: LinearTeamId,
}).annotate({ identifier: "SaveLinearTeamIdInput" })
export type SaveLinearTeamIdInput = typeof SaveLinearTeamIdInput.Type

export const SaveNotionDatabaseIdInput = Schema.Struct({
  spaceId: Schema.String,
  databaseId: NotionDatabaseId,
}).annotate({ identifier: "SaveNotionDatabaseIdInput" })
export type SaveNotionDatabaseIdInput = typeof SaveNotionDatabaseIdInput.Type

export const V1ProviderEmptyResult = Schema.Undefined
