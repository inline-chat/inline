import {
  Data,
  Effect,
} from "effect"
import {
  reportUnexpectedError,
} from "../../core/errors/errorReporter"

export type OwnedProcessName =
  | "database-health-monitor"
  | "grid-provider-effects"
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
      try: async () => {
        console.info(
          `Starting process service: ${adapter.name}`,
        )
        const resource =
          await adapter.start()
        console.info(
          `Started process service: ${adapter.name}`,
        )
        return resource
      },
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
