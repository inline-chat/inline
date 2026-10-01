import { Layer } from "effect"
import {
  runLivenessCheck,
  runHealthChecks,
  withLifecycleCheck,
} from "./healthCheck"
import {
  HealthOperations,
  makeHealthOperations,
} from "./health.effect"
import {
  internalMessaging,
} from "../modules/internalMessaging/service"
import { isDistributedRealtimeEnabled } from "../modules/internalMessaging/config"

export const HealthOperationsLive = Layer.succeed(
  HealthOperations,
  makeHealthOperations(async () =>
    withLifecycleCheck(await runHealthChecks(
      isDistributedRealtimeEnabled() ? {
        checkBroker: () => internalMessaging.health === "ready",
      } : undefined,
    )),
    async () => runLivenessCheck(),
  ),
)
