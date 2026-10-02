import { Context, Effect, Layer } from "effect"
import { ErrorReporter } from "@in/server/core/errors/errorReporter"
import { acquireDeferredOwnedProcess, type ProcessServiceStartFailure, type ProcessServiceStopFailure } from "@in/server/modules/monitoring/ownedProcess.effect"
import type { McpEventsWorker } from "./worker"

export class McpEventsProcess extends Context.Service<McpEventsProcess,
  { readonly start: Effect.Effect<McpEventsWorker | null, ProcessServiceStartFailure>; readonly stop: Effect.Effect<void, ProcessServiceStopFailure> }
>()("@inline/server/mcpEvents/McpEventsProcess") {}

export const McpEventsProcessLive: Layer.Layer<McpEventsProcess, ProcessServiceStartFailure, ErrorReporter> = Layer.effect(
  McpEventsProcess,
  acquireDeferredOwnedProcess({ name: "mcp-event-delivery", start: async () => (await import("./worker")).startMcpEventsWorker(), stop: async (worker) => { await worker?.stop() } }),
)
