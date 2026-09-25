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

export const HealthOperationsLive = Layer.succeed(
  HealthOperations,
  makeHealthOperations(async () =>
    withLifecycleCheck(await runHealthChecks({
      checkBroker: () =>
        internalMessaging.health === "ready",
    })),
    async () => runLivenessCheck(),
  ),
)
