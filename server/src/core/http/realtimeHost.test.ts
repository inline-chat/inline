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
