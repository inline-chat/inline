import { Schema } from "effect"
import { HttpApiEndpoint, HttpApiGroup, HttpApiSchema } from "effect/unstable/httpapi"
import { HttpStatusCode } from "../core/schema/scalars"
import { requireOpenApiRequestHeader } from "../core/http/openApi"
import {
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
import {
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
import { UploadFilePayload, UploadFileResult } from "./v1UploadSchemas.effect"

export const V1MessagingProvidersApiError = Schema.Struct({
  ok: Schema.Literal(false),
  error: Schema.String,
  errorCode: Schema.optionalKey(HttpStatusCode),
  description: Schema.optionalKey(Schema.String),
}).annotate({ identifier: "V1MessagingProvidersApiError" })

export const V1BotCompatApiError = Schema.Struct({
  ok: Schema.Literal(false),
  error: Schema.optionalKey(Schema.String),
  error_code: HttpStatusCode,
  description: Schema.String,
}).annotate({ identifier: "V1BotCompatApiError" })

const standardErrorAt = (status: number) => V1MessagingProvidersApiError.pipe(HttpApiSchema.status(status))
const phaseAwareErrorAt = (
  status: number,
) =>
  Schema.Union([
    V1MessagingProvidersApiError,
    V1BotCompatApiError,
  ]).pipe(HttpApiSchema.status(status))

const standardErrors = [
  standardErrorAt(400),
  standardErrorAt(401),
  standardErrorAt(403),
  standardErrorAt(404),
  standardErrorAt(420),
  standardErrorAt(500),
] as const

const phaseAwareBotCompatErrors = [
  phaseAwareErrorAt(400),
  phaseAwareErrorAt(401),
  phaseAwareErrorAt(403),
  phaseAwareErrorAt(404),
  phaseAwareErrorAt(420),
  phaseAwareErrorAt(500),
] as const

const success = <Result extends Schema.Top>(result: Result) =>
  Schema.Struct({
    ok: Schema.Literal(true),
    result,
  })

const emptySuccess = (identifier: string) =>
  Schema.Struct({
    ok: Schema.Literal(true),
  }).annotate({ identifier })

const AuthorizationHeader = {
  authorization: Schema.optionalKey(Schema.String),
} as const
const headerDescription = "Required session token using the Bearer scheme."

const postPayloads = <S extends Schema.Top>(schema: S) =>
  [schema, schema.pipe(HttpApiSchema.asFormUrlEncoded()), schema.pipe(HttpApiSchema.asMultipart())] as const

// TODO(effect-cutover): remove token-in-path GET variants after supported
// clients use the Authorization header; URL tokens leak into common logs.
const authenticatedEndpoints = <
  Name extends string,
  Method extends string,
  Fields extends Record<string, Schema.Top>,
  Success extends Schema.Top,
>(
  name: Name,
  method: Method,
  input: Schema.Struct<Fields>,
  successSchema: Success,
) => [
  HttpApiEndpoint.get(`get${name}`, `/v1/${method}`, {
    headers: AuthorizationHeader,
    payload: input.fields,
    success: successSchema,
    error: standardErrors,
  }).annotateMerge(requireOpenApiRequestHeader("authorization", headerDescription)),
  HttpApiEndpoint.get(`get${name}WithToken`, `/v1/:token/${method}`, {
    params: { token: Schema.String },
    payload: input.fields,
    success: successSchema,
    error: standardErrors,
  }),
  HttpApiEndpoint.post(`post${name}`, `/v1/${method}`, {
    headers: AuthorizationHeader,
    payload: postPayloads(input),
    success: successSchema,
    error: standardErrors,
  }).annotateMerge(requireOpenApiRequestHeader("authorization", headerDescription)),
] as const

const botCompatEndpoints = <
  Name extends string,
  Method extends string,
  Fields extends Record<string, Schema.Top>,
  Success extends Schema.Top,
>(
  name: Name,
  method: Method,
  input: Schema.Struct<Fields>,
  successSchema: Success,
) => [
  HttpApiEndpoint.get(`get${name}`, `/v1/${method}`, {
    headers: AuthorizationHeader,
    payload: input.fields,
    success: successSchema,
    error: phaseAwareBotCompatErrors,
  }).annotateMerge(requireOpenApiRequestHeader("authorization", headerDescription)),
  HttpApiEndpoint.get(`get${name}WithToken`, `/v1/:token/${method}`, {
    params: { token: Schema.String },
    payload: input.fields,
    success: successSchema,
    error: phaseAwareBotCompatErrors,
  }),
  HttpApiEndpoint.post(`post${name}`, `/v1/${method}`, {
    headers: AuthorizationHeader,
    payload: postPayloads(input),
    success: successSchema,
    error: phaseAwareBotCompatErrors,
  }).annotateMerge(requireOpenApiRequestHeader("authorization", headerDescription)),
] as const

const AddReactionEndpoints = authenticatedEndpoints(
  "AddReaction",
  "addReaction",
  AddReactionInput,
  success(AddReactionResult).annotate({ identifier: "AddReactionSuccess" }),
)
const CreateLinearIssueEndpoints = authenticatedEndpoints(
  "CreateLinearIssue",
  "createLinearIssue",
  CreateLinearIssueInput,
  success(CreateLinearIssueResult).annotate({ identifier: "CreateLinearIssueSuccess" }),
)
const CreateNotionTaskEndpoints = authenticatedEndpoints(
  "CreateNotionTask",
  "createNotionTask",
  CreateNotionTaskInput,
  success(CreateNotionTaskResult).annotate({ identifier: "CreateNotionTaskSuccess" }),
)
const CreatePrivateChatEndpoints = authenticatedEndpoints(
  "CreatePrivateChat",
  "createPrivateChat",
  CreatePrivateChatInput,
  success(CreatePrivateChatResult).annotate({ identifier: "CreatePrivateChatSuccess" }),
)
const CreateThreadEndpoints = authenticatedEndpoints(
  "CreateThread",
  "createThread",
  CreateThreadInput,
  success(CreateThreadResult).annotate({ identifier: "CreateThreadSuccess" }),
)
const DeleteAttachmentEndpoints = authenticatedEndpoints(
  "DeleteAttachment",
  "deleteAttachment",
  DeleteAttachmentInput,
  success(DeleteAttachmentResult).annotate({ identifier: "DeleteAttachmentSuccess" }),
)
const DeleteMessageEndpoints = authenticatedEndpoints(
  "DeleteMessage",
  "deleteMessage",
  DeleteMessageInput,
  emptySuccess("DeleteMessageSuccess"),
)
const DisconnectIntegrationEndpoints = authenticatedEndpoints(
  "DisconnectIntegration",
  "disconnectIntegration",
  DisconnectIntegrationInput,
  success(DisconnectIntegrationResult).annotate({ identifier: "DisconnectIntegrationSuccess" }),
)
const GetAlphaTextEndpoints = authenticatedEndpoints(
  "GetAlphaText",
  "getAlphaText",
  GetAlphaTextInput,
  success(GetAlphaTextResult).annotate({ identifier: "GetAlphaTextSuccess" }),
)
const GetChatHistoryEndpoints = authenticatedEndpoints(
  "GetChatHistory",
  "getChatHistory",
  GetChatHistoryInput,
  success(GetChatHistoryResult).annotate({ identifier: "GetChatHistorySuccess" }),
)
const GetDialogsEndpoints = authenticatedEndpoints(
  "GetDialogs",
  "getDialogs",
  GetDialogsInput,
  success(GetDialogsResult).annotate({ identifier: "GetDialogsSuccess" }),
)
const GetDraftEndpoints = authenticatedEndpoints(
  "GetDraft",
  "getDraft",
  GetDraftInput,
  success(GetDraftResult).annotate({ identifier: "GetDraftSuccess" }),
)
const GetIntegrationsEndpoints = authenticatedEndpoints(
  "GetIntegrations",
  "getIntegrations",
  GetIntegrationsInput,
  success(GetIntegrationsResult).annotate({ identifier: "GetIntegrationsSuccess" }),
)
const GetLinearTeamsEndpoints = authenticatedEndpoints(
  "GetLinearTeams",
  "getLinearTeams",
  GetLinearTeamsInput,
  success(GetLinearTeamsResult).annotate({ identifier: "GetLinearTeamsSuccess" }),
)
const GetNotionDatabasesEndpoints = authenticatedEndpoints(
  "GetNotionDatabases",
  "getNotionDatabases",
  GetNotionDatabasesInput,
  success(GetNotionDatabasesResult).annotate({ identifier: "GetNotionDatabasesSuccess" }),
)
const GetPrivateChatsEndpoints = authenticatedEndpoints(
  "GetPrivateChats",
  "getPrivateChats",
  GetPrivateChatsInput,
  success(GetPrivateChatsResult).annotate({ identifier: "GetPrivateChatsSuccess" }),
)
const ReadMessagesEndpoints = authenticatedEndpoints(
  "ReadMessages",
  "readMessages",
  ReadMessagesInput,
  success(ReadMessagesResult).annotate({ identifier: "ReadMessagesSuccess" }),
)
const SaveLinearTeamIdEndpoints = authenticatedEndpoints(
  "SaveLinearTeamId",
  "saveLinearTeamId",
  SaveLinearTeamIdInput,
  emptySuccess("SaveLinearTeamIdSuccess"),
)
const SaveNotionDatabaseIdEndpoints = authenticatedEndpoints(
  "SaveNotionDatabaseId",
  "saveNotionDatabaseId",
  SaveNotionDatabaseIdInput,
  emptySuccess("SaveNotionDatabaseIdSuccess"),
)
const SendComposeActionEndpoints = authenticatedEndpoints(
  "SendComposeAction",
  "sendComposeAction",
  SendComposeActionInput,
  emptySuccess("SendComposeActionSuccess"),
)
const SendMessageEndpoints = authenticatedEndpoints(
  "SendMessage",
  "sendMessage",
  SendMessageInput,
  success(SendMessageResult).annotate({ identifier: "SendMessageSuccess" }),
)
const SendMessage20250509Endpoints = botCompatEndpoints(
  "SendMessage20250509",
  "sendMessage20250509",
  SendMessage20250509Input,
  success(SendMessage20250509Result).annotate({ identifier: "SendMessage20250509Success" }),
)
const UpdateDialogEndpoints = authenticatedEndpoints(
  "UpdateDialog",
  "updateDialog",
  UpdateDialogInput,
  success(UpdateDialogResult).annotate({ identifier: "UpdateDialogSuccess" }),
)

const UploadFileEndpoint = HttpApiEndpoint.post("postUploadFile", "/v1/uploadFile", {
  headers: AuthorizationHeader,
  payload: UploadFilePayload,
  success: success(UploadFileResult).annotate({ identifier: "UploadFileSuccess" }),
  error: standardErrors,
}).annotateMerge(requireOpenApiRequestHeader("authorization", headerDescription))

export const V1MessagingProvidersApiGroup = HttpApiGroup.make("v1MessagingProviders").add(
  ...AddReactionEndpoints,
  ...CreateLinearIssueEndpoints,
  ...CreateNotionTaskEndpoints,
  ...CreatePrivateChatEndpoints,
  ...CreateThreadEndpoints,
  ...DeleteAttachmentEndpoints,
  ...DeleteMessageEndpoints,
  ...DisconnectIntegrationEndpoints,
  ...GetAlphaTextEndpoints,
  ...GetChatHistoryEndpoints,
  ...GetDialogsEndpoints,
  ...GetDraftEndpoints,
  ...GetIntegrationsEndpoints,
  ...GetLinearTeamsEndpoints,
  ...GetNotionDatabasesEndpoints,
  ...GetPrivateChatsEndpoints,
  ...ReadMessagesEndpoints,
  ...SaveLinearTeamIdEndpoints,
  ...SaveNotionDatabaseIdEndpoints,
  ...SendComposeActionEndpoints,
  ...SendMessageEndpoints,
  ...SendMessage20250509Endpoints,
  ...UpdateDialogEndpoints,
  UploadFileEndpoint,
)

export type V1MessagingProvidersOperation =
  | "addReaction"
  | "createLinearIssue"
  | "createNotionTask"
  | "createPrivateChat"
  | "createThread"
  | "deleteAttachment"
  | "deleteMessage"
  | "disconnectIntegration"
  | "getAlphaText"
  | "getChatHistory"
  | "getDialogs"
  | "getDraft"
  | "getIntegrations"
  | "getLinearTeams"
  | "getNotionDatabases"
  | "getPrivateChats"
  | "readMessages"
  | "saveLinearTeamId"
  | "saveNotionDatabaseId"
  | "sendComposeAction"
  | "sendMessage"
  | "sendMessage20250509"
  | "updateDialog"
  | "uploadFile"
