// This is entry point for the v2 API that uses Protocol Buffers, binary websocket protocol.

import Elysia, { t } from "elysia"

import { Log } from "@in/server/utils/log"
import { getUserIdFromToken } from "@in/server/controllers/plugins"
import { ClientMessage } from "../protocol/core"
import { handleMessage } from "@in/server/realtime/message"
import { BinaryReader } from "@bufbuild/protobuf/wire"
import type { ServerWebSocket } from "bun"
import type { ElysiaWS } from "elysia/ws"
import { connectionManager, ConnVersion } from "@in/server/ws/connections"

const log = new Log("ApiV2")

export const realtime = new Elysia().state("connectionId", undefined as string | undefined).ws("/realtime", {
  // CONFIG
  perMessageDeflate: {
    compress: "32KB",
    decompress: "32KB",
  },
  sendPings: true,
  backpressureLimit: 1024 * 1024 * 16, // bytes
  closeOnBackpressureLimit: false,
  idleTimeout: 240, // 240 seconds

  // ------------------------------------------------------------
  // HANDLERS
  open(ws) {
    const connectionId = connectionManager.addConnection(ws, ConnVersion.REALTIME_V1)
    ws.data.store.connectionId = connectionId
  },

  close(ws) {
    log.trace("connection closed")
  },

  async message(ws, message) {
    if (typeof message === "string") {
      log.error("string messages aren't supported in v2 realtime api", message)
      ws.close()
      return
    }

    const connectionId = ws.data.store.connectionId
    if (!connectionId) {
      log.error("no connection id found")
      ws.close()
      return
    }

    const parsed = ClientMessage.fromBinary(message as Uint8Array)
    handleMessage(parsed, { ws: ws as unknown as ElysiaWS<ServerWebSocket<any>>, connectionId })
  },
})
