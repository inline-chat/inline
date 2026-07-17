import { BunFileSystem, BunHttpServer, BunPath } from "@effect/platform-bun"
import { Cause, Data, Exit, Layer } from "effect"
import { HttpRouter, HttpServer } from "effect/unstable/http"
import { ErrorReporterLive } from "../errors/errorReporterLive"
import { makeRuntimeBridge } from "../effect/runtimeBridge"
import type {
  HttpApplicationLayer,
} from "./application"

const DEFAULT_GRACEFUL_SHUTDOWN_MILLIS = 20_000

export type CoreShutdownSignal = "manual" | "SIGINT" | "SIGTERM"

export class CoreServerStartupError extends Data.TaggedError(
  "CoreServerStartupError",
)<{
  readonly cause: Cause.Cause<unknown>
}> {
  override readonly message = "The Effect HTTP kernel failed to start."
}

export interface StartCoreHttpServerOptions<
  ApplicationError,
  ApplicationRequirements,
> {
  readonly application: HttpApplicationLayer<
    ApplicationError,
    ApplicationRequirements
  >
  readonly gracefulShutdownMillis?: number | undefined
  readonly hostname?: string | undefined
  readonly installSignalHandlers?: boolean | undefined
  readonly port?: number | undefined
}

export interface CoreHttpServerHandle {
  readonly hostname: string
  readonly port: number
  readonly shutdown: (
    signal?: CoreShutdownSignal,
  ) => Promise<void>
}

export const makeCoreHttpServerLayer = <
  ApplicationError,
  ApplicationRequirements,
>({
  application: applicationLayer,
  gracefulShutdownMillis = DEFAULT_GRACEFUL_SHUTDOWN_MILLIS,
  hostname = "127.0.0.1",
  port = 0,
}: StartCoreHttpServerOptions<
  ApplicationError,
  ApplicationRequirements
>) => {
  const application = HttpRouter.serve(applicationLayer, {
    // Effect's stock logger records the raw URL and Cause. Request logging must
    // go through Inline's redacting Log boundary instead.
    disableLogger: true,
    disableListenLog: true,
  })
  const platform = Layer.mergeAll(
    BunHttpServer.layer({
      hostname,
      port,
      gracefulShutdownTimeout: gracefulShutdownMillis,
    }),
    BunFileSystem.layer,
    BunPath.layer,
  )

  return application.pipe(
    Layer.provideMerge(platform),
    Layer.provide(ErrorReporterLive),
  )
}

const installShutdownHandlers = (
  shutdown: (signal: CoreShutdownSignal) => Promise<void>,
): (() => void) => {
  const onSigint = (): void => {
    void shutdown("SIGINT").catch(() => {
      process.exitCode = 1
    })
  }
  const onSigterm = (): void => {
    void shutdown("SIGTERM").catch(() => {
      process.exitCode = 1
    })
  }

  process.once("SIGINT", onSigint)
  process.once("SIGTERM", onSigterm)

  return () => {
    process.off("SIGINT", onSigint)
    process.off("SIGTERM", onSigterm)
  }
}

/**
 * Starts the independent Bun/Effect shadow listener.
 *
 * The managed runtime owns the listener and all future process-scoped Layers.
 * Disposal is idempotent and releases that graph exactly once.
 */
export const startCoreHttpServer = async <
  ApplicationError,
  ApplicationRequirements,
>(
  options: StartCoreHttpServerOptions<
    ApplicationError,
    ApplicationRequirements
  >,
): Promise<CoreHttpServerHandle> => {
  const serverLayer = makeCoreHttpServerLayer(options)
  // `HttpRouter.serve` does not currently eliminate a service supplied by a
  // typed global request middleware from the Layer requirement channel. The
  // kernel middleware supplies HttpRequestContext for every request; live
  // listener tests pin that invariant before this narrow type boundary.
  const runnableServerLayer = serverLayer as Layer.Layer<
    Layer.Success<typeof serverLayer>,
    Layer.Error<typeof serverLayer>
  >
  const bridge = makeRuntimeBridge(runnableServerLayer)
  const serverExit = await bridge.runPromiseExit(HttpServer.HttpServer)

  if (Exit.isFailure(serverExit)) {
    await bridge.dispose()
    throw new CoreServerStartupError({
      cause: serverExit.cause,
    })
  }

  const address = serverExit.value.address
  if (address._tag !== "TcpAddress") {
    await bridge.dispose()
    throw new CoreServerStartupError({
      cause: Cause.die(
        new Error("The core shadow listener did not bind a TCP address."),
      ),
    })
  }

  let shutdownPromise: Promise<void> | undefined
  let removeSignalHandlers = (): void => {}
  const shutdown = (
    _signal: CoreShutdownSignal = "manual",
  ): Promise<void> => {
    if (shutdownPromise) {
      return shutdownPromise
    }

    removeSignalHandlers()
    shutdownPromise = bridge.dispose()
    return shutdownPromise
  }

  if (options.installSignalHandlers === true) {
    removeSignalHandlers = installShutdownHandlers(shutdown)
  }

  return {
    hostname: address.hostname,
    port: address.port,
    shutdown,
  }
}
