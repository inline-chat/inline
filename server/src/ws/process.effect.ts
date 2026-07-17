import {
  Context,
  Effect,
  Layer,
} from "effect"
import {
  ErrorReporter,
} from "../core/errors/errorReporter"
import {
  ProcessServiceStartFailure,
  acquireOwnedProcess,
} from "../modules/monitoring/ownedProcess.effect"

export interface RealtimeConnectionOwner {
  readonly shutdown: () => void | Promise<void>
}

export interface RealtimePresenceOwner {
  readonly shutdown: () => void | Promise<void>
}

export interface RealtimeStateOwners {
  readonly connections: RealtimeConnectionOwner
  readonly presence: RealtimePresenceOwner
}

export interface RealtimeStateProcessShape {
  readonly owners: RealtimeStateOwners
}

export class RealtimeStateProcess extends Context.Service<
  RealtimeStateProcess,
  RealtimeStateProcessShape
>()("@inline/server/realtime/RealtimeStateProcess") {}

export interface RealtimeStateProcessAdapter {
  readonly start: () =>
    | RealtimeStateOwners
    | Promise<RealtimeStateOwners>
  readonly stop: (
    owners: RealtimeStateOwners,
  ) => void | Promise<void>
}

const CurrentRealtimeState: RealtimeStateProcessAdapter =
  {
    start: async () => {
      const [
        { connectionManager },
        { presenceManager },
      ] = await Promise.all([
        import("./connections"),
        import("./presence"),
      ])
      return {
        connections: connectionManager,
        presence: presenceManager,
      }
    },
    stop: async (owners) => {
      let connectionFailure: unknown
      let presenceFailure: unknown

      try {
        await owners.connections.shutdown()
      } catch (cause) {
        connectionFailure = cause
      }

      try {
        await owners.presence.shutdown()
      } catch (cause) {
        presenceFailure = cause
      }

      if (
        connectionFailure !== undefined ||
        presenceFailure !== undefined
      ) {
        throw new AggregateError(
          [
            connectionFailure,
            presenceFailure,
          ].filter(
            (cause) =>
              cause !== undefined,
          ),
          "Realtime state shutdown failed.",
        )
      }
    },
  }

export const makeRealtimeStateProcessLayer = (
  adapter: RealtimeStateProcessAdapter =
    CurrentRealtimeState,
): Layer.Layer<
  RealtimeStateProcess,
  ProcessServiceStartFailure,
  ErrorReporter
> =>
  Layer.effect(
    RealtimeStateProcess,
    acquireOwnedProcess({
      name: "realtime-state",
      start: adapter.start,
      stop: adapter.stop,
    }).pipe(
      Effect.map((owners) => ({ owners })),
    ),
  )

/**
 * Owns the current connection and presence managers in their existing shutdown
 * order. The dynamic import keeps the presence heartbeat inside acquisition.
 *
 * TODO(effect-cutover): replace the module singletons with constructors owned
 * directly by this Layer after realtime callers consume an injected registry.
 */
export const RealtimeStateProcessLive =
  makeRealtimeStateProcessLayer()
