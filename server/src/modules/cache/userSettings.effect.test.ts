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
import {
  UserSettingsCleanupProcess,
  makeCurrentUserSettingsCleanupAdapter,
  makeUserSettingsCleanupProcessLayer,
} from "./userSettings.effect"

describe(
  "user settings cleanup process Layer",
  () => {
    it.effect(
      "owns cleanup from acquisition through disposal",
      () =>
        Effect.gen(function* () {
          const events: Array<string> = []
          const layer =
            makeUserSettingsCleanupProcessLayer(
              {
                start: () => {
                  events.push("start")
                  return {
                    stop: () => {
                      events.push("stop")
                    },
                  }
                },
              },
            ).pipe(
              Layer.provide(
                ErrorReporter.Noop,
              ),
            )

          yield* UserSettingsCleanupProcess.use(
            (process) => process.start.pipe(Effect.tap((handle) => Effect.sync(() => {
              expect(typeof handle.stop).toBe("function")
            }))),
          ).pipe(Effect.provide(layer))

          expect(events).toEqual([
            "start",
            "stop",
          ])
        }),
    )

    it(
      "uses the compatibility module's explicit start and stop lifecycle",
      async () => {
        const events: Array<string> = []
        const adapter =
          makeCurrentUserSettingsCleanupAdapter(
            async () => ({
              startUserSettingsCacheCleanup:
                () => {
                  events.push("start")
                },
              stopUserSettingsCacheCleanup:
                () => {
                  events.push("stop")
                },
            }),
          )

        const handle = await adapter.start()
        await handle.stop()

        expect(events).toEqual([
          "start",
          "stop",
        ])
      },
    )
  },
)
