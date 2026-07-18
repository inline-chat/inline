import {
  Context,
  Effect,
  Option,
} from "effect"
import {
  HttpEffect,
  HttpRouter,
  HttpServerRequest,
  HttpServerResponse,
} from "effect/unstable/http"

export type CoreHttpRequestHandler = (
  request: Request,
  remoteAddress?: string | undefined,
  onRequestComplete?: (() => void) | undefined,
) => Promise<Response>

/**
 * Adapts the already-built replacement router to Bun's Fetch boundary.
 *
 * Keeping this adapter outside the route graph lets the production root share
 * one built Layer context across HTTP, realtime, and process services while
 * retaining Bun's direct peer address.
 */
export const makeCoreHttpRequestHandler = (
  context: Context.Context<never>,
): CoreHttpRequestHandler => {
  const router = Context.getUnsafe(
    context,
    HttpRouter.HttpRouter,
  )
  const runFork = Effect.runForkWith(context)

  return (
    request,
    remoteAddress,
    onRequestComplete,
  ) =>
    new Promise<Response>((resolve) => {
      const serverRequest =
        HttpServerRequest
          .fromWeb(request)
          .modify({
            remoteAddress:
              Option.fromNullishOr(
                remoteAddress,
              ),
          })
      const httpEffect =
        onRequestComplete === undefined
          ? router.asHttpEffect()
          : Effect.gen(function* () {
              yield* Effect.addFinalizer(
                () =>
                  Effect.sync(
                    onRequestComplete,
                  ),
              )
              return yield* router
                .asHttpEffect()
            })
      const handled = HttpEffect.toHandled(
        httpEffect,
        (
          currentRequest,
          response,
        ) =>
          Effect.sync(() => {
            resolve(
              HttpServerResponse.toWeb(
                HttpEffect
                  .scopeTransferToStream(
                    response,
                  ),
                {
                  context,
                  withoutBody:
                    currentRequest.method ===
                    "HEAD",
                },
              ),
            )
          }),
      ).pipe(
        Effect.provideService(
          HttpServerRequest
            .HttpServerRequest,
          serverRequest,
        ),
      )
      const fiber = runFork(handled)

      request.signal.addEventListener(
        "abort",
        () => {
          fiber.interruptUnsafe()
        },
        { once: true },
      )
    })
}
