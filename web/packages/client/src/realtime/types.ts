import type {
  ConnectionError_Reason,
  RpcError,
  RpcResult,
  ServerProtocolMessage,
  UpdatesPayload,
} from "@inline-chat/protocol/core"

export type ClientState = "connecting" | "open"

export type TransportEvent =
  | { type: "connecting" }
  | { type: "connected" }
  | { type: "disconnected"; reason?: string }
  | { type: "stopping" }
  | { type: "message"; message: ServerProtocolMessage }

export type ClientEvent =
  | { type: "transportConnected" }
  | { type: "disconnected"; reason?: string }
  | {
      type: "failure"
      reason:
        | "authentication-missing"
        | "transport-send"
        | "protocol"
        | "ping-timeout"
    }
  | { type: "connectionError"; reason: ConnectionError_Reason }
  | {
      type: "authInvalidated"
      reason: "missing" | ConnectionError_Reason
    }
  | { type: "pong"; nonce: bigint }
  | { type: "connecting" }
  | { type: "open" }
  | { type: "ack"; msgId: bigint }
  | { type: "rpcResult"; msgId: bigint; rpcResult: RpcResult["result"] }
  | { type: "rpcError"; msgId: bigint; rpcError: RpcError }
  | { type: "updates"; updates: UpdatesPayload }

export type RealtimeConnectionState = "idle" | "connecting" | "updating" | "connected"
