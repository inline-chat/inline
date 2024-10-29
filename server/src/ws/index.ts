import Elysia, { t } from "elysia"
import { ServerMessage, ClientMessage } from "./protocol"
import { WsConnection } from "@in/server/ws/connections"

export const webSocket = new Elysia()
  .state("userId", undefined as number | undefined)
  .state("connection", undefined as WsConnection | undefined)
  .ws("/ws", {
    // ------------------------------------------------------------
    // CONFIG
    perMessageDeflate: {
      compress: "32KB",
      decompress: "32KB",
    },
    sendPings: true,

    // ------------------------------------------------------------
    // TYPES
    response: ServerMessage,
    body: ClientMessage,

    // ------------------------------------------------------------
    // HANDLERS
    open(ws) {
      /**
       * TODO:
       * - save, wait for auth message
       * - Mark session as active
       * - Add error types here as well
       * - Authenticate user and save user id to the socket
       * - Add a way to add methods from REST API to the websocket easily
       * -
       */

      // Save
      const connection = new WsConnection(ws)
      connection.save()
      ws.data.store.connection = connection

      console.log("open", connection.id)
    },

    close(ws) {
      // TODO: Delete socket from our cache
      console.log("close", ws.data.store.connection?.id)

      // Clean up
      ws.data.store.connection?.remove()
    },

    message(ws, message) {
      console.log({ message })
    },
  })
