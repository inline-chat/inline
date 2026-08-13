import type { BotEvent, RpcError, RpcResult, ServerProtocolMessage, UpdatesPayload } from "@inline-chat/protocol/core"
import type { InlineSdkAuthenticationError } from "../sdk/errors.js"

export type ClientState = "connecting" | "open"

export type TransportEvent =
  | { type: "connecting" }
  | { type: "connected" }
  | { type: "stopping" }
  | { type: "message"; message: ServerProtocolMessage }

export type ClientEvent =
  | { type: "connecting" }
  | { type: "open" }
  | { type: "authenticationError"; error: InlineSdkAuthenticationError }
  | { type: "ack"; msgId: bigint }
  | { type: "rpcResult"; msgId: bigint; rpcResult: RpcResult["result"] }
  | { type: "rpcError"; msgId: bigint; rpcError: RpcError }
  | { type: "updates"; updates: UpdatesPayload }
  | { type: "bot"; bot: BotEvent }
