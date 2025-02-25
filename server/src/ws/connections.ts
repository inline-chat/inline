/**
 * Connections Manager
 *
 * - Registers incoming websocket connections and manages users presence via Presence Manager
 */

import { getSpaceIdsForUser } from "@in/server/db/models/spaces"
import type { Update } from "@in/server/protocol/core"
import { filterFalsy } from "@in/server/utils/filter"
import { Log, LogLevel } from "@in/server/utils/log"
import { presenceManager } from "@in/server/ws/presence"
import { ServerMessage, type ServerMessageType } from "@in/server/ws/protocol"
import { WebSocketTopic } from "@in/server/ws/topics"
import { Value } from "@sinclair/typebox/value"
import { type Server, type ServerWebSocket } from "bun"
import type { ElysiaWS } from "elysia/ws"
import { nanoid } from "nanoid"

const log = new Log("ws-connections", LogLevel.INFO)

const CLOSE_UNAUTHENTICATED_TIMEOUT = 20_000

export enum ConnVersion {
  BASIC_V1 = 1,
  REALTIME_V1 = 2,
}

interface Connection {
  ws: ElysiaWS<ServerWebSocket<any>>

  version: ConnVersion

  // For authenticated connections
  userId?: number
  sessionId?: number
}

class ConnectionManager {
  private server: Server | undefined
  private connections: Map<string, Connection> = new Map()
  private authenticatedUsers: Map<number, Set<string>> = new Map()
  private usersBySpaceId: Map<number, Set<number>> = new Map()
  private userSpaceIds: Map<number, number[]> = new Map()

  setServer(server: Server) {
    this.server = server
  }

  getConnection(id: string): Connection | undefined {
    return this.connections.get(id)
  }

  addConnection(ws: ElysiaWS<ServerWebSocket<any>, any, any>, version: ConnVersion): string {
    log.debug("Adding new connection")
    const id = nanoid()
    this.connections.set(id, { ws, version })

    // Start timeout, if not authenticated in 20 seconds, close the connection
    setTimeout(() => {
      const connection = this.connections.get(id)
      if (connection && !connection.userId) {
        log.debug(`Connection ${id} not authenticated, closing`)
        this.closeConnection(id)
      }
    }, CLOSE_UNAUTHENTICATED_TIMEOUT)

    return id
  }

  authenticateConnection(id: string, userId: number, sessionId: number) {
    log.debug(`Authenticating connection ${id} for user ${userId}`)
    const connection = this.connections.get(id)
    if (connection) {
      connection.userId = userId
      connection.sessionId = sessionId

      presenceManager.handleConnectionOpen({ userId, sessionId })

      if (!this.authenticatedUsers.has(userId)) {
        // User is connecting for the first time, populate the cache
        this.authenticatedUsers.set(userId, new Set())
        this.subscribeUserToSpaceIds(userId)
      }
      this.authenticatedUsers.get(userId)?.add(id)
    }
  }

  closeConnection(id: string) {
    log.debug(`Closing connection ${id}`)
    const connection = this.connections.get(id)
    if (connection) {
      try {
        connection.ws.close()
      } catch (error) {
        log.error(error)
      }
      this.removeConnection(id)
    }
  }

  closeConnectionForSession(userId: number, sessionId: number) {
    const connectionIdsForUser = this.authenticatedUsers.get(userId)
    if (!connectionIdsForUser) {
      return
    }

    connectionIdsForUser.forEach((id) => {
      const connection = this.connections.get(id)
      if (connection?.sessionId === sessionId) {
        this.closeConnection(id)
      }
    })
  }

  removeConnection(id: string) {
    log.debug(`Removing connection ${id}`)
    const connection = this.connections.get(id)
    if (connection) {
      this.connections.delete(id)
      if (connection.userId && connection.sessionId) {
        presenceManager.handleConnectionClose({ userId: connection.userId, sessionId: connection.sessionId })

        const userConnections = this.authenticatedUsers.get(connection.userId)
        userConnections?.delete(id)
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

  // TODO: refactor to use publish
  sendToUser(userId: number, message: ServerMessageType) {
    log.debug(`Sending message to user ${userId}`)
    const userConnections = this.authenticatedUsers.get(userId)
    if (userConnections) {
      userConnections.forEach((connectionId) => {
        const connection = this.connections.get(connectionId)
        if (connection?.version === ConnVersion.BASIC_V1) {
          connection?.ws.send(message)
        }
      })
    }
  }

  async sendToSpace(spaceId: number, message: ServerMessageType) {
    log.debug(`Sending message to space ${spaceId}`)
    this.publish(WebSocketTopic.Space(spaceId), message)
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

  private publish(topic: string, message: ServerMessageType) {
    if (this.server) {
      const encoded = Value.Encode(ServerMessage, Value.Clean(ServerMessage, message))
      let status = this.server.publish(topic, JSON.stringify(encoded))

      if (status === 0) {
        log.error(`Failed to publish message to topic ${topic}`, status)
      } else if (status === -1) {
        log.debug(`Published message to topic ${topic}`)
      } else {
        // Success
        log.trace(`Published message to topic ${topic} with bytes ${status}`)
      }
    } else {
      log.error("No server set, cannot publish")
    }
  }
}

export const connectionManager = new ConnectionManager()
