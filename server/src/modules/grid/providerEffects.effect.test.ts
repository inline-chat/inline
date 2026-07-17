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
  GridProviderEffectWorker,
} from "./providerEffects"
import {
  GridProviderEffectsProcess,
  makeCurrentGridProviderEffectsAdapter,
  makeGridProviderEffectsProcessLayer,
} from "./providerEffects.effect"

describe(
  "Grid provider process Layer",
  () => {
    it.effect(
      "awaits the owned worker shutdown",
      () =>
        Effect.gen(function* () {
          const events: Array<string> = []
          const worker =
            {} as GridProviderEffectWorker
          const layer =
            makeGridProviderEffectsProcessLayer(
              {
                start: () => {
                  events.push("start")
                  return worker
                },
                stop: async (owned) => {
                  expect(owned).toBe(worker)
                  await Promise.resolve()
                  events.push("stop")
                },
              },
            ).pipe(
              Layer.provide(
                ErrorReporter.Noop,
              ),
            )

          yield* GridProviderEffectsProcess.use(
            (process) =>
              Effect.sync(() => {
                expect(process.worker).toBe(
                  worker,
                )
              }),
          ).pipe(Effect.provide(layer))

          expect(events).toEqual([
            "start",
            "stop",
          ])
        }),
    )

    it(
      "passes the acquired worker to the default compatibility stop adapter",
      async () => {
        const worker =
          {} as GridProviderEffectWorker
        const stopped: Array<
          GridProviderEffectWorker | null | undefined
        > = []
        const adapter =
          makeCurrentGridProviderEffectsAdapter(
            async () => ({
              startGridProviderEffectWorker:
                () => worker,
              stopGridProviderEffectWorker:
                async (owned) => {
                  stopped.push(owned)
                },
            }),
          )

        const acquired =
          await adapter.start()
        await adapter.stop(acquired)

        expect(acquired).toBe(worker)
        expect(stopped).toEqual([worker])
      },
    )
  },
)
