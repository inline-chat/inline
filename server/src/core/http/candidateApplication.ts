import { Layer } from "effect"
import {
  AuthApiGroup,
} from "../../controllers/auth.effect"
import {
  AuthRouteGroupLive,
} from "../../controllers/authLive.effect"
import {
  AuxiliaryApiGroup,
} from "../../controllers/auxiliary.effect"
import {
  AuxiliaryRouteGroupLive,
} from "../../controllers/auxiliaryLive.effect"
import {
  AdminApiGroup,
} from "../../controllers/admin.effect"
import {
  AdminRouteGroupLive,
} from "../../controllers/adminLive.effect"
import {
  BotApiGroup,
} from "../../controllers/bot/bot.effect"
import {
  BotRouteGroupLive,
} from "../../controllers/bot/botLive.effect"
import {
  V1IdentitySpacesApiGroup,
} from "../../controllers/v1IdentitySpaces.effect"
import {
  V1IdentitySpacesRouteGroupLive,
} from "../../controllers/v1IdentitySpacesLive.effect"
import {
  V1MessagingProvidersApiGroup,
} from "../../controllers/v1MessagingProvidersContracts.effect"
import {
  V1MessagingProvidersRouteGroupLive,
} from "../../controllers/v1MessagingProvidersLive.effect"
import {
  defineExecutableHttpApi,
  makeHttpApplication,
} from "./application"
import type { HttpKernelMiddlewareOptions } from "./middleware"
import {
  defineOpenApiDocument,
  makeBotApiBase,
  makePlatformApiBase,
} from "./openApi"

export interface CandidateHttpApplicationOptions {
  readonly apiBaseUrl?: string | undefined
  readonly middleware: HttpKernelMiddlewareOptions
}

/**
 * Integration-owned aggregate of every accepted replacement route slice.
 *
 * The production entry remains `server/src/index.ts`; this graph is served by
 * the shadow listener and contract checks until final cutover.
 */
export const makeCandidateHttpApplication = ({
  apiBaseUrl = "https://api.inline.chat",
  middleware,
}: CandidateHttpApplicationOptions) => {
  const platformApi = makePlatformApiBase(apiBaseUrl)
    .add(AuthApiGroup)
    .add(V1IdentitySpacesApiGroup)
    .add(V1MessagingProvidersApiGroup)
    .add(AuxiliaryApiGroup)
    .add(AdminApiGroup)
  const botApi = makeBotApiBase(apiBaseUrl)
    .add(BotApiGroup)

  return makeHttpApplication({
    platform: defineExecutableHttpApi({
      ...defineOpenApiDocument({
        api: platformApi,
        jsonPath: "/v1/reference/json",
        swaggerPath: "/v1/reference",
      }),
      handlers: Layer.mergeAll(
        AuthRouteGroupLive,
        V1IdentitySpacesRouteGroupLive,
        V1MessagingProvidersRouteGroupLive,
        AuxiliaryRouteGroupLive,
        AdminRouteGroupLive,
      ),
    }),
    bot: defineExecutableHttpApi({
      ...defineOpenApiDocument({
        api: botApi,
        jsonPath: "/bot-api-reference/json",
        swaggerPath: "/bot-api-reference",
      }),
      handlers: BotRouteGroupLive,
    }),
    middleware,
  })
}
