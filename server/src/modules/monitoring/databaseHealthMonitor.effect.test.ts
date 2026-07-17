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

          const enabled =
            yield* DatabaseHealthMonitorProcess.use(
              (process) =>
                Effect.succeed(process.enabled),
            ).pipe(Effect.provide(layer))

          expect(enabled).toBe(true)
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
          (process) =>
            Effect.sync(() => {
              expect(process.enabled).toBe(false)
              expect(process.monitor).toBeNull()
            }),
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
