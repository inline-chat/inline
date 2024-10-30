import { Log } from "@in/server/utils/log"
import { type ServerWebSocket } from "bun"
import type { ElysiaWS } from "elysia/ws"
import { nanoid } from "nanoid"

const log = new Log("ws-connection")

export class WsConnection {
  id: string
  private ws: ElysiaWS<ServerWebSocket<any>>
  private userId?: number

  constructor(ws: ElysiaWS<ServerWebSocket<any>, any, any>) {
    this.id = nanoid()
    this.ws = ws

    // Start timeout, if not authenticated in 20 seconds, close the connection
    setTimeout(() => {
      if (!this.userId) {
        log.debug(`Connection ${this.id} not authenticated, closing`)
        this.close()
      }
    }, 20000)
  }

  authenticate(userId: number) {
    this.userId = userId
    authenticatedConnections.set(this.userId, this)
  }

  close() {
    try {
      this.ws.close()
    } catch (error) {
      console.error(error)
    }
    this.remove()
  }

  remove() {
    connections.delete(this.id)
    if (this.userId) {
      authenticatedConnections.delete(this.userId)
    }
  }

  save() {
    connections.set(this.id, this)
  }
}

/**
 * Map of all connections by id
 */
export const connections = new Map<string, WsConnection>()
/**
 * Map of authenticated connections by user id
 */
export const authenticatedConnections = new Map<number, WsConnection>()

export const getConnection = (id: string) => {
  return connections.get(id)
}
