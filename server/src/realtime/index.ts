// This is entry point for the v2 API that uses Protocol Buffers, binary websocket protocol.

import Elysia, { t } from "elysia"

import { Log, LogLevel } from "@in/server/utils/log"
import { ClientMessage } from "@in/protocol/core"
import { handleMessage } from "@in/server/realtime/message"
import type { ServerWebSocket } from "bun"
import type { ElysiaWS } from "elysia/ws"
import { connectionManager, ConnVersion } from "@in/server/ws/connections"

const log = new Log("ApiV2", LogLevel.INFO)

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
    connectionManager.closeConnection(connectionId)
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

    const parsed = ClientMessage.fromBinary(message as Uint8Array)
    handleMessage(parsed, { ws: ws as unknown as ElysiaWS<ServerWebSocket<any>>, connectionId })
  },
})
