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
  ProcessServiceStopFailure,
  acquireDeferredOwnedProcess,
} from "../monitoring/ownedProcess.effect"
import type {
  GridProviderEffectWorker,
} from "./providerEffects"

export interface GridProviderEffectsProcessShape {
  readonly stop: Effect.Effect<void, ProcessServiceStopFailure>
  readonly start: Effect.Effect<GridProviderEffectWorker, ProcessServiceStartFailure>
}

export class GridProviderEffectsProcess extends Context.Service<
  GridProviderEffectsProcess,
  GridProviderEffectsProcessShape
>()(
  "@inline/server/grid/GridProviderEffectsProcess",
) {}

export interface GridProviderEffectsProcessAdapter {
  readonly start: () =>
    | GridProviderEffectWorker
    | Promise<GridProviderEffectWorker>
  readonly stop: (
    worker: GridProviderEffectWorker,
  ) => void | Promise<void>
}

export interface LegacyGridProviderEffectsModule {
  readonly startGridProviderEffectWorker:
    () => GridProviderEffectWorker
  readonly stopGridProviderEffectWorker: (
    worker?: GridProviderEffectWorker | null,
  ) => Promise<void>
}

export type LoadLegacyGridProviderEffects =
  () => Promise<LegacyGridProviderEffectsModule>

export interface GridExpirySweeperModule {
  readonly startGridExpirySweeper: () => unknown
  readonly stopGridExpirySweeper: () => Promise<void>
}

export type LoadGridExpirySweeper =
  () => Promise<GridExpirySweeperModule>

const loadLegacyGridProviderEffects: LoadLegacyGridProviderEffects =
  () => import("./providerEffects")

const loadGridExpirySweeper: LoadGridExpirySweeper =
  () => import("./expirySweeper")

/**
 * The Grid process owns both durable background loops: provider effects and
 * the lease/transcription expiry sweep that keeps reads off the mutation lock.
 */
export const makeCurrentGridProviderEffectsAdapter =
  (
    loadModule: LoadLegacyGridProviderEffects =
      loadLegacyGridProviderEffects,
    loadSweeper: LoadGridExpirySweeper =
      loadGridExpirySweeper,
  ): GridProviderEffectsProcessAdapter => ({
    start: async () => {
      const [legacy, sweeper] = await Promise.all([loadModule(), loadSweeper()])
      const worker = legacy.startGridProviderEffectWorker()
      sweeper.startGridExpirySweeper()
      return worker
    },
    stop: async (worker) => {
      const [legacy, sweeper] = await Promise.all([loadModule(), loadSweeper()])
      await Promise.all([
        sweeper.stopGridExpirySweeper(),
        legacy.stopGridProviderEffectWorker(
          worker,
        ),
      ])
    },
  })

const CurrentGridProviderEffects =
  makeCurrentGridProviderEffectsAdapter()

export const makeGridProviderEffectsProcessLayer = (
  adapter: GridProviderEffectsProcessAdapter =
    CurrentGridProviderEffects,
): Layer.Layer<
  GridProviderEffectsProcess,
  ProcessServiceStartFailure,
  ErrorReporter
> =>
  Layer.effect(
    GridProviderEffectsProcess,
    acquireDeferredOwnedProcess({
      name: "grid-provider-effects",
      start: adapter.start,
      stop: adapter.stop,
    }),
  )

/**
 * Process-scoped owner for the current durable provider worker.
 *
 * TODO(effect-cutover): replace the legacy interval with a scoped Effect loop
 * once provider execution accepts cancellation; keep the durable claim/retry
 * algorithm unchanged.
 */
export const GridProviderEffectsProcessLive =
  makeGridProviderEffectsProcessLayer()
