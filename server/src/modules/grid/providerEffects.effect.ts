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

const loadLegacyGridProviderEffects: LoadLegacyGridProviderEffects =
  () => import("./providerEffects")

export const makeCurrentGridProviderEffectsAdapter =
  (
    loadModule: LoadLegacyGridProviderEffects =
      loadLegacyGridProviderEffects,
  ): GridProviderEffectsProcessAdapter => ({
    start: async () => {
      const legacy = await loadModule()
      return legacy.startGridProviderEffectWorker()
    },
    stop: async (worker) => {
      const legacy = await loadModule()
      await legacy.stopGridProviderEffectWorker(
        worker,
      )
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
