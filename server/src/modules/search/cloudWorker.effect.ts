import { Context, Layer } from "effect"
import {
  acquireDeferredOwnedProcess,
  type ProcessServiceStartFailure,
  type ProcessServiceStopFailure,
} from "../monitoring/ownedProcess.effect"
import type { ErrorReporter } from "@in/server/core/errors/errorReporter"
import type { Effect } from "effect"
import type { CloudSearchWorker } from "./cloudWorker"

export class CloudSearchProcess extends Context.Service<
  CloudSearchProcess,
  {
    start: Effect.Effect<CloudSearchWorker | null, ProcessServiceStartFailure>
    stop: Effect.Effect<void, ProcessServiceStopFailure>
  }
>()("@inline/server/search/CloudSearchProcess") {}

export const CloudSearchProcessLive: Layer.Layer<CloudSearchProcess, ProcessServiceStartFailure, ErrorReporter> =
  Layer.effect(
    CloudSearchProcess,
    acquireDeferredOwnedProcess({
      name: "cloud-message-search",
      start: async () => (await import("./cloudWorker")).startCloudSearchWorker(),
      stop: async (worker) => {
        await worker?.stop()
      },
    }),
  )
