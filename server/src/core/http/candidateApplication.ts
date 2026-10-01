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
  makeHttpRoutes,
} from "./application"
import {
  makeHttpKernelMiddlewareLayer,
  type HttpKernelMiddlewareOptions,
} from "./middleware"
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
 * `server/src/index.ts` serves this graph in production. The retained
 * `legacyServer.ts` graph is differential-test evidence only.
 */
export const makeCandidateHttpRoutes = (apiBaseUrl = "https://api.inline.chat") => {
  const platformApi = makePlatformApiBase(apiBaseUrl)
    .add(AuthApiGroup)
    .add(V1IdentitySpacesApiGroup)
    .add(V1MessagingProvidersApiGroup)
    .add(AuxiliaryApiGroup)
  const botApi = makeBotApiBase(apiBaseUrl)
    .add(BotApiGroup)

  return makeHttpRoutes({
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
  })
}

export const makeCandidateHttpApplication = ({
  apiBaseUrl = "https://api.inline.chat",
  middleware,
}: CandidateHttpApplicationOptions) =>
  makeCandidateHttpRoutes(apiBaseUrl).pipe(
    Layer.provideMerge(makeHttpKernelMiddlewareLayer(middleware)),
  )
