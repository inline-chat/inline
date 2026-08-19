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
      let didComplete = false
      let abortListener:
        | (() => void)
        | undefined
      const completeRequest = () => {
        if (didComplete) return
        didComplete = true
        if (abortListener !== undefined) {
          request.signal
            .removeEventListener(
              "abort",
              abortListener,
            )
          abortListener = undefined
        }
        onRequestComplete?.()
      }
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
        Effect.gen(function* () {
          yield* Effect.addFinalizer(
            () =>
              Effect.sync(
                completeRequest,
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

      // A fully synchronous handler can finalize before runFork returns. In that case there is no
      // live request left to observe, so avoid attaching a listener that can never be removed.
      if (didComplete) return

      abortListener = () => {
        fiber.interruptUnsafe()
      }
      request.signal.addEventListener(
        "abort",
        abortListener,
        { once: true },
      )
      // AbortSignal does not replay an abort that happened before listener registration.
      if (request.signal.aborted) {
        abortListener()
      }
    })
}
