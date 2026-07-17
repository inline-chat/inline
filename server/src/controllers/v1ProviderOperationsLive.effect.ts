import { Layer } from "effect"
import { handler as createLinearIssueHandler } from "@in/server/methods/createLinearIssue"
import { handler as disconnectIntegrationHandler } from "@in/server/methods/disconnectIntegration"
import { handler as getIntegrationsHandler } from "@in/server/methods/getIntegrations"
import { handler as getLinearTeamsHandler } from "@in/server/methods/linear/getLinearTeams"
import { handler as saveLinearTeamIdHandler } from "@in/server/methods/linear/saveLinearTeamId"
import { handler as createNotionTaskHandler } from "@in/server/methods/notion/createNotionTask"
import { handler as deleteAttachmentHandler } from "@in/server/methods/notion/deleteNotionTask"
import { handler as getNotionDatabasesHandler } from "@in/server/methods/notion/getNotionDatabases"
import { handler as saveNotionDatabaseIdHandler } from "@in/server/methods/notion/saveNotionDatabaseId"
import { Authorize } from "@in/server/utils/authorize"
import { makeV1ProviderOperations } from "./v1ProviderOperationsAdapter.effect"
import { V1ProviderOperations } from "./v1ProviderOperations.effect"
import { authorizeProviderTask } from "./v1ProviderTaskAuthorizationLive"

// TODO(effect-cutover): replace retained SDK/database bindings as provider capabilities become Effect-native.
export const V1ProviderOperationsLive = Layer.succeed(
  V1ProviderOperations,
  makeV1ProviderOperations({
    // Intentional security correction: authorize the exact target before retained provider work.
    authorizeLinearIssue: authorizeProviderTask,
    authorizeNotionTask: authorizeProviderTask,
    authorizeNotionSpace: (input, context) =>
      Authorize.spaceMember(input.spaceId, context.currentUserId).then(() => undefined),
    // FIXME(effect-cutover): the retained Linear handler collapses provider and
    // persistence failures into a successful response with no link.
    createLinearIssue: (input, context) => createLinearIssueHandler({ ...input }, context),
    createNotionTask: (input, context) => createNotionTaskHandler({ ...input }, context),
    deleteAttachment: (input, context) => deleteAttachmentHandler({ ...input }, context),
    disconnectIntegration: (input, context) => disconnectIntegrationHandler({ ...input }, context),
    getIntegrations: (input, context) => getIntegrationsHandler({ ...input }, context),
    getLinearTeams: (input, context) => getLinearTeamsHandler({ ...input }, context),
    getNotionDatabases: (input, context) => getNotionDatabasesHandler({ ...input }, context),
    saveLinearTeamId: (input, context) => saveLinearTeamIdHandler({ ...input }, context),
    saveNotionDatabaseId: (input, context) => saveNotionDatabaseIdHandler({ ...input }, context),
  }),
)
