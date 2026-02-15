import type { Server } from "bun"
import { ClientMessage, ServerProtocolMessage, type ClientMessage as ClientMessageType } from "@inline-chat/protocol/core"

export const newWebsocket = (server: Server<unknown>, path = "/realtime") =>
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

export const wsBinaryMessage = async (ws: WebSocket): Promise<Uint8Array> => {
  const event = await wsMessage(ws)
  const data = event.data
  if (typeof data === "string") {
    throw new Error("Expected binary websocket message but received string")
  }
  return new Uint8Array(data)
}

export const wsServerProtocolMessage = async (ws: WebSocket): Promise<ServerProtocolMessage> => {
  const binary = await wsBinaryMessage(ws)
  return ServerProtocolMessage.fromBinary(binary)
}

export const wsSendClientProtocolMessage = (ws: WebSocket, message: ClientMessageType) => {
  ws.send(ClientMessage.toBinary(message))
}
