import { RealtimeV3Request } from "@inline-chat/protocol/core"
import { REPLAY_EXEMPT_METHODS } from "@inline-chat/protocol/transfers"

/**
 * Idempotent and read-only RPCs rely on the session's in-memory receive window;
 * everything else, including undecodable payloads, keeps a durable replay row.
 */
export const inlineProtocolReplayPolicy = (payload: Uint8Array): "durable" | "session" => {
  try {
    const request = RealtimeV3Request.fromBinary(payload)
    return request.body.oneofKind === "rpc" && REPLAY_EXEMPT_METHODS.has(request.body.rpc.method)
      ? "session"
      : "durable"
  } catch {
    return "durable"
  }
}
