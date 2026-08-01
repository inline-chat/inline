import {
  Context,
  Effect,
  Layer,
} from "effect"
import {
  ErrorReporter,
  reportUnexpectedError,
} from "../errors/errorReporter"
import { Log } from "../../utils/log"

const log = new Log(
  "effect.productionInfrastructure",
)

export interface ProductionInfrastructureShape {
  readonly owned: true
}

export class ProductionInfrastructure extends
  Context.Service<
    ProductionInfrastructure,
    ProductionInfrastructureShape
  >()(
    "@inline/server/core/ProductionInfrastructure",
  ) {}

export interface ProductionInfrastructureAdapter {
  readonly closeDatabase:
    () => void | Promise<void>
  readonly flushTelemetry:
    () => void | Promise<void>
  readonly shutdownPushProvider:
    () => void | Promise<void>
}

const CurrentProductionInfrastructure:
  ProductionInfrastructureAdapter = {
    closeDatabase: async () => {
      const { closeDb } =
        await import("../../db")
      await closeDb()
    },
    flushTelemetry: async () => {
      const Sentry =
        await import("@sentry/bun")
      await Sentry.close(2_000)
    },
    shutdownPushProvider: async () => {
      const { shutdownApnProvider } =
        await import("../../libs/apn")
      shutdownApnProvider()
    },
  }

const releaseStep = (
  operation: string,
  release: () => void | Promise<void>,
): Effect.Effect<
  void,
  never,
  ErrorReporter
> =>
  Effect.tryPromise({
    try: async () => {
      const startedAt = performance.now()
      log.info("Starting infrastructure release", {
        operation,
      })
      await release()
      log.info("Completed infrastructure release", {
        durationMs: Math.round(
          performance.now() - startedAt,
        ),
        operation,
      })
    },
    catch: (cause) => cause,
  }).pipe(
    Effect.catchCause((cause) =>
      reportUnexpectedError({
        cause,
        context: { operation },
      }),
    ),
  )

/**
 * Scoped ownership of the remaining lazy legacy infrastructure.
 *
 * TODO(effect-cutover): replace these singleton shutdown callbacks with native
 * constructor Layers as their database, APN, and telemetry callers migrate.
 */
export const makeProductionInfrastructureLayer =
  (
    adapter:
      ProductionInfrastructureAdapter =
        CurrentProductionInfrastructure,
  ) =>
  Layer.effect(
    ProductionInfrastructure,
    Effect.acquireRelease(
      Effect.succeed({
        owned: true as const,
      }),
      () =>
        releaseStep(
          "infrastructure.apn.stop",
          adapter.shutdownPushProvider,
        ).pipe(
          Effect.andThen(
            releaseStep(
              "infrastructure.database.stop",
              adapter.closeDatabase,
            ),
          ),
          Effect.andThen(
            releaseStep(
              "infrastructure.sentry.flush",
              adapter.flushTelemetry,
            ),
          ),
        ),
    ),
  )

export const ProductionInfrastructureLive =
  makeProductionInfrastructureLayer()
