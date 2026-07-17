import {
  type ClientMessage as ClientMessageType,
} from "@inline-chat/protocol/core"
import {
  describe,
  expect,
  it,
} from "@effect/vitest"
import {
  Effect,
  Layer,
} from "effect"
import {
  RealtimeSessionFailure,
  RealtimeSessions,
  type RealtimeTransportPeer,
} from "./host.effect"
import {
  makeLegacyRealtimeSessions,
  makeLegacyRealtimeSessionsLayer,
  type LegacyRealtimeRuntime,
} from "./legacyHostAdapter.effect"
import {
  RealtimeStateProcess,
} from "../ws/process.effect"

const ping: ClientMessageType = {
  id: 99n,
  seq: 2,
  body: {
    oneofKind: "ping",
    ping: { nonce: 5n },
  },
}

describe(
  "current realtime compatibility adapter",
  () => {
    it.effect(
      "delegates the exact socket methods and protobuf message context",
      () =>
        Effect.gen(function* () {
          const sent: Array<{
            bytes: Uint8Array
            compress: boolean
          }> = []
          const removed: Array<string> = []
          let sendResult: number | undefined
          let handled:
            | {
              message: ClientMessageType
              connectionId: string
              userAgent:
                | string
                | undefined
            }
            | undefined
          const peer: RealtimeTransportPeer = {
            id: "peer-7",
            close: () => {},
            sendBinary: (
              bytes,
              compress,
            ) => {
              sent.push({
                bytes: bytes.slice(),
                compress,
              })
              return 17
            },
          }
          const runtime: LegacyRealtimeRuntime =
            {
              addConnection: (socket) => {
                expect(socket.id).toBe(
                  "peer-7",
                )
                return "connection-7"
              },
              handleMessage: async (
                message,
                context,
              ) => {
                handled = {
                  message,
                  connectionId:
                    context.connectionId,
                  userAgent:
                    context.requestMetadata
                      ?.userAgent,
                }
                sendResult =
                  context.ws.raw.sendBinary(
                    new Uint8Array([1, 2, 3]),
                    true,
                  )
              },
              removeConnection: (
                connectionId,
              ) => {
                removed.push(connectionId)
              },
            }
          const sessions =
            makeLegacyRealtimeSessions(
              async () => runtime,
            )
          const session =
            yield* sessions.open(peer, {
              userAgent: "Inline Test",
            })

          yield* session.handle(ping)
          yield* session.close

          expect(handled).toEqual({
            message: ping,
            connectionId: "connection-7",
            userAgent: "Inline Test",
          })
          expect(sent).toEqual([
            {
              bytes: new Uint8Array([
                1, 2, 3,
              ]),
              compress: true,
            },
          ])
          expect(sendResult).toBe(17)
          expect(removed).toEqual([
            "connection-7",
          ])
        }),
    )

    it.effect(
      "maps legacy startup failure without exposing its cause",
      () =>
        Effect.gen(function* () {
          const peer: RealtimeTransportPeer = {
            id: "peer-failure",
            close: () => {},
            sendBinary: (bytes) =>
              bytes.byteLength,
          }
          const sessions =
            makeLegacyRealtimeSessions(
              async () => {
                throw new Error(
                  "private module failure",
                )
              },
            )
          const failure = yield* Effect.flip(
            sessions.open(peer),
          )

          expect(failure).toBeInstanceOf(
            RealtimeSessionFailure,
          )
          expect(failure.phase).toBe("open")
        }),
    )

    it.effect(
      "requires the realtime state owner before exposing legacy sessions",
      () =>
        Effect.gen(function* () {
          const removed: Array<string> = []
          const runtime: LegacyRealtimeRuntime =
            {
              addConnection: () =>
                "owned-connection",
              handleMessage: async () => {},
              removeConnection: (
                connectionId,
              ) => {
                removed.push(connectionId)
              },
            }
          const stateLayer = Layer.succeed(
            RealtimeStateProcess,
          )({
            owners: {
              connections: {
                shutdown: () => {},
              },
              presence: {
                shutdown: () => {},
              },
            },
          })
          const sessionsLayer =
            makeLegacyRealtimeSessionsLayer(
              async () => runtime,
            ).pipe(
              Layer.provide(stateLayer),
            )
          const peer: RealtimeTransportPeer = {
            id: "owned-peer",
            close: () => {},
            sendBinary: (bytes) =>
              bytes.byteLength,
          }

          yield* RealtimeSessions.use(
            (sessions) =>
              sessions.open(peer).pipe(
                Effect.flatMap(
                  (session) => session.close,
                ),
              ),
          ).pipe(
            Effect.provide(sessionsLayer),
          )

          expect(removed).toEqual([
            "owned-connection",
          ])
        }),
    )
  },
)
