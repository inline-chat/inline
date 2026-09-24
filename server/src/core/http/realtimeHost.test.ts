import type {
  ClientMessage as ClientMessageType,
} from "@inline-chat/protocol/core"
import {
  ClientMessage,
} from "@inline-chat/protocol/core"
import type {
  Server,
  ServerWebSocket,
} from "bun"
import {
  Context,
  Effect,
} from "effect"
import {
  describe,
  expect,
  it,
} from "vitest"
import {
  ErrorReporter,
  type ErrorReporterShape,
} from "../errors/errorReporter"
import {
  RealtimeSessions,
  type RealtimeSessionsShape,
} from "../../realtime/host.effect"
import type {
  RealtimeWebSocketData,
} from "./realtimeHost"
import {
  makeCoreRealtimeTransport,
} from "./realtimeHost"

const reporter: ErrorReporterShape = {
  report: () => Effect.void,
}

const makeContext = (
  sessions: RealtimeSessionsShape,
) =>
  Context.make(
    ErrorReporter,
    reporter,
  ).pipe(
    Context.add(
      RealtimeSessions,
      sessions,
    ),
  )

const upgrade = (
  transport: ReturnType<
    typeof makeCoreRealtimeTransport
  >,
  request: Request,
) => {
  let data:
    | RealtimeWebSocketData
    | undefined
  const server = {
    requestIP: () => ({
      address: "127.0.0.1",
    }),
    upgrade: (
      _request: Request,
      options: {
        readonly data:
          RealtimeWebSocketData
      },
    ) => {
      data = options.data
      return true
    },
  } as unknown as Server<
    RealtimeWebSocketData
  >

  expect(
    transport.tryUpgrade(
      request,
      server,
    ),
  ).toBe(true)
  expect(data).toBeDefined()
  return data!
}

describe("raw Bun realtime transport", () => {
  it("rejects new frames on existing sockets once drain begins", async () => {
    let handled = 0
    const transport = makeCoreRealtimeTransport(makeContext({ open: (peer) => Effect.succeed({
      connectionId: peer.id, isAuthenticated: () => true, close: Effect.void,
      handle: () => Effect.sync(() => { handled++ }),
    }) }))
    const data = upgrade(transport, new Request("http://inline.test/realtime"))
    const closes: number[] = []
    const socket = { data, close: (code: number) => { closes.push(code) }, sendBinary: () => 1 } as unknown as ServerWebSocket<RealtimeWebSocketData>
    await transport.websocket.open?.(socket)
    await data.connection
    transport.beginDrain()
    await transport.websocket.message(socket, Buffer.alloc(1))
    expect(handled).toBe(0)
    expect(closes).toEqual([1001])
    await transport.shutdown()
  })

  it("rejects excess upgrades before allocating a protocol session", async () => {
    let upgrades = 0
    const transport = makeCoreRealtimeTransport(makeContext({ open: () => Effect.die("not exercised") }))
    const server = {
      requestIP: () => ({ address: "192.0.2.1" }),
      upgrade: () => { upgrades++; return true },
    } as unknown as Server<RealtimeWebSocketData>
    const request = new Request("http://inline.test/realtime")
    for (let i = 0; i < 120; i++) expect(transport.tryUpgrade(request, server)).toBe(true)
    const rejected = transport.tryUpgrade(request, server)
    expect(rejected).toBeInstanceOf(Response)
    expect((rejected as Response).status).toBe(429)
    expect(upgrades).toBe(120)
    await transport.shutdown()
  })

  it("bounds work before awaiting a slow session handler", async () => {
    let release!: () => void
    const pending = new Promise<void>((resolve) => { release = resolve })
    let handled = 0
    let rejected = 0
    const transport = makeCoreRealtimeTransport(makeContext({
      open: (peer) => Effect.succeed({
        connectionId: peer.id, isAuthenticated: () => true, close: Effect.void,
        handle: () => Effect.promise(async () => { handled++; await pending }),
      }),
    }))
    const data = upgrade(transport, new Request("http://inline.test/realtime"))
    const socket = { data, close: () => { rejected++ }, sendBinary: () => 1 } as unknown as ServerWebSocket<RealtimeWebSocketData>
    await transport.websocket.open?.(socket)
    await data.connection
    const frame = Buffer.from(ClientMessage.toBinary({ id: 1n, seq: 1, body: { oneofKind: "ping", ping: { nonce: 1n } } }))
    const requests = Array.from({ length: 40 }, () => transport.websocket.message(socket, frame))
    await Promise.resolve()
    expect(handled).toBeLessThanOrEqual(32)
    expect(rejected).toBeGreaterThan(0)
    release()
    await Promise.all(requests)
    expect(data.pendingMessages).toBe(0)
    expect(data.pendingBytes).toBe(0)
    await transport.websocket.close?.(socket, 1000, "test")
    await transport.shutdown()
  })

  it("rejects large pre-auth frames before decoding", async () => {
    let handled = 0
    let rejected = 0
    const transport = makeCoreRealtimeTransport(makeContext({
      open: (peer) => Effect.succeed({ connectionId: peer.id, close: Effect.void,
        handle: () => Effect.sync(() => { handled++ }) }),
    }))
    const data = upgrade(transport, new Request("http://inline.test/realtime"))
    const socket = { data, close: () => { rejected++ }, sendBinary: () => 1 } as unknown as ServerWebSocket<RealtimeWebSocketData>
    await transport.websocket.open?.(socket)
    await data.connection
    await transport.websocket.message(socket, Buffer.alloc(65_537))
    expect(handled).toBe(0)
    expect(rejected).toBe(1)
    await transport.websocket.close?.(socket, 1000, "test")
    await transport.shutdown()
  })

  it("rejects large frames even while opening a session and bounds retained authenticated bytes", async () => {
    const transport = makeCoreRealtimeTransport(makeContext({ open: () => Effect.die("not exercised") }))
    const data = upgrade(transport, new Request("http://inline.test/realtime"))
    let release!: () => void
    data.connection = new Promise((resolve) => { release = () => resolve(undefined) })
    const closes: number[] = []
    const socket = { data, close: (code: number) => { closes.push(code) } } as unknown as ServerWebSocket<RealtimeWebSocketData>
    await transport.websocket.message(socket, Buffer.alloc(65_537))
    expect(closes).toEqual([1009])
    data.isAuthenticated = () => true
    const frame = Buffer.alloc(16 * 1024 * 1024)
    const first = transport.websocket.message(socket, frame)
    const second = transport.websocket.message(socket, frame)
    await transport.websocket.message(socket, frame)
    expect(closes).toEqual([1009, 1013])
    expect(data.pendingBytes).toBe(32 * 1024 * 1024)
    release()
    await Promise.all([first, second])
    expect(data.pendingBytes).toBe(0)
    await transport.shutdown()
  })

  it("pins transport settings and bounded trusted metadata", () => {
    const transport =
      makeCoreRealtimeTransport(
        makeContext({
          open: () =>
            Effect.die(
              "not exercised",
            ),
        }),
        {
          clientIpHeader:
            "cf-connecting-ip",
        },
      )

    expect(
      transport.websocket,
    ).toMatchObject({
      backpressureLimit:
        16 * 1024 * 1024,
      closeOnBackpressureLimit: false,
      idleTimeout: 480,
      perMessageDeflate: {
        compress: "32KB",
        decompress: "32KB",
      },
      sendPings: true,
    })

    const data = upgrade(
      transport,
      new Request(
        "http://inline.test/realtime",
        {
          headers: {
            "cf-connecting-ip":
              "203.0.113.8",
            "user-agent":
              `  ${"a".repeat(250)}  `,
          },
        },
      ),
    )

    expect(data.metadata?.ip).toBe(
      "203.0.113.8",
    )
    expect(
      data.metadata?.userAgent,
    ).toHaveLength(200)
    expect(
      transport.tryUpgrade(
        new Request(
          "http://inline.test/health",
        ),
        {} as Server<
          RealtimeWebSocketData
        >,
      ),
    ).toBe(false)
  })

  it("routes binary protobuf frames and removes a session once", async () => {
    const handled:
      Array<ClientMessageType> = []
    let closes = 0
    const transport =
      makeCoreRealtimeTransport(
        makeContext({
          open: (peer) =>
            Effect.succeed({
              connectionId: peer.id,
              handle: (message) =>
                Effect.sync(() => {
                  handled.push(message)
                }),
              close: Effect.sync(() => {
                closes += 1
              }),
            }),
        }),
      )
    const data = upgrade(
      transport,
      new Request(
        "http://inline.test/realtime",
      ),
    )
    let transportCloses = 0
    const socket = {
      data,
      close: () => {
        transportCloses += 1
      },
      sendBinary: (
        bytes: Uint8Array,
      ) => bytes.byteLength,
    } as unknown as ServerWebSocket<
      RealtimeWebSocketData
    >

    await transport.websocket.open?.(
      socket,
    )
    await data.connection
    const ping: ClientMessageType = {
      id: 7n,
      seq: 2,
      body: {
        oneofKind: "ping",
        ping: { nonce: 11n },
      },
    }
    await transport.websocket.message(
      socket,
      Buffer.from(
        ClientMessage.toBinary(ping),
      ),
    )
    await transport.websocket.close?.(
      socket,
      1000,
      "test",
    )
    await transport.shutdown()

    expect(handled).toEqual([ping])
    expect(closes).toBe(1)
    expect(transportCloses).toBe(1)
  })
})
