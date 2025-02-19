import type { ConnectionInit, ConnectionOpen } from "@in/server/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { getUserIdFromToken } from "@in/server/controllers/plugins"
import { connectionManager } from "@in/server/ws/connections"

export const handleConnectionInit = async (
  init: ConnectionInit,
  handlerContext: HandlerContext,
): Promise<ConnectionOpen> => {
  // user still unauthenticated here.
  console.log("connection init token=", init.token)

  let { token } = init
  let userIdFromToken = await getUserIdFromToken(token)

  connectionManager.authenticateConnection(
    handlerContext.connectionId,
    userIdFromToken.userId,
    userIdFromToken.sessionId,
  )

  // respond back with ack
  return {}
}
