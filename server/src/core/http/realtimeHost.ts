import { makeConnectionAdmission, REALTIME_FRAME_BYTES, PREAUTH_FRAME_BYTES, type ConnectionLease } from "../../realtime/admission"
import type {
  Server,
  ServerWebSocket,
} from "bun"
import {
  isIP,
} from "node:net"
import {
  Context,
  Effect,
  Exit,
  Schema,
} from "effect"
import {
  ErrorReporter,
} from "../errors/errorReporter"
import type {
  TrustedClientIpHeader,
} from "./middleware"
import {
  RealtimeSessions,
  makeRealtimeHostConnection,
  type RealtimeHostConnection,
} from "../../realtime/host.effect"
import type {
  RealtimeRequestMetadata,
} from "../../realtime/types"
import {
  RealtimeConnectionId,
  toRealtimeMetadataValue,
} from "../../realtime/transportSchema.effect"

const REALTIME_PATH = "/realtime"
const REALTIME_BACKPRESSURE_LIMIT =
  16 * 1024 * 1024

export interface RealtimeWebSocketData {
  readonly id: RealtimeConnectionId
  readonly metadata?:
    | RealtimeRequestMetadata
    | undefined
  admissionLease?: ConnectionLease | undefined
  isAuthenticated?: (() => boolean) | undefined
  pendingMessages?: number | undefined
  pendingBytes?: number | undefined
  messageWindow?: { start: number; count: number } | undefined
  closed: boolean
  connection:
    | Promise<
      RealtimeHostConnection | undefined
    >
    | undefined
}

export interface CoreRealtimeTransport {
  readonly shutdown: () => Promise<void>
  readonly tryUpgrade: (
    request: Request,
    server: Server<
      RealtimeWebSocketData
    >,
  ) => boolean | Response
  readonly websocket:
    Bun.WebSocketHandler<
      RealtimeWebSocketData
    >
}

export interface CoreRealtimeTransportOptions {
  readonly clientIpHeader?:
    | TrustedClientIpHeader
    | undefined
}

const decodeConnectionId =
  Schema.decodeUnknownSync(
    RealtimeConnectionId,
  )

const headerValue = (
  request: Request,
  name: string,
): string | undefined =>
  toRealtimeMetadataValue(
    request.headers.get(name),
  )

const realtimeMetadata = (
  request: Request,
  server: Server<
    RealtimeWebSocketData
  >,
  clientIpHeader:
    | TrustedClientIpHeader
    | undefined,
): RealtimeRequestMetadata | undefined => {
  const trustedClientIp =
    clientIpHeader === undefined
      ? undefined
      : (() => {
        const value = headerValue(
          request,
          clientIpHeader,
        )
        return value !== undefined &&
            isIP(value) !== 0
          ? value
          : undefined
      })()
  const metadata: RealtimeRequestMetadata = {
    ip:
      trustedClientIp ??
      server.requestIP(request)?.address,
    userAgent: headerValue(
      request,
      "user-agent",
    ),
    origin: headerValue(
      request,
      "origin",
    ),
    host: headerValue(request, "host"),
  }

  return Object.values(metadata).some(
    (value) => value !== undefined,
  )
    ? metadata
    : undefined
}

const binaryFrame = (
  message: Buffer<ArrayBuffer>,
): Uint8Array =>
  new Uint8Array(
    message.buffer,
    message.byteOffset,
    message.byteLength,
  )

/**
 * Raw Bun WebSocket transport for Inline's protobuf realtime protocol.
 *
 * Protocol decoding, error reporting, and session ownership remain in the
 * Effect host; this adapter owns only upgrade metadata and Bun callbacks.
 */
export const makeCoreRealtimeTransport = <
  Services,
>(
  context: Context.Context<
    | Services
    | ErrorReporter
    | RealtimeSessions
  >,
  {
    clientIpHeader,
  }: CoreRealtimeTransportOptions = {},
): CoreRealtimeTransport => {
  const runPromiseExit =
    Effect.runPromiseExitWith(context)
  const connections = new Set<
    Promise<
      RealtimeHostConnection | undefined
    >
  >()
  const inFlight = new Set<
    Promise<void>
  >()
  let accepting = true
  const admission = makeConnectionAdmission()
  let pendingMessages = 0
  let pendingBytes = 0

  const track = (
    operation: Promise<void>,
  ): Promise<void> => {
    inFlight.add(operation)
    void operation.then(
      () => {
        inFlight.delete(operation)
      },
      () => {
        inFlight.delete(operation)
      },
    )
    return operation
  }

  const openConnection = async (
    websocket: ServerWebSocket<
      RealtimeWebSocketData
    >,
  ): Promise<
    RealtimeHostConnection | undefined
  > => {
    const peer = {
      id: websocket.data.id,
      close: () => websocket.close(),
      sendBinary: (
        bytes: Uint8Array,
        compress: boolean,
      ) =>
        websocket.sendBinary(
          bytes,
          compress,
        ),
    }
    const exit = await runPromiseExit(
      makeRealtimeHostConnection(
        peer,
        websocket.data.metadata,
      ),
    )

    if (Exit.isFailure(exit)) {
      websocket.close(
        1011,
        "Realtime session failed to open.",
      )
      return undefined
    }

    if (websocket.data.closed) {
      await runPromiseExit(
        exit.value.close,
      )
      return undefined
    }

    websocket.data.isAuthenticated = exit.value.isAuthenticated
    return exit.value
  }

  const websocket:
    Bun.WebSocketHandler<
      RealtimeWebSocketData
    > = {
      maxPayloadLength: REALTIME_FRAME_BYTES,
      backpressureLimit:
        REALTIME_BACKPRESSURE_LIMIT,
      closeOnBackpressureLimit: false,
      idleTimeout: 480,
      perMessageDeflate: {
        compress: "32KB",
        decompress: "32KB",
      },
      sendPings: true,
      open: (socket) => {
        if (socket.data.admissionLease && !socket.data.admissionLease.activate()) { socket.close(1013, "Upgrade expired"); return }
        const connection =
          openConnection(socket)
        socket.data.connection = connection
        connections.add(connection)
      },
      message: async (socket, message) => {
        if (socket.data.closed) return
        const length = typeof message === "string" ? Buffer.byteLength(message) : message.byteLength
        if (length > (socket.data.isAuthenticated?.() ? REALTIME_FRAME_BYTES : PREAUTH_FRAME_BYTES)) {
          socket.close(1009, "Realtime frame too large")
          return
        }
        const now = Date.now()
        let window = socket.data.messageWindow
        if (!window || now - window.start >= 1_000) {
          window = { start: now, count: 0 }
          socket.data.messageWindow = window
        }
        if (++window.count > 120 || (socket.data.pendingMessages ?? 0) >= 32 || pendingMessages >= 2_048 ||
          (socket.data.pendingBytes ?? 0) + length > 32 * 1024 * 1024 || pendingBytes + length > 128 * 1024 * 1024) {
          socket.close(1013, "Realtime capacity reached")
          return
        }
        socket.data.pendingMessages = (socket.data.pendingMessages ?? 0) + 1
        socket.data.pendingBytes = (socket.data.pendingBytes ?? 0) + length
        pendingMessages++
        pendingBytes += length
        try {
          const connection = await socket.data.connection
          if (!connection || socket.data.closed) { socket.close(1011, "Realtime session unavailable"); return }
          await runPromiseExit(connection.receive(typeof message === "string" ? message : binaryFrame(message)))
        } finally {
          socket.data.pendingMessages--
          socket.data.pendingBytes -= length
          pendingMessages--
          pendingBytes -= length
        }
      },
      close: (socket) => {
        socket.data.closed = true
        socket.data.admissionLease?.release()
        const pending =
          socket.data.connection
        if (pending === undefined) {
          return
        }

        return track(
          pending.then(
            async (connection) => {
              if (
                connection !== undefined
              ) {
                await runPromiseExit(
                  connection.close,
                )
              }
              connections.delete(pending)
            },
          ),
        )
      },
    }

  return {
    tryUpgrade: (
      request,
      server,
    ) => {
      if (
        !accepting ||
        new URL(request.url).pathname !==
          REALTIME_PATH
      ) {
        return false
      }

      const metadata = realtimeMetadata(request, server, clientIpHeader)
      const lease = admission.acquire(metadata?.ip ?? "unknown")
      if (!lease) return new Response("Realtime capacity reached", { status: 429, headers: { "Retry-After": "60" } })
      try {
        const upgraded = server.upgrade(request, {
          data: { id: decodeConnectionId(crypto.randomUUID()), metadata, closed: false,
            connection: undefined, admissionLease: lease },
        })
        if (!upgraded) lease.release()
        return upgraded
      } catch (error) { lease.release(); throw error }

    },
    shutdown: async () => {
      accepting = false
      admission.shutdown()
      const active = [
        ...connections,
      ]
      await Promise.allSettled(
        active.map(
          async (pending) => {
            const connection =
              await pending
            if (
              connection !== undefined
            ) {
              await runPromiseExit(
                connection.close,
              )
            }
          },
        ),
      )

      while (inFlight.size > 0) {
        await Promise.allSettled(
          inFlight,
        )
      }
    },
    websocket,
  }
}
