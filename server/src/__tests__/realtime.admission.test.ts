import { afterAll, beforeAll, describe, expect, it, mock, spyOn } from "bun:test"
import { Context, Effect } from "effect"
import type { Server } from "bun"
import { ClientMessage, Method, RpcError_Code, ServerProtocolMessage } from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "./setup"
import { makeCoreRealtimeTransport, type RealtimeWebSocketData } from "../core/http/realtimeHost"
import { ErrorReporter } from "../core/errors/errorReporter"
import { RealtimeSessions } from "../realtime/host.effect"
import { makeLegacyRealtimeSessions } from "../realtime/legacyHostAdapter.effect"
import { wsOpen, wsClose, wsClosed, wsSendClientProtocolMessage, wsServerProtocolMessage } from "../realtime/test/utils"
import * as rpcHandlers from "../realtime/handlers/_rpc"
import { MAX_IN_FLIGHT_RPC_CALLS } from "../realtime/message"

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

  it("answers RPC calls beyond the in-flight window with RATE_LIMIT and keeps the socket open", async () => {
    const socket = await open()
    let release!: () => void
    const blocked = new Promise<void>((resolve) => { release = resolve })
    const handleRpcCall = spyOn(rpcHandlers, "handleRpcCall").mockImplementation(async () => {
      await blocked
      return { oneofKind: "getSessions", getSessions: { sessions: [] } }
    })
    try {
      const user = await testUtils.createUser("native-rpc-window@example.test")
      const { token } = await testUtils.createSessionForUser(user.id, { clientType: "cli" })
      const opened = wsServerProtocolMessage(socket)
      wsSendClientProtocolMessage(socket, { id: 1n, seq: 1, body: {
        oneofKind: "connectionInit", connectionInit: { token, layer: 2, clientVersion: "1.0.0" },
      } })
      expect((await opened).body.oneofKind).toBe("connectionOpen")

      const received: ServerProtocolMessage[] = []
      let notify: (() => void) | undefined
      socket.onmessage = (event: MessageEvent<ArrayBuffer>) => {
        received.push(ServerProtocolMessage.fromBinary(new Uint8Array(event.data)))
        notify?.()
      }
      const waitFor = async (predicate: () => boolean) => {
        while (!predicate()) await new Promise<void>((resolve) => { notify = resolve })
      }
      const call = (id: bigint) => wsSendClientProtocolMessage(socket, { id, seq: Number(id), body: { oneofKind: "rpcCall", rpcCall: {
        method: Method.GET_SESSIONS, input: { oneofKind: "getSessions", getSessions: {} },
      } } })
      const isResult = (message: ServerProtocolMessage) => message.body.oneofKind === "rpcResult"

      const firstCallId = 10n
      const excessCallId = firstCallId + BigInt(MAX_IN_FLIGHT_RPC_CALLS)
      for (let id = firstCallId; id <= excessCallId; id++) call(id)
      // Pings do not count against the window and are still answered.
      wsSendClientProtocolMessage(socket, { id: 500n, seq: 500, body: { oneofKind: "ping", ping: { nonce: 7n } } })

      await waitFor(() =>
        received.some((message) => message.body.oneofKind === "rpcError")
        && received.some((message) => message.body.oneofKind === "pong"))
      const errors = received.flatMap((message) => message.body.oneofKind === "rpcError" ? [message.body.rpcError] : [])
      expect(errors).toEqual([expect.objectContaining({
        reqMsgId: excessCallId,
        errorCode: RpcError_Code.RATE_LIMIT,
        code: 429,
        retryAfterSeconds: 1,
      })])
      expect(socket.readyState).toBe(WebSocket.OPEN)

      release()
      await waitFor(() => received.filter(isResult).length === MAX_IN_FLIGHT_RPC_CALLS)
      // The window frees up as calls finish.
      call(excessCallId + 1n)
      await waitFor(() => received.filter(isResult).length === MAX_IN_FLIGHT_RPC_CALLS + 1)
      expect(handleRpcCall).toHaveBeenCalledTimes(MAX_IN_FLIGHT_RPC_CALLS + 1)
    } finally {
      release()
      handleRpcCall.mockRestore()
      await wsClosed(socket)
    }
  })

  it("closes oversized pre-auth frames at the native listener", async () => {
    const socket = await open()
    const closed = wsClose(socket)
    socket.send(Buffer.alloc(65_537))
    expect((await closed).code).toBe(1009)
  })
})
