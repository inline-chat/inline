import { BunFileSystem, BunHttpServer, BunPath } from "@effect/platform-bun"
import { afterAll } from "bun:test"
import { Effect, Exit, Layer } from "effect"
import { HttpRouter } from "effect/unstable/http"
import { ErrorReporterLive } from "@in/server/core/errors/errorReporterLive"
import { makeRuntimeBridge } from "@in/server/core/effect/runtimeBridge"
import {
  makeCandidateHttpApplication,
  type CandidateHttpApplicationOptions,
} from "@in/server/core/http/candidateApplication"
import { makeCoreHttpRequestHandler, type CoreHttpRequestHandler } from "@in/server/core/http/bunRequestHandler"

export interface LiveHttpApp {
  /** Runs one request through the served Effect application, in process. */
  readonly handle: (request: Request, options?: { readonly remoteAddress?: string | undefined }) => Promise<Response>
  readonly dispose: () => Promise<void>
}

/**
 * The production HTTP graph (`makeCandidateHttpApplication`) behind the same
 * Bun fetch adapter `productionHost.ts` uses, without a listener, realtime or
 * background processes. Built lazily on first request; disposed after the file.
 */
export const useLiveHttpApp = (
  options: Partial<CandidateHttpApplicationOptions> = {},
): LiveHttpApp => {
  const application = makeCandidateHttpApplication({
    ...(options.apiBaseUrl === undefined ? {} : { apiBaseUrl: options.apiBaseUrl }),
    middleware: options.middleware ?? { isProduction: false },
  })
  const runtimeLayer = Layer.mergeAll(
    application.pipe(Layer.provideMerge(HttpRouter.layer)),
    BunHttpServer.layerHttpServices,
    BunFileSystem.layer,
    BunPath.layer,
  ).pipe(Layer.provideMerge(ErrorReporterLive))
  // Same narrow cast as productionHost.ts: the kernel middleware supplies the
  // request context that Effect beta leaves in the requirement channel.
  const runnableLayer = runtimeLayer as Layer.Layer<Layer.Success<typeof runtimeLayer>, Layer.Error<typeof runtimeLayer>>
  const bridge = makeRuntimeBridge(runnableLayer)
  let handler: Promise<CoreHttpRequestHandler> | undefined

  const build = async (): Promise<CoreHttpRequestHandler> => {
    const contextExit = await bridge.runPromiseExit(Effect.context<Layer.Success<typeof runnableLayer>>())
    if (Exit.isFailure(contextExit)) {
      throw new Error("The live Effect HTTP application failed to build.", { cause: contextExit.cause })
    }
    return makeCoreHttpRequestHandler(contextExit.value)
  }

  const app: LiveHttpApp = {
    handle: async (request, requestOptions) => (await (handler ??= build()))(request, requestOptions?.remoteAddress),
    dispose: () => bridge.dispose(),
  }
  afterAll(() => app.dispose())
  return app
}
