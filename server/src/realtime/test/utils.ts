import type { Server } from "bun"

export const newWebsocket = (server: Server, path = "/realtime") =>
  new WebSocket(`ws://${server.hostname}:${server.port}${path}`, undefined)

export const wsOpen = (ws: WebSocket) =>
  new Promise((resolve) => {
    ws.onopen = resolve
  })

export const wsClose = async (ws: WebSocket) =>
  new Promise<CloseEvent>((resolve) => {
    ws.onclose = resolve
  })

export const wsClosed = async (ws: WebSocket) => {
  const closed = wsClose(ws)
  ws.close()
  await closed
}

export const wsMessage = (ws: WebSocket) =>
  new Promise<MessageEvent<string | Buffer>>((resolve) => {
    ws.onmessage = resolve
  })
