import type { ConnectionInit, ConnectionOpen } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { getUserIdFromToken } from "@in/server/controllers/plugins"
import { connectionManager } from "@in/server/ws/connections"
import { Log, LogLevel } from "@in/server/utils/log"
import { db } from "@in/server/db"
import { sessions } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { validateUpToFourSegementSemver } from "@in/server/utils/validate"

const log = new Log("realtime.handlers._connectionInit")

export const handleConnectionInit = async (
  init: ConnectionInit,
  handlerContext: HandlerContext,
): Promise<ConnectionOpen> => {
  // user still unauthenticated here.

  let { token, buildNumber, layer, clientVersion, osVersion } = init
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
    "clientVersion",
    clientVersion,
    "osVersion",
    osVersion,
  )

  const nextClientVersion = validateUpToFourSegementSemver(clientVersion ?? "")
    ? clientVersion
    : buildNumber
      ? buildNumber.toString()
      : undefined
  const nextOsVersion = validateUpToFourSegementSemver(osVersion ?? "") ? osVersion : undefined

  if (nextClientVersion || nextOsVersion) {
    storeSessionInfo(
      userIdFromToken.sessionId,
      userIdFromToken.userId,
      nextClientVersion,
      nextOsVersion,
    ).catch((error) => {
      log.error("Failed to store session client metadata", error)
    })
  }

  connectionManager.authenticateConnection(
    handlerContext.connectionId,
    userIdFromToken.userId,
    userIdFromToken.sessionId,
    layer,
  )

  // respond back with ack
  return {}
}

async function storeSessionInfo(sessionId: number, userId: number, clientVersion?: string, osVersion?: string) {
  const values: { clientVersion?: string; osVersion?: string } = {}
  if (clientVersion) values.clientVersion = clientVersion
  if (osVersion) values.osVersion = osVersion
  if (!Object.keys(values).length) return

  await db.update(sessions).set(values).where(and(eq(sessions.id, sessionId), eq(sessions.userId, userId)))
}
