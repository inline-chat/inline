import {
  describe,
  expect,
  it,
} from "@effect/vitest"
import {
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
  DatabaseHealthMonitorProcess,
  makeCurrentDatabaseHealthMonitorAdapter,
  makeDatabaseHealthMonitorProcessLayer,
} from "./databaseHealthMonitor.effect"

describe(
  "database health monitor process Layer",
  () => {
    it.effect(
      "starts once and stops when its scope closes",
      () =>
        Effect.gen(function* () {
          const events: Array<string> = []
          const monitor =
            {} as DatabaseHealthMonitor
          const layer =
            makeDatabaseHealthMonitorProcessLayer(
              {
                start: () => {
                  events.push("start")
                  return monitor
                },
                stop: (owned) => {
                  expect(owned).toBe(monitor)
                  events.push("stop")
                },
              },
            ).pipe(
              Layer.provide(
                ErrorReporter.Noop,
              ),
            )

          const acquired = yield* DatabaseHealthMonitorProcess.use(
            (process) => process.start,
          ).pipe(Effect.provide(layer))

          expect(acquired).toBe(monitor)
          expect(events).toEqual([
            "start",
            "stop",
          ])
        }),
    )

    it.effect(
      "retains the current disabled no-op state",
      () =>
        DatabaseHealthMonitorProcess.use(
          (process) => process.start.pipe(Effect.tap((monitor) => Effect.sync(() => {
            expect(monitor).toBeNull()
          }))),
        ).pipe(
          Effect.provide(
            makeDatabaseHealthMonitorProcessLayer(
              {
                start: () => null,
                stop: () => {},
              },
            ).pipe(
              Layer.provide(
                ErrorReporter.Noop,
              ),
            ),
          ),
        ),
    )

    it(
      "passes the acquired monitor to the default compatibility stop adapter",
      async () => {
        const monitor =
          {} as DatabaseHealthMonitor
        const stopped: Array<
          DatabaseHealthMonitor | null | undefined
        > = []
        const adapter =
          makeCurrentDatabaseHealthMonitorAdapter(
            async () => ({
              startDatabaseHealthMonitor:
                () => monitor,
              stopDatabaseHealthMonitor:
                (owned) => {
                  stopped.push(owned)
                },
            }),
          )

        const acquired =
          await adapter.start()
        await adapter.stop(acquired)

        expect(acquired).toBe(monitor)
        expect(stopped).toEqual([monitor])
      },
    )
  },
)
