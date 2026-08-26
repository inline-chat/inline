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
  BotWebhookDeliveryWorker,
} from "./delivery"
import {
  BotWebhookDeliveryProcess,
  makeBotWebhookDeliveryProcessLayer,
  makeCurrentBotWebhookDeliveryAdapter,
} from "./delivery.effect"

describe(
  "Bot webhook delivery process Layer",
  () => {
    it.effect(
      "awaits the acquired worker during release",
      () =>
        Effect.gen(function* () {
          const events: Array<string> = []
          const worker =
            {} as BotWebhookDeliveryWorker
          const layer =
            makeBotWebhookDeliveryProcessLayer(
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

          yield* BotWebhookDeliveryProcess.use(
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
          {} as BotWebhookDeliveryWorker
        const stopped: Array<
          BotWebhookDeliveryWorker | null
        > = []
        const adapter =
          makeCurrentBotWebhookDeliveryAdapter(
            async () => ({
              startBotWebhookDeliveryWorker:
                () => worker,
              stopBotWebhookDeliveryWorker:
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
