import Elysia, { t } from "elysia"
import { ServerMessage, ClientMessage, ServerMessageKind, ClientMessageKind } from "./protocol"
import { WsConnection } from "@in/server/ws/connections"
import { Log } from "@in/server/utils/log"
import { getUserIdFromToken } from "@in/server/controllers/plugins"
import { ErrorCodes, InlineError } from "@in/server/types/errors"

const log = new Log("ws")

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

      log.debug("new ws connection", connection.id)
    },

    close(ws) {
      // TODO: Delete socket from our cache
      log.debug("ws connection closed", ws.data.store.connection?.id)

      // Clean up
      ws.data.store.connection?.remove()
    },

    async message(ws, message) {
      switch (message.k) {
        case ClientMessageKind.ConnectionInit: {
          log.debug("ws connection init")

          if (!ws.data.store.connection) {
            log.warn("no connection found when authenticating")
            return
          }
          let { token, userId } = message.p
          let userIdFromToken = await getUserIdFromToken(token)
          if (userIdFromToken !== userId) {
            log.warn(`userId mismatch userIdFromToken: ${userIdFromToken}, userId: ${userId}`)
            throw new InlineError(ErrorCodes.UNAUTHORIZED, "Unauthorized")
          }

          ws.data.store.connection.authenticate(userIdFromToken)
          log.debug("authenticated connection", ws.data.store.connection.id, userIdFromToken)
          break
        }

        case ClientMessageKind.Message:
          log.debug("ws message", message.p)
          break

        case ClientMessageKind.Ping:
          log.debug("ws ping")
          break

        default:
          log.warn("unknown ws message kind", message)
          break
      }
    },
  })
