import type { ServerWebSocket, WebSocketHandler } from "bun"
import type { RealtimeWebSocketData } from "./realtimeHost"
import type { InlineProtocolWebSocketData } from "./realtimeV3Host"
import { REALTIME_FRAME_BYTES } from "../../realtime/admission"

export type CoreWebSocketData = RealtimeWebSocketData | InlineProtocolWebSocketData

/** Bun negotiates these options once per listener, not once per routed handler. */
export const makeCombinedWebsocket = (
  v2: WebSocketHandler<RealtimeWebSocketData>,
  v3?: WebSocketHandler<InlineProtocolWebSocketData>,
): WebSocketHandler<CoreWebSocketData> => {
  const isV3 = (socket: ServerWebSocket<CoreWebSocketData>): socket is ServerWebSocket<InlineProtocolWebSocketData> =>
    "protocol" in socket.data && socket.data.protocol === "inline-v3"
  return {
    maxPayloadLength: REALTIME_FRAME_BYTES,
    backpressureLimit: 16 * 1024 * 1024,
    closeOnBackpressureLimit: true,
    idleTimeout: 480,
    // V2 clients can use ordinary uncompressed frames. V3 must never negotiate deflate.
    perMessageDeflate: v3 ? false : v2.perMessageDeflate,
    sendPings: true,
    open: (socket) => isV3(socket) ? v3?.open?.(socket) : v2.open?.(socket as ServerWebSocket<RealtimeWebSocketData>),
    message: (socket, message) => isV3(socket)
      ? v3?.message(socket, message)
      : v2.message(socket as ServerWebSocket<RealtimeWebSocketData>, message),
    close: (socket, code, reason) => isV3(socket)
      ? v3?.close?.(socket, code, reason)
      : v2.close?.(socket as ServerWebSocket<RealtimeWebSocketData>, code, reason),
    drain: (socket) => isV3(socket) ? v3?.drain?.(socket) : v2.drain?.(socket as ServerWebSocket<RealtimeWebSocketData>),
  }
}
