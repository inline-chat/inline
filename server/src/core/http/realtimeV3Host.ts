import {
  InlineProtocolServerSession,
  acceptObfuscatedClientHeader,
  decodeAbridgedFrame,
  encodeAbridgedPacket,
  encodeAbridgedQuickAck,
  type HandshakeRsaServerKey,
  type InlineProtocolServerApplicationTask,
  type ObfuscatedServerHeader,
  type ServerApplicationAuthorization,
  type ServerApplicationDispatcher,
  type ServerAuthorizationKeyRepository,
  type ServerReplayRepository,
} from "@inline-chat/protocol/server"
import {
  RealtimeV3Update,
  ServerProtocolMessage,
} from "@inline-chat/protocol/core"
import type { Server, ServerWebSocket } from "bun"
import { gunzipSync } from "node:zlib"
import { isIP } from "node:net"
import { randomBytes } from "node:crypto"
import { PermanentAuthorizationKeyRepository } from "@in/server/db/models/inlineProtocol"
import { makeAuthorizationKeyCipher } from "@in/server/modules/inlineProtocol/keyCipher"
import { InlineProtocolAuthorizationKeys } from "@in/server/modules/inlineProtocol/authorizationKeys"
import { TemporaryAuthorizationKeyStore } from "@in/server/modules/inlineProtocol/temporaryKeys"
import { makeInlineProtocolReplayRepository } from "@in/server/modules/inlineProtocol/replay"
import { makeInlineProtocolRsaSigner } from "@in/server/modules/inlineProtocol/rsaSigner"
import { InlineProtocolAuthOperations } from "@in/server/modules/inlineProtocol/auth"
import { InlineProtocolOperations } from "@in/server/modules/inlineProtocol/operations"
import { makeInlineProtocolApplicationDispatcher } from "@in/server/modules/inlineProtocol/application"
import type { InlineProtocolEnabledConfiguration } from "@in/server/modules/inlineProtocol/config"
import {
  inlineProtocolClock,
  type InlineProtocolClock,
} from "@in/server/modules/inlineProtocol/clockHealth"
import { connectionManager, ConnVersion } from "@in/server/ws/connections"
import type { RealtimeRequestMetadata } from "@in/server/realtime/types"
import type { TrustedClientIpHeader } from "./middleware"
import { Log } from "@in/server/utils/log"

const REALTIME_V3_PATH = "/realtime/v3"
const INLINE_PROTOCOL_VERIFICATION_PATH = "/.well-known/inline-protocol"
const PROTOCOL_CLOSE_CODE = 1002
const PROTOCOL_CLOSE_REASON = "Protocol error"
const BACKPRESSURE_LIMIT = 16 * 1024 * 1024

export type InlineProtocolRuntime = {
  rsaKeys: readonly HandshakeRsaServerKey[]
  authorizationKeys: ServerAuthorizationKeyRepository
  replay: ServerReplayRepository
  operations: InlineProtocolOperations
  clock: Pick<InlineProtocolClock, "assertHealthy" | "nowMilliseconds">
  close: () => void
}

export type InlineProtocolWebSocketData = {
  readonly protocol: "inline-v3"
  readonly id: string
  readonly metadata?: RealtimeRequestMetadata
  closed: boolean
  state?: InlineProtocolConnectionState
}

type InlineProtocolConnectionState = {
  session: InlineProtocolServerSession
  carrier?: ObfuscatedServerHeader
  queue: Promise<void>
  outboundQueue: Promise<void>
  applicationTasks: Set<Promise<void>>
  registered: boolean
}

export interface InlineProtocolRealtimeTransport {
  readonly handleVerification: (request: Request) => Response | undefined
  readonly tryUpgrade: (request: Request, server: Server<InlineProtocolWebSocketData>) => boolean
  readonly rejectUnsupportedUpgrade: (request: Request) => Response | undefined
  readonly websocket: Bun.WebSocketHandler<InlineProtocolWebSocketData>
  readonly shutdown: () => Promise<void>
}

const metadataValue = (value: string | null): string | undefined => {
  const trimmed = value?.trim()
  return trimmed ? trimmed.slice(0, 512) : undefined
}

const requestMetadata = (
  request: Request,
  server: Server<InlineProtocolWebSocketData>,
  trustedHeader: TrustedClientIpHeader | undefined,
): RealtimeRequestMetadata | undefined => {
  const forwarded = trustedHeader ? metadataValue(request.headers.get(trustedHeader)) : undefined
  const trustedIp = forwarded && isIP(forwarded) !== 0 ? forwarded : undefined
  const value: RealtimeRequestMetadata = {
    ip: trustedIp ?? server.requestIP(request)?.address,
    userAgent: metadataValue(request.headers.get("user-agent")),
    origin: metadataValue(request.headers.get("origin")),
    host: metadataValue(request.headers.get("host")),
  }
  return Object.values(value).some((entry) => entry !== undefined) ? value : undefined
}

const bytesForFrame = (message: Buffer<ArrayBuffer>): Uint8Array =>
  new Uint8Array(message.buffer, message.byteOffset, message.byteLength)

const closeProtocol = (socket: ServerWebSocket<InlineProtocolWebSocketData>): void => {
  if (!socket.data.closed) socket.close(PROTOCOL_CLOSE_CODE, PROTOCOL_CLOSE_REASON)
}

export const makeInlineProtocolRuntime = (
  configuration: InlineProtocolEnabledConfiguration,
): InlineProtocolRuntime => {
  const nowSeconds = () => Math.floor(Date.now() / 1_000)
  const signer = makeInlineProtocolRsaSigner(configuration.rsaPrivateKeysJson)
  const permanent = new PermanentAuthorizationKeyRepository(
    makeAuthorizationKeyCipher(configuration.authKeyKekRing),
  )
  const temporary = new TemporaryAuthorizationKeyStore(nowSeconds)
  return {
    rsaKeys: signer.handshakeKeys,
    authorizationKeys: new InlineProtocolAuthorizationKeys(permanent, temporary),
    replay: makeInlineProtocolReplayRepository(),
    operations: new InlineProtocolOperations(
      new InlineProtocolAuthOperations(configuration.authCodePepperRing),
    ),
    clock: inlineProtocolClock,
    close: () => temporary.clear(),
  }
}

export const makeInlineProtocolRealtimeTransport = (
  runtime: InlineProtocolRuntime,
  {
    clientIpHeader,
    applicationDispatcherFactory = (input) => makeInlineProtocolApplicationDispatcher({
      operations: runtime.operations,
      ...input,
    }),
  }: {
    clientIpHeader?: TrustedClientIpHeader
    applicationDispatcherFactory?: (input: {
      connectionId: string
      metadata?: RealtimeRequestMetadata
      onAuthorized: (authorization: ServerApplicationAuthorization) => void
    }) => ServerApplicationDispatcher
  } = {},
): InlineProtocolRealtimeTransport => {
  const sockets = new Set<ServerWebSocket<InlineProtocolWebSocketData>>()
  const drainingConnections = new Set<Promise<void>>()
  let accepting = true

  const clockHealthy = (): boolean => {
    try {
      runtime.clock.assertHealthy()
      return true
    } catch {
      return false
    }
  }

  const enqueue = (
    socket: ServerWebSocket<InlineProtocolWebSocketData>,
    operation: () => Promise<void>,
    { allowClosed = false }: { allowClosed?: boolean } = {},
  ): Promise<void> => {
    const state = socket.data.state
    if (!state || (socket.data.closed && !allowClosed)) return Promise.resolve()
    const queuedAt = performance.now()
    state.queue = state.queue.then(async () => {
      if (socket.data.closed && !allowClosed) return
      const queueWaitMs = Math.round(performance.now() - queuedAt)
      if (queueWaitMs >= 100) {
        Log.shared.debug("Inline Protocol V3 session queue delayed", {
          connectionId: socket.data.id,
          queueWaitMs,
        })
      }
      await operation()
    }).catch((error) => {
      Log.shared.debug("Inline Protocol V3 connection failed", {
        connectionId: socket.data.id,
        error,
      })
      closeProtocol(socket)
    })
    return state.queue
  }

  const enqueueOutbound = (
    socket: ServerWebSocket<InlineProtocolWebSocketData>,
    operation: (carrier: ObfuscatedServerHeader) => void,
  ): Promise<void> => {
    const state = socket.data.state
    if (!state || socket.data.closed) return Promise.resolve()
    state.outboundQueue = state.outboundQueue.then(() => {
      if (socket.data.closed) return
      runtime.clock.assertHealthy()
      if (!state.carrier) throw new RangeError("Inline Protocol carrier is unavailable")
      operation(state.carrier)
    }).catch((error) => {
      Log.shared.debug("Inline Protocol V3 outbound carrier failed", {
        connectionId: socket.data.id,
        error,
      })
      closeProtocol(socket)
    })
    return state.outboundQueue
  }

  const sendRecords = (
    socket: ServerWebSocket<InlineProtocolWebSocketData>,
    records: readonly Uint8Array[],
  ): Promise<void> => enqueueOutbound(socket, (carrier) => {
    for (const record of records) {
      socket.sendBinary(carrier.outbound.process(encodeAbridgedPacket(record)), false)
    }
  })

  const sendQuickAck = (
    socket: ServerWebSocket<InlineProtocolWebSocketData>,
    quickAckId: number,
  ): Promise<void> => enqueueOutbound(socket, (carrier) => {
    socket.sendBinary(carrier.outbound.process(encodeAbridgedQuickAck(quickAckId)), false)
  })

  const closeDestroyedSessionAfterWrites = (
    socket: ServerWebSocket<InlineProtocolWebSocketData>,
  ): void => {
    const state = socket.data.state
    if (!state || socket.data.closed || !state.session.destroyed) return
    state.outboundQueue = state.outboundQueue.then(() => {
      if (!socket.data.closed) socket.close(1000, "Protocol session closed")
    })
  }

  const scheduleApplicationTask = (
    socket: ServerWebSocket<InlineProtocolWebSocketData>,
    task: InlineProtocolServerApplicationTask,
  ): void => {
    const state = socket.data.state
    if (!state) return
    const handlerStartedAt = performance.now()
    const execution = (async () => {
      const completion = await task.dispatch()
      const handlerDurationMs = Math.round(performance.now() - handlerStartedAt)
      Log.shared.debug("Inline Protocol V3 application handler completed", {
        connectionId: socket.data.id,
        requestMessageId: task.messageId.toString(),
        handlerDurationMs,
        inFlightApplications: state.applicationTasks.size,
      })
      await enqueue(socket, async () => {
        const finalizationStartedAt = performance.now()
        const finalized = await completion.finalize()
        const finalizationDurationMs = Math.round(performance.now() - finalizationStartedAt)
        Log.shared.debug("Inline Protocol V3 application finalized", {
          connectionId: socket.data.id,
          requestMessageId: task.messageId.toString(),
          handlerDurationMs,
          finalizationDurationMs,
          responseCount: finalized.responses.length,
          releasedApplicationCount: finalized.applicationTasks.length,
        })
        if (!socket.data.closed) void sendRecords(socket, finalized.responses)
        for (const released of finalized.applicationTasks) scheduleApplicationTask(socket, released)
        closeDestroyedSessionAfterWrites(socket)
      }, { allowClosed: true })
    })().catch((error) => {
      Log.shared.debug("Inline Protocol V3 application dispatch failed", {
        connectionId: socket.data.id,
        requestMessageId: task.messageId.toString(),
        error,
      })
      closeProtocol(socket)
    })
    state.applicationTasks.add(execution)
    void execution.finally(() => state.applicationTasks.delete(execution))
  }

  const drainConnectionState = async (state: InlineProtocolConnectionState): Promise<void> => {
    await state.queue
    while (state.applicationTasks.size > 0) {
      await Promise.allSettled(state.applicationTasks)
      await state.queue
    }
    await state.outboundQueue
  }

  const trackClosedConnection = (state: InlineProtocolConnectionState): void => {
    const draining = drainConnectionState(state)
    drainingConnections.add(draining)
    void draining.finally(() => drainingConnections.delete(draining))
  }

  const registerAuthenticatedConnection = (
    socket: ServerWebSocket<InlineProtocolWebSocketData>,
    userId: number,
    accountSessionId: number,
  ): void => {
    const state = socket.data.state
    if (!state || state.registered) return
    const compatibilitySocket = {
      id: socket.data.id,
      close: () => socket.close(),
      raw: {
        sendBinary: (bytes: Uint8Array) => {
          enqueue(socket, async () => {
            const legacy = ServerProtocolMessage.fromBinary(bytes)
            if (legacy.body.oneofKind !== "message") return
            const payload = RealtimeV3Update.toBinary({ message: legacy.body.message })
            void sendRecords(socket, [state.session.sendApplicationUpdate(payload)])
          })
          return bytes.length
        },
      },
    }
    connectionManager.addConnection(compatibilitySocket as never, ConnVersion.REALTIME_V3)
    connectionManager.authenticateConnection(socket.data.id, userId, accountSessionId, 3)
    state.registered = true
  }

  const open = (socket: ServerWebSocket<InlineProtocolWebSocketData>): void => {
    const session = new InlineProtocolServerSession({
      rsaKeys: runtime.rsaKeys,
      authorizationKeys: runtime.authorizationKeys,
      replay: runtime.replay,
      application: applicationDispatcherFactory({
        connectionId: socket.data.id,
        metadata: socket.data.metadata,
        onAuthorized: (authorization) => {
          if (authorization.userId !== undefined && authorization.accountSessionId !== undefined) {
            registerAuthenticatedConnection(socket, authorization.userId, authorization.accountSessionId)
          }
        },
      }),
      randomBytes: (length) => Uint8Array.from(randomBytes(length)),
      nowMilliseconds: () => runtime.clock.nowMilliseconds(),
      gunzip: (packed, maximumOutputBytes) => Uint8Array.from(gunzipSync(packed, {
        maxOutputLength: maximumOutputBytes,
      })),
      carrierProfile: "websocket",
      dc: 1,
    })
    const state: InlineProtocolConnectionState = {
      queue: Promise.resolve(),
      outboundQueue: Promise.resolve(),
      applicationTasks: new Set(),
      registered: false,
      session,
    }
    socket.data.state = state
    sockets.add(socket)
  }

  const receive = (socket: ServerWebSocket<InlineProtocolWebSocketData>, message: string | Buffer<ArrayBuffer>): void => {
    if (typeof message === "string") {
      closeProtocol(socket)
      return
    }
    const frame = bytesForFrame(message).slice()
    enqueue(socket, async () => {
      runtime.clock.assertHealthy()
      const state = socket.data.state
      if (!state) throw new RangeError("Inline Protocol session is unavailable")
      if (!state.carrier) {
        if (frame.length !== 64) throw new RangeError("Inline Protocol header must be exactly one frame")
        state.carrier = acceptObfuscatedClientHeader(frame, 1)
        return
      }
      const decoded = decodeAbridgedFrame(state.carrier.inbound.process(frame))
      if (decoded.kind !== "packet") throw new RangeError("Clients cannot send quick-ACK responses")
      if (decoded.quickAckRequested && decoded.payload.slice(0, 8).every((byte) => byte === 0)) {
        throw new RangeError("Quick ACK is unavailable for unencrypted handshake packets")
      }
      const accepted = await state.session.receiveConcurrent(decoded.payload, decoded.quickAckRequested
        ? { onQuickAck: (quickAckId) => { void sendQuickAck(socket, quickAckId) } }
        : undefined)
      void sendRecords(socket, accepted.responses)
      for (const task of accepted.applicationTasks) scheduleApplicationTask(socket, task)
      closeDestroyedSessionAfterWrites(socket)
    })
  }

  const close = (socket: ServerWebSocket<InlineProtocolWebSocketData>): void => {
    socket.data.closed = true
    sockets.delete(socket)
    if (socket.data.state) {
      if (socket.data.state.registered) connectionManager.removeConnection(socket.data.id)
      trackClosedConnection(socket.data.state)
    }
  }

  return {
    handleVerification: (request) => {
      const url = new URL(request.url)
      if (request.method !== "GET" || url.pathname !== INLINE_PROTOCOL_VERIFICATION_PATH) return undefined
      let serverTime: number | undefined
      try {
        serverTime = Math.floor(runtime.clock.nowMilliseconds() / 1_000)
      } catch {
        serverTime = undefined
      }
      const ready = serverTime !== undefined
      return Response.json({
        protocol: "Inline Protocol",
        protocolVersion: 1,
        applicationContract: "Realtime V3",
        applicationContractVersion: 3,
        status: ready ? "ready" : "degraded",
        ...(serverTime === undefined ? {} : { serverTime }),
        websocketPath: REALTIME_V3_PATH,
        rsaPublicKeyRing: runtime.rsaKeys.map((key) => ({
          modulus: Buffer.from(key.modulus).toString("base64url"),
          exponent: Buffer.from(key.exponent).toString("base64url"),
          fingerprint: key.fingerprint.toString(),
        })),
      }, {
        status: ready ? 200 : 503,
        headers: {
          "access-control-allow-origin": "*",
          "cache-control": "no-store",
        },
      })
    },
    tryUpgrade: (request, server) => {
      if (!accepting || new URL(request.url).pathname !== REALTIME_V3_PATH || !clockHealthy()) return false
      return server.upgrade(request, {
        data: {
          protocol: "inline-v3",
          id: crypto.randomUUID(),
          metadata: requestMetadata(request, server, clientIpHeader),
          closed: false,
        },
      })
    },
    rejectUnsupportedUpgrade: (request) => {
      if (new URL(request.url).pathname !== REALTIME_V3_PATH) return undefined
      if (!clockHealthy()) return new Response("Protocol clock unavailable.", { status: 503 })
      return undefined
    },
    websocket: {
      backpressureLimit: BACKPRESSURE_LIMIT,
      closeOnBackpressureLimit: true,
      idleTimeout: 480,
      perMessageDeflate: false,
      sendPings: true,
      open,
      message: receive,
      close,
    },
    shutdown: async () => {
      accepting = false
      const active = [...sockets]
      const activeStates = active.flatMap((socket) => socket.data.state ? [socket.data.state] : [])
      for (const socket of active) socket.close(1001, "Server shutting down")
      await Promise.allSettled(activeStates.map(drainConnectionState))
      while (drainingConnections.size > 0) {
        await Promise.allSettled(drainingConnections)
      }
      sockets.clear()
      runtime.close()
    },
  }
}
