// This is entry point for the v2 API that uses Protocol Buffers, binary websocket protocol.

import Elysia from "elysia"

import { Log, LogLevel } from "@in/server/utils/log"
import { ClientMessage } from "@inline-chat/protocol/core"
import { handleMessage } from "@in/server/realtime/message"
import type { Server, ServerWebSocket } from "bun"
import type { ElysiaWS } from "elysia/ws"
import { connectionManager, ConnVersion } from "@in/server/ws/connections"
import { getIp } from "@in/server/utils/ip"
import type { RealtimeRequestMetadata } from "@in/server/realtime/types"

const log = new Log("ApiV2", LogLevel.INFO)

type RealtimeWsData = {
  request?: Request
  server?: Server<unknown> | null
}

const getRealtimeRequestMetadata = (ws: { data?: RealtimeWsData }): RealtimeRequestMetadata | undefined => {
  const request = ws.data?.request
  if (!request) return undefined

  const metadata: RealtimeRequestMetadata = {
    ip: getIp(request, ws.data?.server),
    userAgent: cleanHeaderValue(request.headers.get("user-agent")),
    origin: cleanHeaderValue(request.headers.get("origin")),
    host: cleanHeaderValue(request.headers.get("host")),
  }

  return Object.values(metadata).some(Boolean) ? metadata : undefined
}

const cleanHeaderValue = (value: string | null | undefined): string | undefined => {
  const trimmed = value?.trim()
  if (!trimmed) return undefined
  return trimmed.length > 200 ? `${trimmed.slice(0, 200)}...` : trimmed
}

export const realtime = new Elysia().ws("/realtime", {
  // CONFIG
  perMessageDeflate: {
    compress: "32KB",
    decompress: "32KB",
  },
  sendPings: true,
  backpressureLimit: 1024 * 1024 * 16, // bytes
  closeOnBackpressureLimit: false,
  idleTimeout: 480, //  8 min

  // ------------------------------------------------------------
  // HANDLERS
  open(ws) {
    const connectionId = connectionManager.addConnection(ws, ConnVersion.REALTIME_V1)
    log.debug("connection opened", connectionId)
  },

  close(ws) {
    const connectionId = connectionManager.getConnectionIdFromWs(ws)
    log.debug("connection closed", connectionId)
    // Socket is already closed here; don't attempt to close it again.
    connectionManager.removeConnection(connectionId)
  },

  async message(ws, message) {
    if (typeof message === "string") {
      log.error("string messages aren't supported in v2 realtime api", message)
      ws.close()
      return
    }

    const connectionId = connectionManager.getConnectionIdFromWs(ws)
    if (!connectionId) {
      log.error("no connection id found")
      ws.close()
      return
    }

    log.debug("ws connectionId", connectionId)
    const requestMetadata = getRealtimeRequestMetadata(ws)

    let parsed: ClientMessage
    try {
      parsed = ClientMessage.fromBinary(message as Uint8Array)
    } catch (e) {
      log.error("Failed to decode client message", e, { connectionId, ...requestMetadata })
      ws.close()
      return
    }

    try {
      await handleMessage(parsed, {
        ws: ws as unknown as ElysiaWS<ServerWebSocket<any>>,
        connectionId,
        requestMetadata,
      })
    } catch (e) {
      log.error("Unhandled error in realtime message handler", e, { connectionId, ...requestMetadata })
      ws.close()
    }
  },
})
