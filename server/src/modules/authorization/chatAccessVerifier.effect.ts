import { Context, Effect, Layer } from "effect"
import { ErrorReporter } from "@in/server/core/errors/errorReporter"
import { acquireDeferredOwnedProcess, type ProcessServiceStartFailure, type ProcessServiceStopFailure } from "@in/server/modules/monitoring/ownedProcess.effect"
import type { ChatAccessVerifier } from "./chatAccessVerifier"

export class ChatAccessVerifierProcess extends Context.Service<ChatAccessVerifierProcess,
  { readonly start: Effect.Effect<ChatAccessVerifier | null, ProcessServiceStartFailure>; readonly stop: Effect.Effect<void, ProcessServiceStopFailure> }
>()("@inline/server/authorization/ChatAccessVerifierProcess") {}

export const ChatAccessVerifierProcessLive: Layer.Layer<ChatAccessVerifierProcess, ProcessServiceStartFailure, ErrorReporter> = Layer.effect(
  ChatAccessVerifierProcess,
  acquireDeferredOwnedProcess({ name: "chat-access-verifier", start: async () => (await import("./chatAccessVerifier")).startChatAccessVerifier(), stop: async (verifier) => { await verifier?.stop() } }),
)
