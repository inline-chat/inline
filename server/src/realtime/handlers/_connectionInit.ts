import type { ConnectionInit, ConnectionOpen } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { getUserIdFromToken } from "@in/server/controllers/plugins"
import { connectionManager } from "@in/server/ws/connections"
import { Log, LogLevel } from "@in/server/utils/log"
import { db } from "@in/server/db"
import { sessions } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"

const log = new Log("realtime.handlers._connectionInit")

export const handleConnectionInit = async (
  init: ConnectionInit,
  handlerContext: HandlerContext,
): Promise<ConnectionOpen> => {
  // user still unauthenticated here.

  let { token, buildNumber } = init
  let userIdFromToken = await getUserIdFromToken(token)

  log.debug(
    "handleConnectionInit connId",
    handlerContext.connectionId,
    "userId",
    userIdFromToken.userId,
    "sessionId",
    userIdFromToken.sessionId,
    "buildNumber",
    buildNumber,
  )

  if (buildNumber) {
    // Save build number to session
    storeBuildNumber(userIdFromToken.sessionId, userIdFromToken.userId, buildNumber).catch((error) => {
      log.error("Failed to store build number", error)
    })
  }

  connectionManager.authenticateConnection(
    handlerContext.connectionId,
    userIdFromToken.userId,
    userIdFromToken.sessionId,
  )

  // respond back with ack
  return {}
}

async function storeBuildNumber(sessionId: number, userId: number, buildNumber: number) {
  await db
    .update(sessions)
    .set({ clientVersion: buildNumber.toString() })
    .where(and(eq(sessions.id, sessionId), eq(sessions.userId, userId)))
}
