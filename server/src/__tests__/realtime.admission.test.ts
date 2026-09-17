import { afterAll, beforeAll, describe, expect, it, mock } from "bun:test"
import { Context, Effect } from "effect"
import type { Server } from "bun"
import { ClientMessage, Method, RpcError_Code } from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "./setup"
import { makeCoreRealtimeTransport, type RealtimeWebSocketData } from "../core/http/realtimeHost"
import { ErrorReporter } from "../core/errors/errorReporter"
import { RealtimeSessions } from "../realtime/host.effect"
import { makeLegacyRealtimeSessions } from "../realtime/legacyHostAdapter.effect"
import { wsOpen, wsClose, wsClosed, wsSendClientProtocolMessage, wsServerProtocolMessage } from "../realtime/test/utils"

mock.module("@in/server/ws/presence", () => ({
  presenceManager: { handleConnectionOpen: async () => {}, handleConnectionClose: async () => {} },
}))

describe("native Bun realtime security boundary", () => {
  setupTestLifecycle()
  const transport = makeCoreRealtimeTransport(Context.make(ErrorReporter, { report: () => Effect.void })
    .pipe(Context.add(RealtimeSessions, makeLegacyRealtimeSessions())))
  let server: Server<RealtimeWebSocketData>
  beforeAll(() => {
    server = Bun.serve({
      hostname: "127.0.0.1", port: 0, websocket: transport.websocket,
      fetch(request, server) {
        const upgraded = transport.tryUpgrade(request, server)
        if (upgraded instanceof Response) return upgraded
        if (upgraded) return undefined
        return new Response("Not found", { status: 404 })
      },
    })
  })
  afterAll(async () => { await transport.shutdown(); await server.stop(true) })
  const open = async () => {
    const socket = new WebSocket(`ws://127.0.0.1:${server.port}/realtime`)
    socket.binaryType = "arraybuffer"
    await wsOpen(socket)
    return socket
  }

  it("denies private dispatch before login, then permits authentication, a large valid frame and reconnect", async () => {
    const socket = await open()
    try {
      const denied = wsServerProtocolMessage(socket)
      wsSendClientProtocolMessage(socket, { id: 1n, seq: 1, body: { oneofKind: "rpcCall", rpcCall: {
        method: Method.GET_SESSIONS, input: { oneofKind: "getSessions", getSessions: {} },
      } } })
      expect((await denied).body).toMatchObject({ oneofKind: "rpcError", rpcError: { code: 401, errorCode: RpcError_Code.UNAUTHENTICATED } })
      const user = await testUtils.createUser("native-security@example.test")
      const { token } = await testUtils.createSessionForUser(user.id, { clientType: "cli" })
      const authenticate = async (target: WebSocket) => {
        const reply = wsServerProtocolMessage(target)
        wsSendClientProtocolMessage(target, { id: 2n, seq: 2, body: {
          oneofKind: "connectionInit", connectionInit: { token, layer: 2, clientVersion: "1.0.0" },
        } })
        expect((await reply).body.oneofKind).toBe("connectionOpen")
      }
      await authenticate(socket)
      const pong = wsServerProtocolMessage(socket)
      const ping = ClientMessage.toBinary({ id: 3n, seq: 3, body: { oneofKind: "ping", ping: { nonce: 99n } } })
      // Unknown protobuf field 127, length 70,000: valid forward-compatible data above the pre-auth ceiling.
      socket.send(Buffer.concat([ping, Buffer.from([0xfa, 0x07, 0xf0, 0xa2, 0x04]), Buffer.alloc(70_000)]))
      expect((await pong).body.oneofKind).toBe("pong")
      const reconnected = await open()
      try { await authenticate(reconnected) } finally { await wsClosed(reconnected) }
    } finally { await wsClosed(socket) }
  })

  it("closes oversized pre-auth frames at the native listener", async () => {
    const socket = await open()
    const closed = wsClose(socket)
    socket.send(Buffer.alloc(65_537))
    expect((await closed).code).toBe(1009)
  })
})
