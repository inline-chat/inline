import Elysia, { t } from "elysia"
import { ServerMessage, ClientMessage, ServerMessageKind, ClientMessageKind, createMessage } from "./protocol"
import { connectionManager, ConnVersion } from "@in/server/ws/connections"
import { Log } from "@in/server/utils/log"
import { getUserIdFromToken } from "@in/server/controllers/plugins"
import { ErrorCodes, InlineError } from "@in/server/types/errors"

const log = new Log("ws")

export const webSocket = new Elysia()
  .state("userId", undefined as number | undefined)
  .state("connectionId", undefined as string | undefined)
  .ws("/ws", {
    // ------------------------------------------------------------
    // CONFIG
    perMessageDeflate: {
      compress: "32KB",
      decompress: "32KB",
    },
    sendPings: true,
    backpressureLimit: 10_000_000,
    closeOnBackpressureLimit: false,

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
      const connectionId = connectionManager.addConnection(ws, ConnVersion.BASIC_V1)
      ws.data.store.connectionId = connectionId

      log.trace("new ws connection", connectionId)
    },

    close(ws) {
      // TODO: Delete socket from our cache
      log.trace("ws connection closed", ws.data.store.connectionId)

      // Clean up
      const connectionId = ws.data.store.connectionId
      if (connectionId) {
        connectionManager.closeConnection(connectionId)
      }
    },

    async message(ws, message) {
      try {
        switch (message.k) {
          case ClientMessageKind.ConnectionInit: {
            log.trace("ws connection init")

            if (!ws.data.store.connectionId) {
              log.warn("no connection found when authenticating")
              return
            }

            let { token, userId } = message.p
            let userIdFromToken = await getUserIdFromToken(token)

            if (userIdFromToken.userId !== userId) {
              log.warn(`userId mismatch userIdFromToken: ${userIdFromToken.userId}, userId: ${userId}`)
              throw new InlineError(InlineError.ApiError.UNAUTHORIZED)
            }

            connectionManager.authenticateConnection(
              ws.data.store.connectionId,
              userIdFromToken.userId,
              userIdFromToken.sessionId,
            )

            log.trace("authenticated connection", userIdFromToken.userId)

            ws.send(
              createMessage({
                kind: ServerMessageKind.ConnectionAck,
                id: message.i,
                payload: {},
              }),
            )

            break
          }

          case ClientMessageKind.Message:
            log.trace("ws message", message.p)
            break

          case ClientMessageKind.Ping:
            log.trace("ws ping")
            break

          default:
            log.warn("unknown ws message kind", message)
            break
        }
      } catch (error) {
        log.error("ws connection init error", error)
        ws.close()
      }
    },
  })
