/**
 * Connections Manager
 *
 * - Registers incoming websocket connections and manages users presence via Presence Manager
 */

import { filterFalsy } from "@in/server/utils/filter"
import { Log } from "@in/server/utils/log"
import { presenceManager } from "@in/server/ws/presence"
import { WebSocketTopic } from "@in/server/ws/topics"
import { type Server } from "bun"
import type { ElysiaWS } from "elysia/ws"
import invariant from "tiny-invariant"

const log = new Log("ws-connections")

const CLOSE_UNAUTHENTICATED_TIMEOUT = 20_000

export enum ConnVersion {
  BASIC_V1 = 1,
  REALTIME_V1 = 2,
}

type WS = ElysiaWS<any, any, any>

interface Connection {
  ws: WS

  version: ConnVersion

  /** Close unauthenticated connections after a grace period. Cleared on auth or close. */
  unauthenticatedCloseTimeoutId?: ReturnType<typeof setTimeout>

  // For authenticated connections
  userId?: number
  sessionId?: number

  /** Realtime API layer */
  layer?: number
}

class ConnectionManager {
  private server: Server<unknown> | undefined
  private connections: Map<string, Connection> = new Map()
  private authenticatedUsers: Map<number, Set<string>> = new Map()
  private usersBySpaceId: Map<number, Set<number>> = new Map()
  private userSpaceIds: Map<number, number[]> = new Map()

  setServer(server: Server<unknown>) {
    this.server = server
  }

  getConnection(id: string): Connection | undefined {
    return this.connections.get(id)
  }

  getTotalConnections(): number {
    return this.connections.size
  }

  getAuthenticatedConnectionCount(): number {
    let count = 0
    for (const connection of this.connections.values()) {
      if (connection.userId) {
        count += 1
      }
    }
    return count
  }

  getAuthenticatedUserCount(): number {
    return this.authenticatedUsers.size
  }

  getUserConnectionSummary(userId: number): { totalConnections: number; sessions: { sessionId: number; count: number }[] } {
    const userConnections = this.authenticatedUsers.get(userId) ?? new Set<string>()
    const sessionCounts = new Map<number, number>()

    for (const connectionId of userConnections) {
      const connection = this.connections.get(connectionId)
      if (!connection?.sessionId) continue
      sessionCounts.set(connection.sessionId, (sessionCounts.get(connection.sessionId) ?? 0) + 1)
    }

    const sessions = Array.from(sessionCounts.entries()).map(([sessionId, count]) => ({ sessionId, count }))
    return { totalConnections: userConnections.size, sessions }
  }

  getConnectionIdFromWs(ws: WS): string {
    let id = ws.id
    invariant(id, "ID is not available on WS")
    return id
  }

  addConnection(ws: WS, version: ConnVersion): string {
    log.debug("Adding new connection")
    //const id = nanoid()
    const id = this.getConnectionIdFromWs(ws)
    const connection: Connection = { ws, version }
    this.connections.set(id, connection)

    // Start timeout, if not authenticated in 20 seconds, close the connection
    connection.unauthenticatedCloseTimeoutId = setTimeout(() => {
      const connection = this.connections.get(id)
      if (connection && !connection.userId) {
        log.debug(`Connection ${id} not authenticated, closing`)
        this.closeConnection(id)
      }
    }, CLOSE_UNAUTHENTICATED_TIMEOUT)

    return id
  }

  authenticateConnection(id: string, userId: number, sessionId: number, layer: number = 1) {
    log.debug(`Authenticating connection ${id} for user ${userId}`)
    const connection = this.connections.get(id)
    if (connection) {
      clearTimeout(connection.unauthenticatedCloseTimeoutId)
      connection.unauthenticatedCloseTimeoutId = undefined

      connection.userId = userId
      connection.sessionId = sessionId
      connection.layer = layer

      void presenceManager.handleConnectionOpen({ userId, sessionId }).catch((e) => {
        log.error("presenceManager.handleConnectionOpen failed", { userId, sessionId, error: e })
      })

      if (!this.authenticatedUsers.has(userId)) {
        // User is connecting for the first time, populate the cache
        this.authenticatedUsers.set(userId, new Set())
        void this.subscribeUserToSpaceIds(userId).catch((e) => {
          log.error("Failed to subscribe user to spaces", { userId, error: e })
        })
      }
      this.authenticatedUsers.get(userId)?.add(id)
    }
  }

  closeConnection(id: string, context: { loggedOut?: boolean } = {}) {
    log.debug(`Closing connection ${id}`)
    const connection = this.connections.get(id)
    if (connection) {
      try {
        connection.ws.close()
      } catch (error) {
        log.error(error)
      }
      this.removeConnection(id, context)
    }
  }

  sessionLoggedOut(userId: number, sessionId: number) {
    this.closeConnectionForSession(userId, sessionId, { loggedOut: true })
  }

  closeConnectionForSession(userId: number, sessionId: number, context: { loggedOut?: boolean } = {}) {
    const connectionIdsForUser = this.authenticatedUsers.get(userId)
    if (!connectionIdsForUser) {
      return
    }

    connectionIdsForUser.forEach((id) => {
      const connection = this.connections.get(id)
      if (connection?.sessionId === sessionId) {
        this.closeConnection(id, context)
      }
    })
  }

  removeConnection(id: string, context: { loggedOut?: boolean } = {}) {
    log.debug(`Removing connection ${id}`)
    const connection = this.connections.get(id)
    if (connection) {
      clearTimeout(connection.unauthenticatedCloseTimeoutId)
      connection.unauthenticatedCloseTimeoutId = undefined

      this.connections.delete(id)
      if (connection.userId && connection.sessionId) {
        const userConnections = this.authenticatedUsers.get(connection.userId)
        userConnections?.delete(id)

        const hasOtherConnectionsForSession = (() => {
          if (userConnections) {
            for (const otherId of userConnections) {
              const other = this.connections.get(otherId)
              if (other?.sessionId === connection.sessionId) return true
            }
            return false
          }

          // Fallback scan: shouldn't happen, but keeps presence state correct.
          for (const other of this.connections.values()) {
            if (other.userId === connection.userId && other.sessionId === connection.sessionId) return true
          }
          return false
        })()

        // Only mark a session inactive when the last connection for that session closes.
        // If logged out there is no point in calling presenceManager.handleConnectionClose.
        if (!context.loggedOut && !hasOtherConnectionsForSession) {
          void presenceManager.handleConnectionClose({ userId: connection.userId, sessionId: connection.sessionId }).catch((e) => {
            log.error("presenceManager.handleConnectionClose failed", {
              userId: connection.userId,
              sessionId: connection.sessionId,
              error: e,
            })
          })
        }

        if (userConnections && userConnections.size === 0) {
          this.authenticatedUsers.delete(connection.userId)
        }
      }
    }
  }

  getUserConnections(userId: number): Connection[] {
    const userConnections = this.authenticatedUsers.get(userId) ?? new Set<string>()
    return [...userConnections].map((conId) => this.connections.get(conId)).filter(filterFalsy)
  }

  getConnectionBySession(userId: number, sessionId: number): Connection | undefined {
    const userConnections = this.authenticatedUsers.get(userId) ?? new Set<string>()

    for (const connectionId of userConnections) {
      const connection = this.connections.get(connectionId)
      if (connection?.sessionId === sessionId) {
        return connection
      }
    }

    return undefined
  }

  getSpaceUserIds(spaceId: number): number[] {
    return Array.from(this.usersBySpaceId.get(spaceId) ?? [])
  }

  subscribeToSpace(userId: number, spaceId: number): void {
    log.debug(`Subscribing to space ${spaceId} for user ${userId}`)
    // TODO: Implement

    // Cache the user in the space
    let spaceConnections = this.usersBySpaceId.get(spaceId)
    if (!spaceConnections) {
      spaceConnections = new Set()
      this.usersBySpaceId.set(spaceId, spaceConnections)
    }
    spaceConnections.add(userId)

    // Subscribe the user to the space
    const userConnections = this.authenticatedUsers.get(userId)
    if (userConnections) {
      userConnections.forEach((connectionId) => {
        const connection = this.connections.get(connectionId)
        if (connection?.version === ConnVersion.BASIC_V1) {
          connection?.ws.subscribe(WebSocketTopic.Space(spaceId))
        }
      })
    }
  }

  // ------------------------------------------------------------------------------------------------
  // Private methods
  // ------------------------------------------------------------------------------------------------

  private async getUserSpaceIds(userId: number): Promise<number[]> {
    // Lazy import so this module doesn't eagerly load db/env at startup.
    const { getSpaceIdsForUser } = await import("@in/server/db/models/spaces")
    return await getSpaceIdsForUser(userId)
  }

  private async cacheUserSpaceIds(userId: number): Promise<number[]> {
    if (this.userSpaceIds.has(userId)) {
      // Already cached
      return this.userSpaceIds.get(userId) ?? []
    }

    const spaceIds = await this.getUserSpaceIds(userId)
    this.userSpaceIds.set(userId, spaceIds)
    return spaceIds
  }

  private async subscribeUserToSpaceIds(userId: number): Promise<void> {
    const spaceIds = await this.cacheUserSpaceIds(userId)
    if (!spaceIds) return

    spaceIds.forEach((spaceId) => {
      this.subscribeToSpace(userId, spaceId)
    })
  }
}

export const connectionManager = new ConnectionManager()
