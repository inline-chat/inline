import { MAX_USER_CONNECTIONS } from "@in/server/realtime/admission"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { ConnectionInit, ConnectionOpen } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { getUserIdFromToken } from "@in/server/modules/auth/sessionAuthentication"
import { connectionManager } from "@in/server/ws/connections"
import { Log } from "@in/server/utils/log"
import { db } from "@in/server/db"
import { sessions } from "@in/server/db/schema"
import { and, eq, or, sql, type SQL } from "drizzle-orm"
import { validateUpToFourSegementSemver } from "@in/server/utils/validate"
import { connectionBackgroundWork } from "@in/server/ws/backgroundWork"

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
    const store = storeSessionInfo(
      userIdFromToken.sessionId,
      userIdFromToken.userId,
      nextClientVersion,
      nextOsVersion,
    ).catch((error) => {
      log.error("Failed to store session client metadata", error)
    })
    connectionBackgroundWork.track(store)
  }

  if (connectionManager.getUserConnections(userIdFromToken.userId).length >= MAX_USER_CONNECTIONS) {
    throw RealtimeRpcError.RateLimit()
  }

  if (!connectionManager.authenticateConnection(
    handlerContext.connectionId,
    userIdFromToken.userId,
    userIdFromToken.sessionId,
    layer,
    userIdFromToken.isBot,
    userIdFromToken.clientType,
  )) {
    throw RealtimeRpcError.Unauthenticated()
  }

  connectionManager.setSupportsWorking(
    handlerContext.connectionId,
    userIdFromToken.userId,
    userIdFromToken.sessionId,
    init.supportsWorking === true,
  )

  // respond back with ack
  return {}
}

/**
 * Records client metadata only when it changed. Request-scoped clients connect
 * once per call with the same versions, so an unconditional write would update
 * the session row on every connection. Returns the number of rows written.
 */
export async function storeSessionInfo(sessionId: number, userId: number, clientVersion?: string, osVersion?: string): Promise<number> {
  const values: { clientVersion?: string; osVersion?: string } = {}
  const changed: SQL[] = []
  if (clientVersion) {
    values.clientVersion = clientVersion
    changed.push(sql`${sessions.clientVersion} is distinct from ${clientVersion}`)
  }
  if (osVersion) {
    values.osVersion = osVersion
    changed.push(sql`${sessions.osVersion} is distinct from ${osVersion}`)
  }
  if (changed.length === 0) return 0

  const rows = await db.update(sessions).set(values)
    .where(and(eq(sessions.id, sessionId), eq(sessions.userId, userId), or(...changed)))
    .returning({ id: sessions.id })
  return rows.length
}
