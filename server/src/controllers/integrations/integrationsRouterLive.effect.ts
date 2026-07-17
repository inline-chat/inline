import * as arctic from "arctic"
import { Layer } from "effect"
import { isProd } from "@in/server/env"
import {
  getLinearAuthUrl,
} from "@in/server/libs/linear"
import {
  getNotionAuthUrl,
  handleNotionCallback,
} from "@in/server/libs/notion"
import { InlineError } from "@in/server/types/errors"
import {
  Authorize,
} from "@in/server/utils/authorize"
import { handleLinearCallback } from "./handleLinearCallback"
import {
  IntegrationOperations,
  makeIntegrationOperations,
} from "./integrationsRouter.effect"

export const IntegrationOperationsLive = Layer.succeed(
  IntegrationOperations,
  makeIntegrationOperations({
    secureCookies: isProd,
    authorizeAdmin: Authorize.spaceAdmin,
    isAuthorizationRejected: (cause) =>
      cause instanceof InlineError &&
      cause.code < 500,
    generateState: arctic.generateState,
    linearAuthUrl: (state) => {
      const { url } = getLinearAuthUrl(state)
      return { url }
    },
    notionAuthUrl: (state) => {
      const { url, error } = getNotionAuthUrl(state)
      return {
        url: url?.toString(),
        error,
      }
    },
    linearCallback: handleLinearCallback,
    notionCallback: async (input) => {
      const result = await handleNotionCallback(input)
      return {
        ok: result.ok,
        ...("error" in result
          ? { error: result.error }
          : {}),
      }
    },
  }),
)
