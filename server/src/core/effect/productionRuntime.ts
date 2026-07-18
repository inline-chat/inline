import {
  Effect,
  Layer,
} from "effect"
import {
  UserSettingsCleanupProcessLive,
} from "../../modules/cache/userSettings.effect"
import {
  GridProviderEffectsProcessLive,
} from "../../modules/grid/providerEffects.effect"
import {
  DatabaseHealthMonitorProcessLive,
} from "../../modules/monitoring/databaseHealthMonitor.effect"
import {
  LegacyRealtimeSessionsLive,
} from "../../realtime/legacyHostAdapter.effect"
import {
  RealtimeStateProcessLive,
} from "../../ws/process.effect"
import {
  ProductionInfrastructure,
  ProductionInfrastructureLive,
} from "./productionInfrastructure"

/**
 * Process services owned by the replacement root.
 *
 * The realtime session Layer depends on the state Layer, which ensures the
 * registry remains alive until all sessions have released it. Independent
 * background workers share the same root scope and may finalize concurrently.
 */
const OwnedProcessServicesLive =
  LegacyRealtimeSessionsLive.pipe(
    Layer.provideMerge(
      Layer.mergeAll(
        DatabaseHealthMonitorProcessLive,
        GridProviderEffectsProcessLive,
        UserSettingsCleanupProcessLive,
        RealtimeStateProcessLive,
      ),
    ),
  )

export const ProductionProcessServicesLive =
  Layer.unwrap(
    ProductionInfrastructure.use(() =>
      Effect.succeed(
        OwnedProcessServicesLive,
      ),
    ),
  ).pipe(
    Layer.provideMerge(
      ProductionInfrastructureLive,
    ),
  )
