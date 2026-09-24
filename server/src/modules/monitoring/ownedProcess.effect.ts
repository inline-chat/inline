import {
  Data,
  Effect,
} from "effect"
import {
  reportUnexpectedError,
} from "../../core/errors/errorReporter"

export type OwnedProcessName =
  | "block-content-image"
  | "bot-webhook-delivery"
  | "database-health-monitor"
  | "grid-provider-effects"
  | "native-upload"
  | "realtime-state"
  | "user-settings-cache-cleanup"

export class ProcessServiceStartFailure extends Data.TaggedError(
  "ProcessServiceStartFailure",
)<{
  readonly cause: unknown
  readonly service: OwnedProcessName
}> {}

export class ProcessServiceStopFailure extends Data.TaggedError(
  "ProcessServiceStopFailure",
)<{
  readonly cause: unknown
  readonly service: OwnedProcessName
}> {}

export interface OwnedProcessAdapter<Resource> {
  readonly name: OwnedProcessName
  readonly start: () => Resource | Promise<Resource>
  readonly stop: (
    resource: Resource,
  ) => void | Promise<void>
}

export interface DeferredOwnedProcess<Resource> {
  readonly start: Effect.Effect<
    Resource,
    ProcessServiceStartFailure
  >
  readonly stop: Effect.Effect<void, ProcessServiceStopFailure>
}

/**
 * Acquires one process-owned legacy service in an Effect Scope.
 *
 * Startup remains typed so the replacement root can refuse to serve with an
 * incomplete process graph. Finalizer failures are reported with their private
 * cause and deliberately absorbed because `acquireRelease` finalizers cannot
 * expose a typed error channel.
 */
export const acquireOwnedProcess = <Resource>(
  adapter: OwnedProcessAdapter<Resource>,
) =>
  Effect.acquireRelease(
    Effect.tryPromise({
      try: async () => adapter.start(),
      catch: (cause) =>
        new ProcessServiceStartFailure({
          cause,
          service: adapter.name,
        }),
    }),
    (resource) =>
      Effect.tryPromise({
        try: async () => adapter.stop(resource),
        catch: (cause) =>
          new ProcessServiceStopFailure({
            cause,
            service: adapter.name,
          }),
      }).pipe(
        Effect.catchCause((cause) =>
          reportUnexpectedError({
            cause,
            context: {
              operation:
                `process.${adapter.name}.stop`,
            },
          }),
        ),
      ),
  )

/**
 * Acquires ownership immediately but defers starting the legacy process until
 * the returned Effect runs. This lets the production host bind its listener
 * before background work begins while retaining scoped, awaited release.
 */
export const acquireDeferredOwnedProcess = <Resource>(
  adapter: OwnedProcessAdapter<Resource>,
) =>
  Effect.acquireRelease(
    Effect.sync(() => {
      let starting:
        | Promise<Resource>
        | undefined
      let stopped = false
      let stopping: Promise<void> | undefined

      const start = Effect.tryPromise({
        try: () => {
          if (stopped) return Promise.reject(new Error("Process ownership has stopped"))
          starting ??=
            Promise.resolve().then(
              () => adapter.start(),
            )
          return starting
        },
        catch: (cause) =>
          new ProcessServiceStartFailure({
            cause,
            service: adapter.name,
          }),
      })

      return {
        start,
        stop: (): Promise<void> => {
          stopped = true
          stopping ??= (async () => {
            if (starting === undefined) return
            let resource: Resource
            try { resource = await starting } catch { return }
            await adapter.stop(resource)
          })()
          return stopping
        },
      }
    }),
    (process) =>
      Effect.tryPromise({
        try: process.stop,
        catch: (cause) =>
          new ProcessServiceStopFailure({
            cause,
            service: adapter.name,
          }),
      }).pipe(
        Effect.catchCause((cause) =>
          reportUnexpectedError({
            cause,
            context: {
              operation:
                `process.${adapter.name}.stop`,
            },
          }),
        ),
      ),
  ).pipe(
    Effect.map(({ start, stop }): DeferredOwnedProcess<Resource> => ({
      start,
      // The host quiesces producers before draining consumers. The scoped
      // finalizer calls the same idempotent stop if startup or shutdown fails.
      stop: Effect.tryPromise({
        try: stop,
        catch: (cause) => new ProcessServiceStopFailure({ cause, service: adapter.name }),
      }),
    })),
  )
