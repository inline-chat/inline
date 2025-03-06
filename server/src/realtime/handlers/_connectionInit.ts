import type { ConnectionInit, ConnectionOpen } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { getUserIdFromToken } from "@in/server/controllers/plugins"
import { connectionManager } from "@in/server/ws/connections"
import { Log, LogLevel } from "@in/server/utils/log"

const log = new Log("realtime.handlers._connectionInit", LogLevel.INFO)

export const handleConnectionInit = async (
  init: ConnectionInit,
  handlerContext: HandlerContext,
): Promise<ConnectionOpen> => {
  // user still unauthenticated here.

  let { token } = init
  let userIdFromToken = await getUserIdFromToken(token)

  log.debug(
    "handleConnectionInit connId",
    handlerContext.connectionId,
    "userId",
    userIdFromToken.userId,
    "sessionId",
    userIdFromToken.sessionId,
  )
  connectionManager.authenticateConnection(
    handlerContext.connectionId,
    userIdFromToken.userId,
    userIdFromToken.sessionId,
  )

  // respond back with ack
  return {}
}
