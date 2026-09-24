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
  BotWebhookDeliveryProcess,
} from "../../modules/botUpdates/delivery.effect"
import {
  BlockContentImageProcess,
} from "../../modules/message/blockContentImageWorker.effect"
import {
  NativeUploadProcess,
} from "../../modules/uploads/worker.effect"
import { GridProviderEffectsProcess } from "../../modules/grid/providerEffects.effect"
import { DatabaseHealthMonitorProcess } from "../../modules/monitoring/databaseHealthMonitor.effect"
import { UserSettingsCleanupProcess } from "../../modules/cache/userSettings.effect"
import {
  markServerShuttingDown,
  type ShutdownSignal,
} from "../../lifecycle/shutdownState"
import { applicationBackgroundWork } from "../../lifecycle/backgroundWork"
import { botUpdateWaiters } from "../../db/models/botUpdateWaiters"
import { waitForPostCommitHooks } from "../../db/commitHooks"
import { internalMessaging } from "../../modules/internalMessaging/service"
import { outboundPublications } from "../../modules/internalMessaging/outbound"
import { connectionDirectory } from "../../modules/internalMessaging/directory"
import { connectedUserRepair } from "../../modules/internalMessaging/repair"
import { subscribeBotPresenceHints } from "../../modules/botPresence/cluster"
import { subscribeGridCredentialHints } from "../../functions/grid"
import { subscribeGridChangeHints } from "../../modules/grid/realtime"
import { subscribePrivateBotRequests } from "../../modules/internalMessaging/privateBot"
import { subscribeClusterCaches } from "../../modules/cache/cluster"
import { subscribeTransientRealtime } from "../../modules/internalMessaging/transient"
import { connectionManager } from "../../ws/connections"
import { sessionAuthority } from "../../modules/auth/sessionAuthority"
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
import type { IngressPolicy } from "./ingress"
import {
  DEFAULT_CORE_GRACEFUL_SHUTDOWN_MILLIS,
} from "./shutdownTimeout"
import {
  makeCoreRealtimeTransport,
} from "./realtimeHost"
import {
  makeInlineProtocolRealtimeTransport,
  makeInlineProtocolRuntime,
  type InlineProtocolRealtimeTransport,
} from "./realtimeV3Host"
import {
  loadInlineProtocolConfiguration,
  type InlineProtocolConfiguration,
} from "../../modules/inlineProtocol/config"

import { makeCombinedWebsocket, type CoreWebSocketData } from "./combinedWebsocket"
export type { CoreWebSocketData } from "./combinedWebsocket"

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

export const coreProductionStartupErrorDetails = (
  error: unknown,
): string | undefined => {
  if (
    !(
      error instanceof CoreProductionStartupError ||
      (
        typeof error === "object" &&
        error !== null &&
        "_tag" in error &&
        error._tag ===
          "CoreProductionStartupError" &&
        "cause" in error
      )
    )
  ) {
    return undefined
  }

  try {
    return Cause.pretty(
      error.cause as Cause.Cause<unknown>,
    )
  } catch {
    return undefined
  }
}

export interface StartCoreProductionServerOptions<
  ApplicationError,
  ApplicationRequirements,
> {
  readonly application: HttpApplicationLayer<
    ApplicationError,
    ApplicationRequirements
  >
  readonly ingressPolicy?: IngressPolicy | undefined
  readonly bindRealtimeServer?:
    | ((
      server: Server<
        CoreWebSocketData
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
  readonly inlineProtocolConfiguration?:
    | InlineProtocolConfiguration
    | undefined
  readonly installSignalHandlers?:
    | boolean
    | undefined
  readonly markShuttingDown?:
    | ((
      signal: ShutdownSignal,
    ) => void)
    | undefined
  readonly port?: number | undefined
  readonly startBackgroundProcesses?:
    | boolean
    | undefined
  readonly startClusterServices?: boolean | undefined
}

export interface CoreProductionServerHandle {
  readonly hostname: string
  readonly port: number
  readonly server: Server<
    CoreWebSocketData
  >
  readonly shutdown: (
    signal?: CoreShutdownSignal,
  ) => Promise<void>
}

const bindCurrentRealtimeServer = async (
  server: Server<
    CoreWebSocketData
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
  cause instanceof CoreProductionStartupError
    ? cause.cause
    : Cause.die(cause)

export const shutdownWithDeadline = async (
  operation: (
    signal: AbortSignal,
  ) => Promise<void>,
  timeoutMillis: number,
  onTimeout: () => void,
  currentStage: () => string,
): Promise<void> => {
  const controller = new AbortController()
  let timeout:
    | ReturnType<typeof setTimeout>
    | undefined

  try {
    await Promise.race([
      operation(controller.signal),
      new Promise<never>(
        (_resolve, reject) => {
          timeout = setTimeout(() => {
            controller.abort()
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

const NETWORK_DRAIN_POLL_MILLIS = 5

export const isBotLongPollRequest = (request: Request): boolean => {
  if (request.method !== "GET") return false
  const path = new URL(request.url).pathname
  return path === "/bot/getUpdates" || /^\/bot[^/]+\/getUpdates$/.test(path)
}

export interface CoreHttpNetworkDrainServer {
  readonly pendingRequests: number
}

const waitForAbortOrTimeout = (
  signal: AbortSignal,
  timeoutMillis: number,
): Promise<void> =>
  new Promise((resolve) => {
    if (signal.aborted) {
      resolve()
      return
    }
    const timeout = setTimeout(complete, timeoutMillis)
    const abort = () => complete()
    function complete(): void {
      clearTimeout(timeout)
      signal.removeEventListener("abort", abort)
      resolve()
    }
    signal.addEventListener("abort", abort, { once: true })
  })

/**
 * Bun's `pendingRequests` can remain nonzero briefly after the request
 * handler/fiber has completed while the final response is still flushing to
 * the client. Keep that final flush inside the existing shutdown deadline.
 */
export const waitForCoreHttpNetworkDrain = async (
  server: CoreHttpNetworkDrainServer,
  signal: AbortSignal,
): Promise<void> => {
  while (!signal.aborted && server.pendingRequests > 0) {
    await waitForAbortOrTimeout(
      signal,
      NETWORK_DRAIN_POLL_MILLIS,
    )
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
  ingressPolicy,
  gracefulShutdownMillis =
    DEFAULT_CORE_GRACEFUL_SHUTDOWN_MILLIS,
  hostname = "0.0.0.0",
  inlineProtocolConfiguration:
    providedInlineProtocolConfiguration,
  installSignalHandlers = false,
  markShuttingDown =
    markServerShuttingDown,
  port = 0,
  startBackgroundProcesses = false,
  startClusterServices = false,
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
  let runtimeDisposePromise: Promise<void> | undefined
  const disposeRuntime = (): Promise<void> =>
    runtimeDisposePromise ??= bridge.dispose()
  const contextExit =
    await bridge.runPromiseExit(
      Effect.context<
        Layer.Success<
          typeof runnableRuntimeLayer
        >
      >(),
    )

  if (Exit.isFailure(contextExit)) {
    await disposeRuntime()
    throw new CoreProductionStartupError({
      cause: contextExit.cause,
    })
  }

  const context = contextExit.value
  let producerStopPromise: Promise<void> | undefined
  const producerStopFailures: unknown[] = []
  const stopBackgroundProducers = (): Promise<void> => producerStopPromise ??= (async () => {
    if (!startBackgroundProcesses) return
    // Stop all six producers before any application/hint drain. Disposing the
    // runtime first would also close the database those drains still require.
    const result = await bridge.runPromiseExit(Effect.all([
      BotWebhookDeliveryProcess.use((process) => process.stop).pipe(Effect.exit),
      BlockContentImageProcess.use((process) => process.stop).pipe(Effect.exit),
      NativeUploadProcess.use((process) => process.stop).pipe(Effect.exit),
      GridProviderEffectsProcess.use((process) => process.stop).pipe(Effect.exit),
      DatabaseHealthMonitorProcess.use((process) => process.stop).pipe(Effect.exit),
      UserSettingsCleanupProcess.use((process) => process.stop).pipe(Effect.exit),
    ], { concurrency: 6 }))
    if (Exit.isFailure(result)) producerStopFailures.push(result.cause)
    else for (const stopped of result.value) {
      if (Exit.isFailure(stopped)) producerStopFailures.push(stopped.cause)
    }
  })()
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
    | Server<CoreWebSocketData>
    | undefined
  let realtimeV3:
    | InlineProtocolRealtimeTransport
    | undefined
  let unsubscribeRevocations = (): void => {}
  let unsubscribeDurable = (): void => {}
  let unsubscribeBotPresence = async (): Promise<void> => {}
  let unsubscribeGridCredentials = (): void => {}
  let unsubscribeGridChanges = (): void => {}
  let unsubscribePrivateBot = (): void => {}
  let unsubscribeCaches = (): void => {}
  let unsubscribeDirectoryReady = (): void => {}
  let unsubscribeRepairContinuity = (): void => {}
  let unsubscribeTransient = (): void => {}
  let sessionAuthorityStarted = false
  let admitting = false

  try {
    outboundPublications.start()
    internalMessaging.setBrokerRequiredForReadiness(startClusterServices)
    const inlineProtocolConfiguration =
      providedInlineProtocolConfiguration ??
        loadInlineProtocolConfiguration()
    realtimeV3 = inlineProtocolConfiguration.enabled
      ? makeInlineProtocolRealtimeTransport(
        makeInlineProtocolRuntime(
          inlineProtocolConfiguration,
        ),
        { clientIpHeader },
      )
      : undefined
    const websocket = makeCombinedWebsocket(realtime.websocket, realtimeV3?.websocket)
    server = Bun.serve<
      CoreWebSocketData
    >({
      hostname,
      port,
      fetch: (request, bunServer) => {
        const ingressRejection = ingressPolicy?.(request)
        if (ingressRejection) return ingressRejection
        // Before the broker subscription completes, surface only its actual
        // readiness state. No application route or WebSocket can become a
        // one-node writer while the reconnect loop is still running.
        const isReadinessRequest =
          new URL(request.url).pathname === "/readyz"
        if (
          (!admitting && !isReadinessRequest) ||
          httpDrain.isDraining()
        ) {
          return new Response(
            "Server shutting down.",
            { status: 503 },
          )
        }
        const inlineProtocolVerification =
          realtimeV3?.handleVerification(
            request,
          )
        if (inlineProtocolVerification !== undefined) {
          return inlineProtocolVerification
        }
        if (
          realtimeV3?.tryUpgrade(
            request,
            bunServer as never,
          )
        ) {
          return undefined
        }
        const unsupportedV3 =
          realtimeV3
            ?.rejectUnsupportedUpgrade(
              request,
            )
        if (unsupportedV3 !== undefined) {
          return unsupportedV3
        }
        const realtimeUpgrade = realtime.tryUpgrade(request, bunServer as never)
        if (realtimeUpgrade instanceof Response) return realtimeUpgrade
        if (realtimeUpgrade) return undefined

        if (isBotLongPollRequest(request)) bunServer.timeout(request, 65)

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
      websocket,
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
    // The broker is an at-most-once hint. Local session authority starts as
    // soon as the listener is bound so invalidation races and missed broker
    // events remain bounded even while Redis is reconnecting.
    sessionAuthority.start({
      connectedSessions: () =>
        connectionManager.getAuthenticatedSessionIdentities(),
      closeSession: ({ userId, sessionId }) => {
        connectionManager.closeConnectionForSession(
          userId,
          sessionId,
          { authenticationInvalidated: true },
        )
      },
    })
    sessionAuthorityStarted = true

    if (startClusterServices) {
      connectionDirectory.resume()
      unsubscribeDurable = internalMessaging.on("DurableUpdatesAvailable", ({ event }) =>
        connectedUserRepair.observeBucket(event))
      unsubscribeRevocations = internalMessaging.on("SessionRevoked", ({ event }) => {
        sessionAuthority.invalidate({
          userId: event.userId,
          sessionId: event.sessionId,
        })
        connectionManager.closeConnectionForSession(event.userId, event.sessionId, { authenticationInvalidated: true })
      })
      unsubscribeBotPresence = subscribeBotPresenceHints()
      unsubscribeGridCredentials = subscribeGridCredentialHints()
      unsubscribeGridChanges = subscribeGridChangeHints()
      unsubscribePrivateBot = subscribePrivateBotRequests()
      unsubscribeTransient = subscribeTransientRealtime()
      unsubscribeCaches = subscribeClusterCaches()
      unsubscribeDirectoryReady = internalMessaging.onReady(() => {
        void connectionDirectory.recoverFromBrokerRestart()
      })
      unsubscribeRepairContinuity = internalMessaging.onContinuityLost(() => {
        // Pub/Sub is only a wake-up path. Promptly rescan local users after a
        // gap; the durable repair loop owns the source of truth and does not
        // make a healthy listener unavailable merely because Redis restarted.
        connectedUserRepair.observeConnectedUsers()
      })
      await internalMessaging.start()
      await connectedUserRepair.start()
    }

    if (startBackgroundProcesses) {
      // Preserve the pre-Effect production contract: the listener and
      // realtime registry bind before any worker launches its first poll.
      const processStartExit =
        await bridge.runPromiseExit(
          Effect.all(
            [
              BotWebhookDeliveryProcess.use(
                (process) => process.start,
              ),
              BlockContentImageProcess.use(
                (process) => process.start,
              ),
              NativeUploadProcess.use(
                (process) => process.start,
              ),
              GridProviderEffectsProcess.use(
                (process) => process.start,
              ),
              DatabaseHealthMonitorProcess.use(
                (process) => process.start,
              ),
              UserSettingsCleanupProcess.use(
                (process) => process.start,
              ),
            ],
            { concurrency: 1 },
          ),
        )
      if (Exit.isFailure(processStartExit)) {
        throw new CoreProductionStartupError({
          cause: processStartExit.cause,
        })
      }
    }
    admitting = true
  } catch (cause) {
    const botPresenceStopped = unsubscribeBotPresence()
    await stopBackgroundProducers()
    if (startClusterServices) await internalMessaging.stopIncoming()
    await botPresenceStopped
    unsubscribeDurable()
    unsubscribeRevocations()
    unsubscribeGridCredentials()
    unsubscribeGridChanges()
    unsubscribePrivateBot()
    unsubscribeCaches()
    unsubscribeDirectoryReady()
    unsubscribeRepairContinuity()
    unsubscribeTransient()
    if (sessionAuthorityStarted) {
      await sessionAuthority.stop()
    }
    await realtimeV3?.shutdown()
    await realtime.shutdown()
    await connectionManager.shutdown()
    await applicationBackgroundWork.waitForIdle()
    await waitForPostCommitHooks()
    await outboundPublications.stop()
    if (startClusterServices) {
      await connectedUserRepair.stop()
      await connectionDirectory.shutdown()
      await internalMessaging.close()
      internalMessaging.setBrokerRequiredForReadiness(false)
    }
    // Bun stops the listener synchronously, but its bookkeeping Promise may
    // remain pending after WebSocket callbacks. Startup rollback must still
    // release the Effect runtime and surface the original failure.
    if (server) {
      void Promise.resolve(server.stop(true)).catch(() => {})
      server.unref()
    }
    await disposeRuntime()
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
    admitting = false
    httpDrain.begin()
    realtime.beginDrain()
    realtimeV3?.beginDrain()
    // Empty Bot polls should not hold a one-Machine deployment drain open.
    botUpdateWaiters.wakeAll()
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
        async (signal) => {
          shutdownStage =
            "in-flight HTTP drain"
          await httpDrain.wait()
          shutdownStage =
            "HTTP network response flush"
          await waitForCoreHttpNetworkDrain(
            server,
            signal,
          )
          // A deadline forces the listener closed but cannot cancel arbitrary
          // DB/provider promises. Manual callers observe the timeout while
          // this owner continues joining work before disposing dependencies.
          shutdownStage =
            "active connection closure"
          const authorityStopped = sessionAuthority.stop()
          await realtimeV3?.shutdown()
          await realtime.shutdown()
          unsubscribeDirectoryReady()
          unsubscribeRepairContinuity()
          const incomingStopped = startClusterServices ? internalMessaging.stopIncoming() : Promise.resolve()
          const repairStopped = startClusterServices ? connectedUserRepair.stop() : Promise.resolve()
          const botPresenceStopped = unsubscribeBotPresence()
          shutdownStage = "background producer stop"
          await stopBackgroundProducers()
          await Promise.all([authorityStopped, incomingStopped, repairStopped, botPresenceStopped])
          // V3 admission deliberately starts membership and client-type reads
          // outside its protocol callback. Bun may deliver a socket's close
          // callback after the transport has finished draining, so close the
          // shared registry and await those reads before its runtime can go
          // away.
          shutdownStage = "connection background work drain"
          await connectionManager.shutdown()
          // Detached application work may still hold database resources or
          // commit user updates. Keep the broker available until it settles.
          shutdownStage = "application background work drain"
          await applicationBackgroundWork.waitForIdle()
          // Transactions have drained; finish their best-effort publications
          // while the broker is still available. The host deadline bounds this.
          shutdownStage = "post-commit notification drain"
          await waitForPostCommitHooks()
          shutdownStage = "outbound publication drain"
          await outboundPublications.stop()
          if (startClusterServices) await connectionDirectory.shutdown()
          unsubscribeDurable()
          unsubscribeRevocations()
          unsubscribeGridCredentials()
          unsubscribeGridChanges()
          unsubscribePrivateBot()
          unsubscribeCaches()
          unsubscribeDirectoryReady()
          unsubscribeRepairContinuity()
          unsubscribeTransient()
          if (startClusterServices) {
            await internalMessaging.close()
            internalMessaging.setBrokerRequiredForReadiness(false)
          }
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
          await disposeRuntime()
          if (producerStopFailures.length > 0) {
            throw new AggregateError(producerStopFailures, "Background producers failed to stop cleanly")
          }
        },
        gracefulShutdownMillis,
        () => {
          markShuttingDown("timeout")
          sessionAuthority.stop()
          try {
            void Promise.resolve(server.stop(true)).catch(() => {
              process.exitCode = 1
            })
          } catch {
            process.exitCode = 1
          }
          server.unref()
          // Do not dispose the runtime concurrently with the still-running
          // teardown. Signal handlers force process exit on this failure;
          // manual shutdown retains dependencies until the join completes.
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
