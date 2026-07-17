import {
  Context,
  Effect,
  Layer,
} from "effect"
import {
  ErrorReporter,
} from "../../core/errors/errorReporter"
import type {
  DatabaseHealthMonitor,
} from "./databaseHealthMonitor"
import {
  ProcessServiceStartFailure,
  acquireOwnedProcess,
} from "./ownedProcess.effect"

export interface DatabaseHealthMonitorProcessShape {
  readonly enabled: boolean
  readonly monitor:
    | DatabaseHealthMonitor
    | null
}

export class DatabaseHealthMonitorProcess extends Context.Service<
  DatabaseHealthMonitorProcess,
  DatabaseHealthMonitorProcessShape
>()(
  "@inline/server/monitoring/DatabaseHealthMonitorProcess",
) {}

export interface DatabaseHealthMonitorProcessAdapter {
  readonly start: () =>
    | DatabaseHealthMonitor
    | null
    | Promise<DatabaseHealthMonitor | null>
  readonly stop: (
    monitor: DatabaseHealthMonitor | null,
  ) => void | Promise<void>
}

export interface LegacyDatabaseHealthMonitorModule {
  readonly startDatabaseHealthMonitor: () =>
    DatabaseHealthMonitor | null
  readonly stopDatabaseHealthMonitor: (
    monitor?: DatabaseHealthMonitor | null,
  ) => void
}

export type LoadLegacyDatabaseHealthMonitor =
  () => Promise<LegacyDatabaseHealthMonitorModule>

const loadLegacyDatabaseHealthMonitor: LoadLegacyDatabaseHealthMonitor =
  () => import("./databaseHealthMonitor")

export const makeCurrentDatabaseHealthMonitorAdapter =
  (
    loadModule: LoadLegacyDatabaseHealthMonitor =
      loadLegacyDatabaseHealthMonitor,
  ): DatabaseHealthMonitorProcessAdapter => ({
    start: async () => {
      const legacy = await loadModule()
      return legacy.startDatabaseHealthMonitor()
    },
    stop: async (monitor) => {
      const legacy = await loadModule()
      legacy.stopDatabaseHealthMonitor(
        monitor,
      )
    },
  })

const CurrentDatabaseHealthMonitor =
  makeCurrentDatabaseHealthMonitorAdapter()

export const makeDatabaseHealthMonitorProcessLayer = (
  adapter: DatabaseHealthMonitorProcessAdapter =
    CurrentDatabaseHealthMonitor,
): Layer.Layer<
  DatabaseHealthMonitorProcess,
  ProcessServiceStartFailure,
  ErrorReporter
> =>
  Layer.effect(
    DatabaseHealthMonitorProcess,
    acquireOwnedProcess({
      name: "database-health-monitor",
      start: adapter.start,
      stop: adapter.stop,
    }).pipe(
      Effect.map((monitor) => ({
        enabled: monitor !== null,
        monitor,
      })),
    ),
  )

/**
 * Process-scoped owner for the current monitor.
 *
 * TODO(effect-cutover): replace the singleton start/stop adapter with an
 * Effect-native interruptible polling loop after the database query capability
 * itself has an abortable Effect boundary.
 */
export const DatabaseHealthMonitorProcessLive =
  makeDatabaseHealthMonitorProcessLayer()
