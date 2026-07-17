import {
  Cause,
  Effect,
} from "effect"
import {
  HttpServerResponse,
} from "effect/unstable/http"
import {
  HttpApiBuilder,
  HttpApiGroup,
} from "effect/unstable/httpapi"
import {
  ErrorReporter,
  reportUnexpectedError,
} from "../core/errors/errorReporter"
import {
  UNRESOLVED_CLIENT_IP,
} from "../core/http/middleware"
import {
  makePlatformApiBase,
  PLATFORM_API_ID,
} from "../core/http/openApi"
import {
  HttpRequestContext,
} from "../core/http/requestContext"
import {
  defineHttpRouteGroup,
} from "../core/http/routeGroup"
import {
  ThereEndpoints,
  ThereOperationFailure,
  ThereOperations,
  executeThereSignup,
} from "./extra/there.effect"
import {
  WaitlistEndpoints,
  WaitlistOperationFailure,
  WaitlistOperations,
  executeWaitlistCount,
  executeWaitlistSubscribe,
  executeWaitlistVerify,
} from "./extra/waitlist.effect"
import {
  HealthEndpoints,
  HealthOperationFailure,
  HealthOperations,
  executeHealth,
} from "./health.effect"
import {
  IntegrationEndpoints,
  IntegrationOperationFailure,
  IntegrationOperations,
  executeIntegrationCallback,
  executeIntegrationStart,
} from "./integrations/integrationsRouter.effect"
import {
  MediaEndpoints,
  MediaOperationFailure,
  MediaOperations,
  executeMediaPhoto,
} from "./media.effect"
import {
  SessionAuthentication,
} from "./plugins.effect"
import {
  RootEndpoints,
  RootPageOperations,
  executeRoot,
} from "./root.effect"
import {
  AuxiliaryRequestParsingFailure,
  AuxiliaryRequestRejected,
  auxiliaryInternalServerError,
} from "./auxiliaryValidation.effect"

export const AuxiliaryApiGroup =
  HttpApiGroup.make("auxiliary")
    .add(RootEndpoints.root)
    .add(HealthEndpoints.health)
    .add(HealthEndpoints.healthz)
    .add(WaitlistEndpoints.count)
    .add(WaitlistEndpoints.subscribe)
    .add(WaitlistEndpoints.verify)
    .add(ThereEndpoints.signup)
    .add(MediaEndpoints.photo)
    .add(IntegrationEndpoints.linearIntegrate)
    .add(IntegrationEndpoints.linearCallback)
    .add(IntegrationEndpoints.notionIntegrate)
    .add(IntegrationEndpoints.notionCallback)

type AuxiliaryHandlerFailure =
  | AuxiliaryRequestParsingFailure
  | AuxiliaryRequestRejected
  | HealthOperationFailure
  | IntegrationOperationFailure
  | MediaOperationFailure
  | ThereOperationFailure
  | WaitlistOperationFailure

const failureCause = (
  failure: Exclude<
    AuxiliaryHandlerFailure,
    AuxiliaryRequestRejected
  >,
): unknown => failure.cause

const failureResponse = (
  failure: Exclude<
    AuxiliaryHandlerFailure,
    AuxiliaryRequestRejected
  >,
): HttpServerResponse.HttpServerResponse =>
  failure instanceof IntegrationOperationFailure &&
    failure.publicResponse !== undefined
    ? failure.publicResponse
    : auxiliaryInternalServerError()

const complete = <R>(
  operation: string,
  effect: Effect.Effect<
    HttpServerResponse.HttpServerResponse,
    AuxiliaryHandlerFailure,
    R
  >,
) =>
  effect.pipe(
    Effect.catch((failure) => {
      if (failure instanceof AuxiliaryRequestRejected) {
        return Effect.succeed(failure.response)
      }

      return Effect.gen(function* () {
        const context = yield* HttpRequestContext
        yield* reportUnexpectedError({
          cause: Cause.fail(failureCause(failure)),
          context: {
            operation,
            requestId: context.requestId,
          },
        })
        return failureResponse(failure)
      })
    }),
  )

export const makeAuxiliaryRouteGroup = () => {
  const api = makePlatformApiBase(
    "https://api.inline.chat",
  ).add(AuxiliaryApiGroup)
  const handlers = HttpApiBuilder.group(
    api,
    "auxiliary",
    (groupHandlers) =>
      Effect.gen(function* () {
        const services = yield* Effect.context<
          | ErrorReporter
          | HealthOperations
          | IntegrationOperations
          | MediaOperations
          | RootPageOperations
          | SessionAuthentication
          | ThereOperations
          | WaitlistOperations
        >()
        const execute = <E, R>(
          effect: Effect.Effect<
            HttpServerResponse.HttpServerResponse,
            E,
            R
          >,
        ) => Effect.provide(effect, services)

        return groupHandlers
          .handleRaw(
            "auxiliaryRoot",
            () => execute(executeRoot),
          )
          .handleRaw(
            "auxiliaryHealth",
            () =>
              execute(
                complete(
                  "auxiliary.health",
                  executeHealth,
                ),
              ),
          )
          .handleRaw(
            "auxiliaryHealthz",
            () =>
              execute(
                complete(
                  "auxiliary.healthz",
                  executeHealth,
                ),
              ),
          )
          .handleRaw(
            "waitlistSubscriberCount",
            () =>
              execute(
                complete(
                  "auxiliary.waitlist.count",
                  executeWaitlistCount,
                ),
              ),
          )
          .handleRaw(
            "waitlistSubscribe",
            ({ request }) =>
              execute(
                HttpRequestContext.use((context) =>
                  complete(
                    "auxiliary.waitlist.subscribe",
                    executeWaitlistSubscribe(
                      request,
                      context.clientIp ===
                        UNRESOLVED_CLIENT_IP
                        ? undefined
                        : context.clientIp,
                    ),
                  ),
                ),
              ),
          )
          .handleRaw(
            "waitlistVerify",
            () => execute(executeWaitlistVerify),
          )
          .handleRaw(
            "thereSignup",
            ({ request }) =>
              execute(
                complete(
                  "auxiliary.there.signup",
                  executeThereSignup(request),
                ),
              ),
          )
          .handleRaw(
            "mediaPhoto",
            ({ request }) =>
              execute(
                complete(
                  "auxiliary.media.photo",
                  executeMediaPhoto(request),
                ),
              ),
          )
          .handleRaw(
            "linearIntegrate",
            ({ request }) =>
              execute(
                complete(
                  "auxiliary.integrations.linear.integrate",
                  executeIntegrationStart(
                    "linear",
                    request,
                  ),
                ),
              ),
          )
          .handleRaw(
            "linearCallback",
            ({ request }) =>
              execute(
                complete(
                  "auxiliary.integrations.linear.callback",
                  executeIntegrationCallback(
                    "linear",
                    request,
                  ),
                ),
              ),
          )
          .handleRaw(
            "notionIntegrate",
            ({ request }) =>
              execute(
                complete(
                  "auxiliary.integrations.notion.integrate",
                  executeIntegrationStart(
                    "notion",
                    request,
                  ),
                ),
              ),
          )
          .handleRaw(
            "notionCallback",
            ({ request }) =>
              execute(
                complete(
                  "auxiliary.integrations.notion.callback",
                  executeIntegrationCallback(
                    "notion",
                    request,
                  ),
                ),
              ),
          )
      }),
  )

  return defineHttpRouteGroup({
    apiId: PLATFORM_API_ID,
    document: "platform",
    group: AuxiliaryApiGroup,
    handlers,
  })
}

export const AuxiliaryRouteGroup =
  makeAuxiliaryRouteGroup()
