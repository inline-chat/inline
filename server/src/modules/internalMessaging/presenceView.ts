import { connectionManager } from "@in/server/ws/connections"
import { connectionDirectory } from "./directory"

export type ConnectionPresenceRuntime = {
  readonly directory: Pick<
    typeof connectionDirectory,
    "list"
  >
  readonly connections: Pick<
    typeof connectionManager,
    "getUserConnectionSummary"
  >
}

const defaultRuntime: ConnectionPresenceRuntime = {
  directory: connectionDirectory,
  connections: connectionManager,
}

/** A registration view may be incomplete while Redis is unavailable or rebuilding. */
export async function connectionPresenceForUser(
  userId: number,
  runtime: ConnectionPresenceRuntime = defaultRuntime,
): Promise<{
  complete: boolean
  totalConnections: number
  sessions: { sessionId: number; count: number }[]
  activeSessionIds: Set<number>
}> {
  const view = await runtime.directory.list(userId)
  if (view.status === "unavailable") {
    const local = runtime.connections.getUserConnectionSummary(userId)
    return { ...local, complete: false, activeSessionIds: new Set(local.sessions.map((session) => session.sessionId)) }
  }
  const counts = new Map<number, number>()
  for (const connection of view.connections) {
    counts.set(connection.sessionId, (counts.get(connection.sessionId) ?? 0) + 1)
  }
  return {
    complete: view.complete,
    totalConnections: view.connections.length,
    sessions: [...counts].map(([sessionId, count]) => ({ sessionId, count })),
    activeSessionIds: new Set(counts.keys()),
  }
}
