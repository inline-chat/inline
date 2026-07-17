import { Layer } from "effect"
import {
  HttpApiBuilder,
  type HttpApiGroup,
} from "effect/unstable/httpapi"
import {
  makeHttpKernelMiddlewareLayer,
  type HttpKernelMiddlewareOptions,
} from "./middleware"
import {
  defineOpenApiDocument,
  makeBotApiBase,
  makeOpenApiDocumentLayer,
  makePlatformApiBase,
  type OpenApiDocumentDefinition,
} from "./openApi"

export interface ExecutableHttpApiDefinition<
  Id extends string,
  Groups extends HttpApiGroup.Constraint,
  HandlersError,
  HandlersRequirements,
> extends OpenApiDocumentDefinition<Id, Groups> {
  readonly handlers: Layer.Layer<
    HttpApiGroup.ToService<Id, Groups>,
    HandlersError,
    HandlersRequirements
  >
}

export const defineExecutableHttpApi = <
  Id extends string,
  Groups extends HttpApiGroup.Constraint,
  HandlersError,
  HandlersRequirements,
>(
  definition: ExecutableHttpApiDefinition<
    Id,
    Groups,
    HandlersError,
    HandlersRequirements
  >,
): ExecutableHttpApiDefinition<
  Id,
  Groups,
  HandlersError,
  HandlersRequirements
> => definition

export interface HttpApplicationOptions<
  PlatformId extends string,
  PlatformGroups extends HttpApiGroup.Constraint,
  PlatformHandlersError,
  PlatformHandlersRequirements,
  BotId extends string,
  BotGroups extends HttpApiGroup.Constraint,
  BotHandlersError,
  BotHandlersRequirements,
> {
  readonly platform: ExecutableHttpApiDefinition<
    PlatformId,
    PlatformGroups,
    PlatformHandlersError,
    PlatformHandlersRequirements
  >
  readonly bot: ExecutableHttpApiDefinition<
    BotId,
    BotGroups,
    BotHandlersError,
    BotHandlersRequirements
  >
  readonly middleware: HttpKernelMiddlewareOptions
}

const makeExecutableHttpApiLayer = <
  Id extends string,
  Groups extends HttpApiGroup.Constraint,
  HandlersError,
  HandlersRequirements,
>(
  definition: ExecutableHttpApiDefinition<
    Id,
    Groups,
    HandlersError,
    HandlersRequirements
  >,
) =>
  HttpApiBuilder.layer(definition.api).pipe(
    Layer.provide(definition.handlers),
  )

/**
 * Composes the host-neutral replacement application.
 *
 * Each executable API supplies one contract and the handlers for that exact
 * contract. Both the router and OpenAPI document are derived from the same API,
 * so served routes cannot be paired with an unrelated document.
 */
export const makeHttpApplication = <
  PlatformId extends string,
  PlatformGroups extends HttpApiGroup.Constraint,
  PlatformHandlersError,
  PlatformHandlersRequirements,
  BotId extends string,
  BotGroups extends HttpApiGroup.Constraint,
  BotHandlersError,
  BotHandlersRequirements,
>(
  options: HttpApplicationOptions<
    PlatformId,
    PlatformGroups,
    PlatformHandlersError,
    PlatformHandlersRequirements,
    BotId,
    BotGroups,
    BotHandlersError,
    BotHandlersRequirements
  >,
) =>
  Layer.mergeAll(
    makeExecutableHttpApiLayer(options.platform),
    makeExecutableHttpApiLayer(options.bot),
    makeOpenApiDocumentLayer(options.platform),
    makeOpenApiDocumentLayer(options.bot),
  ).pipe(
    Layer.provideMerge(
      makeHttpKernelMiddlewareLayer(options.middleware),
    ),
  )

export interface EmptyHttpApplicationOptions {
  readonly apiBaseUrl?: string | undefined
  readonly middleware: HttpKernelMiddlewareOptions
}

/**
 * Empty aggregate for isolated kernel tests.
 *
 * The listener consumes the returned application just like any route-bearing
 * aggregate; it does not know about API identities, handlers, or docs paths.
 */
export const makeEmptyHttpApplication = ({
  apiBaseUrl = "https://api.inline.chat",
  middleware,
}: EmptyHttpApplicationOptions) => {
  const platformApi = makePlatformApiBase(apiBaseUrl)
  const botApi = makeBotApiBase(apiBaseUrl)

  return makeHttpApplication({
    platform: defineExecutableHttpApi({
      ...defineOpenApiDocument({
        api: platformApi,
        jsonPath: "/v1/reference/json",
        swaggerPath: "/v1/reference",
      }),
      handlers: Layer.empty,
    }),
    bot: defineExecutableHttpApi({
      ...defineOpenApiDocument({
        api: botApi,
        jsonPath: "/bot-api-reference/json",
        swaggerPath: "/bot-api-reference",
      }),
      handlers: Layer.empty,
    }),
    middleware,
  })
}

export type HttpApplicationLayer<
  ApplicationError = never,
  ApplicationRequirements = never,
> = Layer.Layer<
  Layer.Success<ReturnType<typeof makeEmptyHttpApplication>>,
  ApplicationError,
  ApplicationRequirements
>
