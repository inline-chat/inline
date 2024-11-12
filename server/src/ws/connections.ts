import { Log } from "@in/server/utils/log"
import type { ServerMessageType } from "@in/server/ws/protocol"
import { type ServerWebSocket } from "bun"
import type { ElysiaWS } from "elysia/ws"
import { nanoid } from "nanoid"

const log = new Log("ws-connections")

const CLOSE_UNAUTHENTICATED_TIMEOUT = 20_000

class ConnectionManager {
  private connections: Map<string, { ws: ElysiaWS<ServerWebSocket<any>>; userId?: number }> = new Map()
  private authenticatedUsers: Map<number, Set<string>> = new Map()

  addConnection(ws: ElysiaWS<ServerWebSocket<any>, any, any>): string {
    log.debug("Adding new connection")
    const id = nanoid()
    this.connections.set(id, { ws })

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

  authenticateConnection(id: string, userId: number) {
    log.debug(`Authenticating connection ${id} for user ${userId}`)
    const connection = this.connections.get(id)
    if (connection) {
      connection.userId = userId
      if (!this.authenticatedUsers.has(userId)) {
        this.authenticatedUsers.set(userId, new Set())
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
        console.error(error)
      }
      this.removeConnection(id)
    }
  }

  removeConnection(id: string) {
    log.debug(`Removing connection ${id}`)
    const connection = this.connections.get(id)
    if (connection) {
      this.connections.delete(id)
      if (connection.userId) {
        const userConnections = this.authenticatedUsers.get(connection.userId)
        userConnections?.delete(id)
        if (userConnections && userConnections.size === 0) {
          this.authenticatedUsers.delete(connection.userId)
        }
      }
    }
  }

  sendToUser(userId: number, message: ServerMessageType) {
    log.debug(`Sending message to user ${userId}`)
    const userConnections = this.authenticatedUsers.get(userId)
    if (userConnections) {
      userConnections.forEach((connectionId) => {
        const connection = this.connections.get(connectionId)
        connection?.ws.send(message)
      })
    }
  }
}

export const connectionManager = new ConnectionManager()
