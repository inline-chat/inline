import type { RpcError, RpcResult, ServerProtocolMessage, UpdatesPayload } from "@in/protocol/core"

export type ClientState = "connecting" | "open"

export type TransportEvent =
  | { type: "connecting" }
  | { type: "connected" }
  | { type: "stopping" }
  | { type: "message"; message: ServerProtocolMessage }

export type ClientEvent =
  | { type: "connecting" }
  | { type: "open" }
  | { type: "ack"; msgId: bigint }
  | { type: "rpcResult"; msgId: bigint; rpcResult: RpcResult["result"] }
  | { type: "rpcError"; msgId: bigint; rpcError: RpcError }
  | { type: "updates"; updates: UpdatesPayload }

export type RealtimeConnectionState = "idle" | "connecting" | "updating" | "connected"
