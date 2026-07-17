import { Effect, Exit, Layer, ManagedRuntime } from "effect"

/**
 * The deliberately narrow Promise boundary used by existing non-Effect call
 * sites. Returning `Exit` preserves typed failures and defects for the explicit
 * compatibility adapter instead of turning both into rejected Promises.
 */
export interface RuntimeBridge<R, LayerError> {
  readonly runPromiseExit: <A, E>(
    effect: Effect.Effect<A, E, R>,
    options?: Effect.RunOptions,
  ) => Promise<Exit.Exit<A, E | LayerError>>
  readonly dispose: () => Promise<void>
}

/**
 * Creates one lazy, long-lived runtime for a process-owned Layer.
 *
 * The integration root owns this value and must call `dispose` from the
 * existing graceful-shutdown lifecycle. Never construct it per request.
 */
export const makeRuntimeBridge = <R, LayerError>(
  layer: Layer.Layer<R, LayerError>,
): RuntimeBridge<R, LayerError> => {
  const runtime = ManagedRuntime.make(layer)

  return {
    runPromiseExit: (effect, options) => runtime.runPromiseExit(effect, options),
    dispose: () => runtime.dispose(),
  }
}
