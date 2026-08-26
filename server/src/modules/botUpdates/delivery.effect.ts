import {
  Context,
  Effect,
  Layer,
} from "effect"
import {
  ErrorReporter,
} from "../../core/errors/errorReporter"
import {
  ProcessServiceStartFailure,
  acquireOwnedProcess,
} from "../monitoring/ownedProcess.effect"
import type {
  BotWebhookDeliveryWorker,
} from "./delivery"

export interface BotWebhookDeliveryProcessShape {
  readonly worker:
    | BotWebhookDeliveryWorker
    | null
}

export class BotWebhookDeliveryProcess extends Context.Service<
  BotWebhookDeliveryProcess,
  BotWebhookDeliveryProcessShape
>()(
  "@inline/server/botUpdates/BotWebhookDeliveryProcess",
) {}

export interface BotWebhookDeliveryProcessAdapter {
  readonly start: () =>
    | BotWebhookDeliveryWorker
    | null
    | Promise<
      BotWebhookDeliveryWorker | null
    >
  readonly stop: (
    worker:
      | BotWebhookDeliveryWorker
      | null,
  ) => void | Promise<void>
}

export interface LegacyBotWebhookDeliveryModule {
  readonly startBotWebhookDeliveryWorker:
    () =>
      | BotWebhookDeliveryWorker
      | null
  readonly stopBotWebhookDeliveryWorker: (
    worker?:
      | BotWebhookDeliveryWorker
      | null,
  ) => Promise<void>
}

export type LoadLegacyBotWebhookDelivery =
  () => Promise<
    LegacyBotWebhookDeliveryModule
  >

const loadLegacyBotWebhookDelivery:
  LoadLegacyBotWebhookDelivery =
  () => import("./delivery")

export const makeCurrentBotWebhookDeliveryAdapter =
  (
    loadModule:
      LoadLegacyBotWebhookDelivery =
      loadLegacyBotWebhookDelivery,
  ): BotWebhookDeliveryProcessAdapter => ({
    start: async () => {
      const legacy = await loadModule()
      return legacy
        .startBotWebhookDeliveryWorker()
    },
    stop: async (worker) => {
      const legacy = await loadModule()
      await legacy
        .stopBotWebhookDeliveryWorker(
          worker,
        )
    },
  })

const CurrentBotWebhookDelivery =
  makeCurrentBotWebhookDeliveryAdapter()

export const makeBotWebhookDeliveryProcessLayer =
  (
    adapter:
      BotWebhookDeliveryProcessAdapter =
      CurrentBotWebhookDelivery,
  ): Layer.Layer<
    BotWebhookDeliveryProcess,
    ProcessServiceStartFailure,
    ErrorReporter
  > =>
  Layer.effect(
    BotWebhookDeliveryProcess,
    acquireOwnedProcess({
      name: "bot-webhook-delivery",
      start: adapter.start,
      stop: adapter.stop,
    }).pipe(
      Effect.map((worker) => ({ worker })),
    ),
  )

export const BotWebhookDeliveryProcessLive =
  makeBotWebhookDeliveryProcessLayer()
