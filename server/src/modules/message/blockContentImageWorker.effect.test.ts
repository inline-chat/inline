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
  BlockContentImageWorker,
} from "./blockContentImageWorker"
import {
  BlockContentImageProcess,
  makeBlockContentImageProcessLayer,
  makeCurrentBlockContentImageAdapter,
} from "./blockContentImageWorker.effect"

describe(
  "Block content image process Layer",
  () => {
    it.effect(
      "awaits the acquired worker during release",
      () =>
        Effect.gen(function* () {
          const events: Array<string> = []
          const worker =
            {} as BlockContentImageWorker
          const layer =
            makeBlockContentImageProcessLayer(
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

          yield* BlockContentImageProcess.use(
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
      "passes the acquired worker through the compatibility adapter",
      async () => {
        const worker =
          {} as BlockContentImageWorker
        const stopped: Array<
          BlockContentImageWorker | null
        > = []
        const adapter =
          makeCurrentBlockContentImageAdapter(
            async () => ({
              startBlockContentImageWorker:
                () => worker,
              stopBlockContentImageWorker:
                async (owned) => {
                  stopped.push(
                    owned ?? null,
                  )
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
