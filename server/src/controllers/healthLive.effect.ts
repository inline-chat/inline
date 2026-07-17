import { Layer } from "effect"
import {
  runHealthChecks,
  withLifecycleCheck,
} from "./healthCheck"
import {
  HealthOperations,
  makeHealthOperations,
} from "./health.effect"

export const HealthOperationsLive = Layer.succeed(
  HealthOperations,
  makeHealthOperations(async () =>
    withLifecycleCheck(await runHealthChecks()),
  ),
)
