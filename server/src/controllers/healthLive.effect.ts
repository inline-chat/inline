import { Layer } from "effect"
import {
  runLivenessCheck,
  makeHealthChecker,
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

const checkHealth = makeHealthChecker()

export const HealthOperationsLive = Layer.succeed(
  HealthOperations,
  makeHealthOperations(async () =>
    withLifecycleCheck(await checkHealth(isDistributedRealtimeEnabled() ? {
      checkBroker: () => internalMessaging.health === "ready",
    } : undefined)),
    async () => runLivenessCheck(),
  ),
)
