import { Effect } from "effect"
import { HttpServerRequest } from "effect/unstable/http"
import { HttpApiBuilder } from "effect/unstable/httpapi"
import { makePlatformApiBase, PLATFORM_API_ID } from "../core/http/openApi"
import { defineHttpRouteGroup } from "../core/http/routeGroup"
import { SessionAuthentication } from "./plugins.effect"
import {
  V1MessagingProvidersApiGroup,
  type V1MessagingProvidersOperation,
} from "./v1MessagingProvidersContracts.effect"
import { executeV1MessagingProviders } from "./v1MessagingProvidersExecution.effect"
import { V1MessagingOperations } from "./v1MessagingOperations.effect"
import { V1ProviderOperations } from "./v1ProviderOperations.effect"
import { V1UploadOperations } from "./v1UploadOperations.effect"

export const makeV1MessagingProvidersRouteGroup = () => {
  const api = makePlatformApiBase("https://api.inline.chat").add(V1MessagingProvidersApiGroup)
  const handlers = HttpApiBuilder.group(api, "v1MessagingProviders", (groupHandlers) =>
    Effect.gen(function* () {
      const services = yield* Effect.context<
        V1MessagingOperations | V1ProviderOperations | V1UploadOperations | SessionAuthentication
      >()
      const execute = (
        operation: V1MessagingProvidersOperation,
        request: HttpServerRequest.HttpServerRequest,
        pathToken?: string | undefined,
      ) =>
        Effect.provide(
          executeV1MessagingProviders(operation, request, {
            pathToken,
          }),
          services,
        )

      return groupHandlers
        .handleRaw("getAddReaction", ({ request }) => execute("addReaction", request))
        .handleRaw("getAddReactionWithToken", ({ params, request }) =>
          execute("addReaction", request, params.token),
        )
        .handleRaw("postAddReaction", ({ request }) => execute("addReaction", request))
        .handleRaw("getCreateLinearIssue", ({ request }) => execute("createLinearIssue", request))
        .handleRaw("getCreateLinearIssueWithToken", ({ params, request }) =>
          execute("createLinearIssue", request, params.token),
        )
        .handleRaw("postCreateLinearIssue", ({ request }) => execute("createLinearIssue", request))
        .handleRaw("getCreateNotionTask", ({ request }) => execute("createNotionTask", request))
        .handleRaw("getCreateNotionTaskWithToken", ({ params, request }) =>
          execute("createNotionTask", request, params.token),
        )
        .handleRaw("postCreateNotionTask", ({ request }) => execute("createNotionTask", request))
        .handleRaw("getCreatePrivateChat", ({ request }) => execute("createPrivateChat", request))
        .handleRaw("getCreatePrivateChatWithToken", ({ params, request }) =>
          execute("createPrivateChat", request, params.token),
        )
        .handleRaw("postCreatePrivateChat", ({ request }) => execute("createPrivateChat", request))
        .handleRaw("getCreateThread", ({ request }) => execute("createThread", request))
        .handleRaw("getCreateThreadWithToken", ({ params, request }) =>
          execute("createThread", request, params.token),
        )
        .handleRaw("postCreateThread", ({ request }) => execute("createThread", request))
        .handleRaw("getDeleteAttachment", ({ request }) => execute("deleteAttachment", request))
        .handleRaw("getDeleteAttachmentWithToken", ({ params, request }) =>
          execute("deleteAttachment", request, params.token),
        )
        .handleRaw("postDeleteAttachment", ({ request }) => execute("deleteAttachment", request))
        .handleRaw("getDeleteMessage", ({ request }) => execute("deleteMessage", request))
        .handleRaw("getDeleteMessageWithToken", ({ params, request }) =>
          execute("deleteMessage", request, params.token),
        )
        .handleRaw("postDeleteMessage", ({ request }) => execute("deleteMessage", request))
        .handleRaw("getDisconnectIntegration", ({ request }) => execute("disconnectIntegration", request))
        .handleRaw("getDisconnectIntegrationWithToken", ({ params, request }) =>
          execute("disconnectIntegration", request, params.token),
        )
        .handleRaw("postDisconnectIntegration", ({ request }) => execute("disconnectIntegration", request))
        .handleRaw("getGetAlphaText", ({ request }) => execute("getAlphaText", request))
        .handleRaw("getGetAlphaTextWithToken", ({ params, request }) =>
          execute("getAlphaText", request, params.token),
        )
        .handleRaw("postGetAlphaText", ({ request }) => execute("getAlphaText", request))
        .handleRaw("getGetChatHistory", ({ request }) => execute("getChatHistory", request))
        .handleRaw("getGetChatHistoryWithToken", ({ params, request }) =>
          execute("getChatHistory", request, params.token),
        )
        .handleRaw("postGetChatHistory", ({ request }) => execute("getChatHistory", request))
        .handleRaw("getGetDialogs", ({ request }) => execute("getDialogs", request))
        .handleRaw("getGetDialogsWithToken", ({ params, request }) =>
          execute("getDialogs", request, params.token),
        )
        .handleRaw("postGetDialogs", ({ request }) => execute("getDialogs", request))
        .handleRaw("getGetDraft", ({ request }) => execute("getDraft", request))
        .handleRaw("getGetDraftWithToken", ({ params, request }) =>
          execute("getDraft", request, params.token),
        )
        .handleRaw("postGetDraft", ({ request }) => execute("getDraft", request))
        .handleRaw("getGetIntegrations", ({ request }) => execute("getIntegrations", request))
        .handleRaw("getGetIntegrationsWithToken", ({ params, request }) =>
          execute("getIntegrations", request, params.token),
        )
        .handleRaw("postGetIntegrations", ({ request }) => execute("getIntegrations", request))
        .handleRaw("getGetLinearTeams", ({ request }) => execute("getLinearTeams", request))
        .handleRaw("getGetLinearTeamsWithToken", ({ params, request }) =>
          execute("getLinearTeams", request, params.token),
        )
        .handleRaw("postGetLinearTeams", ({ request }) => execute("getLinearTeams", request))
        .handleRaw("getGetNotionDatabases", ({ request }) => execute("getNotionDatabases", request))
        .handleRaw("getGetNotionDatabasesWithToken", ({ params, request }) =>
          execute("getNotionDatabases", request, params.token),
        )
        .handleRaw("postGetNotionDatabases", ({ request }) => execute("getNotionDatabases", request))
        .handleRaw("getGetPrivateChats", ({ request }) => execute("getPrivateChats", request))
        .handleRaw("getGetPrivateChatsWithToken", ({ params, request }) =>
          execute("getPrivateChats", request, params.token),
        )
        .handleRaw("postGetPrivateChats", ({ request }) => execute("getPrivateChats", request))
        .handleRaw("getReadMessages", ({ request }) => execute("readMessages", request))
        .handleRaw("getReadMessagesWithToken", ({ params, request }) =>
          execute("readMessages", request, params.token),
        )
        .handleRaw("postReadMessages", ({ request }) => execute("readMessages", request))
        .handleRaw("getSaveLinearTeamId", ({ request }) => execute("saveLinearTeamId", request))
        .handleRaw("getSaveLinearTeamIdWithToken", ({ params, request }) =>
          execute("saveLinearTeamId", request, params.token),
        )
        .handleRaw("postSaveLinearTeamId", ({ request }) => execute("saveLinearTeamId", request))
        .handleRaw("getSaveNotionDatabaseId", ({ request }) => execute("saveNotionDatabaseId", request))
        .handleRaw("getSaveNotionDatabaseIdWithToken", ({ params, request }) =>
          execute("saveNotionDatabaseId", request, params.token),
        )
        .handleRaw("postSaveNotionDatabaseId", ({ request }) => execute("saveNotionDatabaseId", request))
        .handleRaw("getSendComposeAction", ({ request }) => execute("sendComposeAction", request))
        .handleRaw("getSendComposeActionWithToken", ({ params, request }) =>
          execute("sendComposeAction", request, params.token),
        )
        .handleRaw("postSendComposeAction", ({ request }) => execute("sendComposeAction", request))
        .handleRaw("getSendMessage", ({ request }) => execute("sendMessage", request))
        .handleRaw("getSendMessageWithToken", ({ params, request }) =>
          execute("sendMessage", request, params.token),
        )
        .handleRaw("postSendMessage", ({ request }) => execute("sendMessage", request))
        .handleRaw("getSendMessage20250509", ({ request }) => execute("sendMessage20250509", request))
        .handleRaw("getSendMessage20250509WithToken", ({ params, request }) =>
          execute("sendMessage20250509", request, params.token),
        )
        .handleRaw("postSendMessage20250509", ({ request }) => execute("sendMessage20250509", request))
        .handleRaw("getUpdateDialog", ({ request }) => execute("updateDialog", request))
        .handleRaw("getUpdateDialogWithToken", ({ params, request }) =>
          execute("updateDialog", request, params.token),
        )
        .handleRaw("postUpdateDialog", ({ request }) => execute("updateDialog", request))
        .handleRaw("postUploadFile", ({ request }) => execute("uploadFile", request))
    }),
  )

  return defineHttpRouteGroup({
    apiId: PLATFORM_API_ID,
    document: "platform",
    group: V1MessagingProvidersApiGroup,
    handlers,
  })
}

export const V1MessagingProvidersRouteGroup = makeV1MessagingProvidersRouteGroup()

