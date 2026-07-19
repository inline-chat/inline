import {
  BunFileSystem,
  BunHttpServer,
  BunPath,
} from "@effect/platform-bun"
import type {
  Server,
} from "bun"
import {
  Cause,
  Data,
  Effect,
  Exit,
  Layer,
} from "effect"
import {
  HttpRouter,
} from "effect/unstable/http"
import {
  ErrorReporterLive,
} from "../errors/errorReporterLive"
import {
  ProductionProcessServicesLive,
} from "../effect/productionRuntime"
import {
  markServerShuttingDown,
  type ShutdownSignal,
} from "../../lifecycle/shutdownState"
import {
  makeRuntimeBridge,
} from "../effect/runtimeBridge"
import type {
  HttpApplicationLayer,
} from "./application"
import {
  makeCoreHttpRequestHandler,
} from "./bunRequestHandler"
import {
  installCoreShutdownHandlers,
  type CoreShutdownSignal,
} from "./shutdownSignals"
import type {
  TrustedClientIpHeader,
} from "./middleware"
import {
  makeCoreRealtimeTransport,
  type RealtimeWebSocketData,
} from "./realtimeHost"

const DEFAULT_GRACEFUL_SHUTDOWN_MILLIS =
  20_000

export interface CoreHttpDrain {
  readonly begin: () => void
  readonly enter: () => () => void
  readonly isDraining: () => boolean
  readonly wait: () => Promise<void>
}

export const makeCoreHttpDrain =
  (): CoreHttpDrain => {
    let draining = false
    let active = 0
    let resolveDrained:
      | (() => void)
      | undefined
    let drained:
      | Promise<void>
      | undefined

    const complete = (): void => {
      active -= 1
      if (
        draining &&
        active === 0
      ) {
        resolveDrained?.()
        resolveDrained = undefined
      }
    }

    return {
      begin: () => {
        draining = true
        if (active === 0) {
          resolveDrained?.()
          resolveDrained = undefined
        }
      },
      enter: () => {
        active += 1
        let completed = false
        return () => {
          if (completed) {
            return
          }
          completed = true
          complete()
        }
      },
      isDraining: () => draining,
      wait: () => {
        if (active === 0) {
          return Promise.resolve()
        }
        drained ??=
          new Promise<void>((resolve) => {
            resolveDrained = resolve
          })
        return drained
      },
    }
  }

export class CoreProductionStartupError extends
  Data.TaggedError(
    "CoreProductionStartupError",
  )<{
    readonly cause: Cause.Cause<unknown>
  }> {
  override readonly message =
    "The Effect production server failed to start."
}

export class CoreProductionShutdownError extends
  Data.TaggedError(
    "CoreProductionShutdownError",
  )<{
    readonly cause: unknown
  }> {
  override readonly message =
    "The Effect production server failed to shut down cleanly."
}

export interface StartCoreProductionServerOptions<
  ApplicationError,
  ApplicationRequirements,
> {
  readonly application: HttpApplicationLayer<
    ApplicationError,
    ApplicationRequirements
  >
  readonly bindRealtimeServer?:
    | ((
      server: Server<
        RealtimeWebSocketData
      >,
    ) => void | Promise<void>)
    | undefined
  readonly clientIpHeader?:
    | TrustedClientIpHeader
    | undefined
  readonly gracefulShutdownMillis?:
    | number
    | undefined
  readonly hostname?: string | undefined
  readonly installSignalHandlers?:
    | boolean
    | undefined
  readonly markShuttingDown?:
    | ((
      signal: ShutdownSignal,
    ) => void)
    | undefined
  readonly port?: number | undefined
}

export interface CoreProductionServerHandle {
  readonly hostname: string
  readonly port: number
  readonly server: Server<
    RealtimeWebSocketData
  >
  readonly shutdown: (
    signal?: CoreShutdownSignal,
  ) => Promise<void>
}

const bindCurrentRealtimeServer = async (
  server: Server<
    RealtimeWebSocketData
  >,
): Promise<void> => {
  const { connectionManager } =
    await import("../../ws/connections")

  // TODO(effect-cutover): inject the publish capability into the realtime
  // registry and remove this final singleton binding compatibility edge.
  connectionManager.setServer(server)
}

const startupCause = (
  cause: unknown,
): Cause.Cause<unknown> =>
  Cause.die(cause)

export const shutdownWithDeadline = async (
  operation: () => Promise<void>,
  timeoutMillis: number,
  onTimeout: () => void,
  currentStage: () => string,
): Promise<void> => {
  let timeout:
    | ReturnType<typeof setTimeout>
    | undefined

  try {
    await Promise.race([
      operation(),
      new Promise<never>(
        (_resolve, reject) => {
          timeout = setTimeout(() => {
            onTimeout()
            reject(
              new Error(
                `Effect production shutdown exceeded ${timeoutMillis}ms during ${currentStage()}.`,
              ),
            )
          }, timeoutMillis)
        },
      ),
    ])
  } finally {
    if (timeout !== undefined) {
      clearTimeout(timeout)
    }
  }
}

/**
 * Starts the complete replacement server on one Bun listener and one built
 * Effect Layer context.
 *
 * HTTP, raw protobuf realtime, workers, and their scoped finalizers all share
 * the runtime bridge. The production entry delegates listener and process
 * ownership here.
 */
export const startCoreProductionServer = async <
  ApplicationError,
  ApplicationRequirements,
>({
  application,
  bindRealtimeServer =
    bindCurrentRealtimeServer,
  clientIpHeader,
  gracefulShutdownMillis =
    DEFAULT_GRACEFUL_SHUTDOWN_MILLIS,
  hostname = "0.0.0.0",
  installSignalHandlers = false,
  markShuttingDown =
    markServerShuttingDown,
  port = 0,
}: StartCoreProductionServerOptions<
  ApplicationError,
  ApplicationRequirements
>): Promise<CoreProductionServerHandle> => {
  const platform = Layer.mergeAll(
    BunHttpServer.layerHttpServices,
    BunFileSystem.layer,
    BunPath.layer,
  )
  const httpApplication =
    application.pipe(
      Layer.provideMerge(HttpRouter.layer),
    )
  const runtimeLayer = Layer.mergeAll(
    httpApplication,
    ProductionProcessServicesLive,
    platform,
  ).pipe(
    Layer.provideMerge(ErrorReporterLive),
  )
  // Effect beta currently retains the request-context service supplied by the
  // global middleware in the Layer requirement channel. The served request
  // tests prove the middleware supplies it at runtime.
  const runnableRuntimeLayer =
    runtimeLayer as Layer.Layer<
      Layer.Success<typeof runtimeLayer>,
      Layer.Error<typeof runtimeLayer>
    >
  const bridge = makeRuntimeBridge(
    runnableRuntimeLayer,
  )
  console.info(
    "Acquiring production runtime services",
  )
  const contextExit =
    await bridge.runPromiseExit(
      Effect.context<
        Layer.Success<
          typeof runnableRuntimeLayer
        >
      >(),
    )
  console.info(
    "Acquired production runtime services",
  )

  if (Exit.isFailure(contextExit)) {
    await bridge.dispose()
    throw new CoreProductionStartupError({
      cause: contextExit.cause,
    })
  }

  const context = contextExit.value
  const httpHandler =
    makeCoreHttpRequestHandler(context)
  const realtime =
    makeCoreRealtimeTransport(
      context,
      { clientIpHeader },
    )
  const httpDrain =
    makeCoreHttpDrain()

  let server:
    | Server<RealtimeWebSocketData>
    | undefined

  try {
    server = Bun.serve<
      RealtimeWebSocketData
    >({
      hostname,
      port,
      fetch: (request, bunServer) => {
        if (httpDrain.isDraining()) {
          return new Response(
            "Server shutting down.",
            { status: 503 },
          )
        }
        if (
          realtime.tryUpgrade(
            request,
            bunServer,
          )
        ) {
          return undefined
        }

        const completeRequest =
          httpDrain.enter()
        return httpHandler(
          request,
          bunServer.requestIP(request)
            ?.address,
          completeRequest,
        ).catch((cause) => {
          completeRequest()
          throw cause
        })
      },
      websocket: realtime.websocket,
    })

    await bindRealtimeServer(server)
    if (
      server.hostname === undefined ||
      server.port === undefined
    ) {
      throw new Error(
        "The Effect production listener did not bind a TCP address.",
      )
    }
  } catch (cause) {
    await server?.stop(true)
    await bridge.dispose()
    throw new CoreProductionStartupError({
      cause: startupCause(cause),
    })
  }

  let shutdownPromise:
    | Promise<void>
    | undefined
  let removeSignalHandlers = (): void => {}
  const shutdown = (
    signal: CoreShutdownSignal = "manual",
  ): Promise<void> => {
    if (shutdownPromise !== undefined) {
      return shutdownPromise
    }

    removeSignalHandlers()
    markShuttingDown(signal)
    httpDrain.begin()
    // Bun stops accepting new connections synchronously. Its graceful-stop
    // Promise is deliberately not awaited because async WebSocket close
    // callbacks can keep that bookkeeping Promise pending on Bun 1.3.1.
    void Promise.resolve(
      server.stop(false),
    ).catch(() => {
      process.exitCode = 1
    })
    let shutdownStage =
      "listener drain"
    shutdownPromise =
      shutdownWithDeadline(
        async () => {
          shutdownStage =
            "realtime transport"
          await realtime.shutdown()
          shutdownStage =
            "in-flight HTTP drain"
          await httpDrain.wait()
          shutdownStage =
            "active connection closure"
          // TODO(effect-cutover): retry Bun's graceful stop(false) once its
          // Promise no longer retains a server after any async WebSocket close
          // callback. On Bun 1.3.1 even stop(true) can leave its Promise
          // pending after such a close although it synchronously stops the
          // listener. Unref the stopped listener and do not let that Bun
          // bookkeeping Promise deadlock the owned Effect finalizers.
          server.unref()
          void Promise.resolve(
            server.stop(true),
          ).catch(() => {
            process.exitCode = 1
          })
          shutdownStage =
            "Effect runtime disposal"
          await bridge.dispose()
        },
        gracefulShutdownMillis,
        () => {
          markShuttingDown("timeout")
          void server.stop(true)
          server.unref()
          void bridge.dispose().catch(
            () => {
              process.exitCode = 1
            },
          )
          if (signal !== "manual") {
            process.exitCode = 1
          }
        },
        () => shutdownStage,
      ).catch((cause) => {
        throw new CoreProductionShutdownError({
          cause,
        })
      })

    return shutdownPromise
  }

  if (installSignalHandlers) {
    removeSignalHandlers =
      installCoreShutdownHandlers(
        shutdown,
        { exitProcess: true },
      )
  }

  return {
    hostname: server.hostname!,
    port: server.port!,
    server,
    shutdown,
  }
}
