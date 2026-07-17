import type {
  ClientMessage,
} from "@inline-chat/protocol/core"
import {
  Effect,
  Layer,
} from "effect"
import type {
  RootContext,
} from "./types"
import {
  RealtimeSessionFailure,
  RealtimeSessions,
  type RealtimeProtocolSession,
  type RealtimeSessionsShape,
  type RealtimeTransportPeer,
} from "./host.effect"
import {
  RealtimeStateProcess,
} from "../ws/process.effect"

type LegacyRealtimeSocket = RootContext["ws"]

export interface LegacyRealtimeRuntime {
  readonly addConnection: (
    socket: LegacyRealtimeSocket,
  ) => string
  readonly handleMessage: (
    message: ClientMessage,
    context: RootContext,
  ) => Promise<void>
  readonly removeConnection: (
    connectionId: string,
  ) => void
}

export type LoadLegacyRealtimeRuntime =
  () => Promise<LegacyRealtimeRuntime>

const loadCurrentRealtimeRuntime: LoadLegacyRealtimeRuntime =
  async () => {
    const [
      { connectionManager, ConnVersion },
      { handleMessage },
    ] = await Promise.all([
      import("../ws/connections"),
      import("./message"),
    ])

    return {
      addConnection: (socket) =>
        connectionManager.addConnection(
          socket,
          ConnVersion.REALTIME_V1,
        ),
      handleMessage,
      removeConnection: (connectionId) =>
        connectionManager.removeConnection(
          connectionId,
        ),
    }
  }

/**
 * The only structural Elysia compatibility leaf in the replacement realtime
 * host. The current protocol handlers require `ws.raw.sendBinary`, `ws.id`,
 * and synchronous close; those exact calls delegate to the injected peer.
 *
 * TODO(effect-cutover): remove this shim after `handleMessage` and
 * `ConnectionManager` accept `RealtimeTransportPeer` directly.
 */
const makeLegacySocket = (
  peer: RealtimeTransportPeer,
): LegacyRealtimeSocket =>
  ({
    id: peer.id,
    close: peer.close,
    raw: {
      sendBinary: (
        bytes: Uint8Array,
        compress = false,
      ) => peer.sendBinary(bytes, compress),
    },
  } as LegacyRealtimeSocket)

export const makeLegacyRealtimeSessions = (
  loadRuntime: LoadLegacyRealtimeRuntime =
    loadCurrentRealtimeRuntime,
): RealtimeSessionsShape => ({
  open: (peer, metadata) =>
    Effect.tryPromise({
      try: async () => {
        const runtime = await loadRuntime()
        const socket = makeLegacySocket(peer)
        const connectionId =
          runtime.addConnection(socket)

        const session: RealtimeProtocolSession =
          {
            connectionId,
            handle: (message) =>
              Effect.tryPromise({
                try: () =>
                  runtime.handleMessage(
                    message,
                    {
                      ws: socket,
                      connectionId,
                      requestMetadata:
                        metadata,
                    },
                  ),
                catch: (cause) =>
                  new RealtimeSessionFailure({
                    cause,
                    connectionId,
                    phase: "message",
                  }),
              }),
            close: Effect.try({
              try: () =>
                runtime.removeConnection(
                  connectionId,
                ),
              catch: (cause) =>
                new RealtimeSessionFailure({
                  cause,
                  connectionId,
                  phase: "close",
                }),
            }),
          }

        return session
      },
      catch: (cause) =>
        new RealtimeSessionFailure({
          cause,
          phase: "open",
        }),
    }),
})

export const makeLegacyRealtimeSessionsLayer = (
  loadRuntime: LoadLegacyRealtimeRuntime =
    loadCurrentRealtimeRuntime,
) =>
  Layer.effect(
    RealtimeSessions,
    RealtimeStateProcess.use(() =>
      Effect.succeed(
        makeLegacyRealtimeSessions(loadRuntime),
      ),
    ),
  )

export const LegacyRealtimeSessionsLive =
  makeLegacyRealtimeSessionsLayer()
