import {
  InlineProtocolAuthorizationInvalidated,
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
import productionTrustRoots from "@inline-chat/protocol/trust-roots/inline-protocol-production.json"
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
import {
  connectionManager,
  ConnVersion,
  REALTIME_CLOSE_SESSION_REVOKED,
  REALTIME_CLOSE_SESSION_REVOKED_REASON,
} from "@in/server/ws/connections"
import type { RealtimeRequestMetadata } from "@in/server/realtime/types"
import type { TrustedClientIpHeader } from "./middleware"
import { Log } from "@in/server/utils/log"
import { BoundedLogAggregator } from "@in/server/utils/logging/boundedLogAggregator"

const REALTIME_V3_PATH = "/realtime/v3"
const INLINE_PROTOCOL_VERIFICATION_PATH = "/.well-known/inline-protocol"
const PROTOCOL_CLOSE_CODE = 1002
const PROTOCOL_CLOSE_REASON = "Protocol error"
const OVERLOAD_CLOSE_CODE = 1013
const OVERLOAD_CLOSE_REASON = "Realtime V3 overloaded"
const BACKPRESSURE_LIMIT = 16 * 1024 * 1024
const MAX_QUEUED_INBOUND_FRAMES = 32
const MAX_QUEUED_INBOUND_BYTES = 32 * 1024 * 1024
const MAX_QUEUED_OUTBOUND_RECORDS = 4096
const MAX_QUEUED_OUTBOUND_BYTES = 32 * 1024 * 1024
const MAX_CONCURRENT_HANDSHAKES = 256
const MAX_CONCURRENT_HANDSHAKES_PER_IP = 8
const HANDSHAKE_RATE_WINDOW_MS = 60_000
const MAX_HANDSHAKE_STARTS_PER_WINDOW = 4_096
const MAX_HANDSHAKE_STARTS_PER_IP_PER_WINDOW = 60
const MAX_CONCURRENT_APPLICATIONS = 512
const MAX_CONCURRENT_APPLICATIONS_PER_AUTHORITY = 64
const MAX_BUFFERED_APPLICATION_UPDATE_BYTES = 256 * 1024 * 1024
const OVERLOAD_LOG_WINDOW_MS = 60_000
export const realtimeV3Log = new Log("InlineProtocol.V3")

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
  handshakeAdmissionIp?: string
  closed: boolean
  state?: InlineProtocolConnectionState
}

type InlineProtocolConnectionState = {
  session: InlineProtocolServerSession
  carrier?: ObfuscatedServerHeader
  queue: Promise<void>
  outboundQueue: Promise<void>
  applicationTasks: Set<Promise<void>>
  inboundQueuedFrames: number
  inboundQueuedBytes: number
  outboundQueuedRecords: number
  outboundQueuedBytes: number
  compatibilityQueuedUpdates: number
  overloaded: boolean
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

const closeOverloaded = (socket: ServerWebSocket<InlineProtocolWebSocketData>): void => {
  if (socket.data.state) socket.data.state.overloaded = true
  if (!socket.data.closed) socket.close(OVERLOAD_CLOSE_CODE, OVERLOAD_CLOSE_REASON)
}

const closeAuthorizationInvalidated = (socket: ServerWebSocket<InlineProtocolWebSocketData>): void => {
  if (!socket.data.closed) {
    socket.close(REALTIME_CLOSE_SESSION_REVOKED, REALTIME_CLOSE_SESSION_REVOKED_REASON)
  }
}

export const makeInlineProtocolRuntime = (
  configuration: InlineProtocolEnabledConfiguration,
): InlineProtocolRuntime => {
  const nowSeconds = () => Math.floor(Date.now() / 1_000)
  const signer = makeInlineProtocolRsaSigner(configuration.rsaPrivateKeysJson, {
    requiredPublicRing: configuration.requireCanonicalPublicRing
      ? productionTrustRoots.rsaPublicKeyRing
      : undefined,
  })
  const permanent = new PermanentAuthorizationKeyRepository(
    makeAuthorizationKeyCipher(configuration.authKeyKekRing),
  )
  const temporary = new TemporaryAuthorizationKeyStore(nowSeconds)
  const replay = makeInlineProtocolReplayRepository()
  return {
    rsaKeys: signer.handshakeKeys,
    authorizationKeys: new InlineProtocolAuthorizationKeys(permanent, temporary),
    replay,
    operations: new InlineProtocolOperations(
      new InlineProtocolAuthOperations(configuration.authCodePepperRing),
    ),
    clock: inlineProtocolClock,
    close: () => {
      replay.close()
      temporary.clear()
    },
  }
}

export const makeInlineProtocolRealtimeTransport = (
  runtime: InlineProtocolRuntime,
  {
    clientIpHeader,
    maximumBufferedApplicationUpdateBytes = MAX_BUFFERED_APPLICATION_UPDATE_BYTES,
    applicationDispatcherFactory = (input) => makeInlineProtocolApplicationDispatcher({
      operations: runtime.operations,
      authorizationKeys: runtime.authorizationKeys,
      ...input,
    }),
  }: {
    clientIpHeader?: TrustedClientIpHeader
    maximumBufferedApplicationUpdateBytes?: number
    applicationDispatcherFactory?: (input: {
      connectionId: string
      metadata?: RealtimeRequestMetadata
      onAuthorized: (authorization: ServerApplicationAuthorization) => void
    }) => ServerApplicationDispatcher
  } = {},
): InlineProtocolRealtimeTransport => {
  if (!Number.isSafeInteger(maximumBufferedApplicationUpdateBytes) ||
      maximumBufferedApplicationUpdateBytes < 1) {
    throw new RangeError("Invalid Inline Protocol application-update byte budget")
  }
  const sockets = new Set<ServerWebSocket<InlineProtocolWebSocketData>>()
  const drainingConnections = new Set<Promise<void>>()
  const handshakeCapacityRejectedRequests = new WeakSet<Request>()
  const handshakesByIp = new Map<string, number>()
  const handshakeStartsByIp = new Map<string, number>()
  let activeHandshakes = 0
  let handshakeStarts = 0
  let handshakeRateWindow = -1
  let activeApplications = 0
  const activeApplicationsByAuthority = new Map<string, number>()
  let bufferedApplicationUpdateBytes = 0
  let accepting = true
  const overloadLogs = new BoundedLogAggregator(OVERLOAD_LOG_WINDOW_MS, 8)

  const warnOverload = (
    key: string,
    message: string,
    metadata: Record<string, unknown>,
  ): void => {
    const decision = overloadLogs.record(key)
    if (!decision.emit) return
    realtimeV3Log.warn(message, {
      ...metadata,
      suppressedCount: decision.suppressedCount,
    })
  }

  const applicationAuthorityKey = (authorization: ServerApplicationAuthorization): string =>
    authorization.accountSessionId === undefined
      ? `auth:${Buffer.from(authorization.authKeyId).toString("hex")}`
      : `account:${authorization.accountSessionId}`

  const tryAcquireApplication = (
    authorization: ServerApplicationAuthorization,
  ): (() => void) | undefined => {
    const authorityKey = applicationAuthorityKey(authorization)
    const authorityApplications = activeApplicationsByAuthority.get(authorityKey) ?? 0
    if (activeApplications >= MAX_CONCURRENT_APPLICATIONS ||
        authorityApplications >= MAX_CONCURRENT_APPLICATIONS_PER_AUTHORITY) {
      warnOverload("application", "Inline Protocol V3 application admission overloaded", {
        activeApplications,
        globalCapacity: MAX_CONCURRENT_APPLICATIONS,
        authorityApplications,
        authorityCapacity: MAX_CONCURRENT_APPLICATIONS_PER_AUTHORITY,
        authorityKind: authorization.accountSessionId === undefined ? "auth-key" : "account-session",
      })
      return undefined
    }
    activeApplications += 1
    activeApplicationsByAuthority.set(authorityKey, authorityApplications + 1)
    let released = false
    return () => {
      if (released) return
      released = true
      activeApplications = Math.max(0, activeApplications - 1)
      const remaining = (activeApplicationsByAuthority.get(authorityKey) ?? 1) - 1
      if (remaining <= 0) activeApplicationsByAuthority.delete(authorityKey)
      else activeApplicationsByAuthority.set(authorityKey, remaining)
    }
  }

  const tryReserveApplicationUpdateBytes = (bytes: number): (() => void) | undefined => {
    if (!Number.isSafeInteger(bytes) || bytes < 0 ||
        bufferedApplicationUpdateBytes + bytes > maximumBufferedApplicationUpdateBytes) return undefined
    bufferedApplicationUpdateBytes += bytes
    let released = false
    return () => {
      if (released) return
      released = true
      bufferedApplicationUpdateBytes = Math.max(0, bufferedApplicationUpdateBytes - bytes)
    }
  }

  const handshakeAdmissionIp = (metadata: RealtimeRequestMetadata | undefined): string =>
    metadata?.ip ?? "unknown"

  const refreshHandshakeRateWindow = (): void => {
    const currentWindow = Math.floor(runtime.clock.nowMilliseconds() / HANDSHAKE_RATE_WINDOW_MS)
    if (currentWindow === handshakeRateWindow) return
    handshakeRateWindow = currentWindow
    handshakeStarts = 0
    handshakeStartsByIp.clear()
  }

  const canAdmitHandshake = (ip: string): boolean => {
    refreshHandshakeRateWindow()
    return activeHandshakes < MAX_CONCURRENT_HANDSHAKES &&
      (handshakesByIp.get(ip) ?? 0) < MAX_CONCURRENT_HANDSHAKES_PER_IP &&
      handshakeStarts < MAX_HANDSHAKE_STARTS_PER_WINDOW &&
      (handshakeStartsByIp.get(ip) ?? 0) < MAX_HANDSHAKE_STARTS_PER_IP_PER_WINDOW
  }

  const reserveHandshake = (ip: string): void => {
    activeHandshakes += 1
    handshakesByIp.set(ip, (handshakesByIp.get(ip) ?? 0) + 1)
    handshakeStarts += 1
    handshakeStartsByIp.set(ip, (handshakeStartsByIp.get(ip) ?? 0) + 1)
  }

  const releaseHandshake = (socket: ServerWebSocket<InlineProtocolWebSocketData>): void => {
    const ip = socket.data.handshakeAdmissionIp
    if (!ip) return
    const current = handshakesByIp.get(ip) ?? 0
    if (current <= 1) handshakesByIp.delete(ip)
    else handshakesByIp.set(ip, current - 1)
    activeHandshakes = Math.max(0, activeHandshakes - 1)
    socket.data.handshakeAdmissionIp = undefined
  }

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
        realtimeV3Log.trace("Inline Protocol V3 session queue delayed", {
          connectionId: socket.data.id,
          queueWaitMs,
        })
      }
      await operation()
    }).catch((error) => {
      realtimeV3Log.trace("Inline Protocol V3 connection failed", {
        connectionId: socket.data.id,
        error,
      })
      if (error instanceof InlineProtocolAuthorizationInvalidated) {
        closeAuthorizationInvalidated(socket)
      } else {
        closeProtocol(socket)
      }
    })
    return state.queue
  }

  const enqueueOutbound = (
    socket: ServerWebSocket<InlineProtocolWebSocketData>,
    records: number,
    bytes: number,
    operation: (carrier: ObfuscatedServerHeader) => void,
  ): Promise<void> => {
    const state = socket.data.state
    if (!state || socket.data.closed || state.overloaded) return Promise.resolve()
    if (state.outboundQueuedRecords + records > MAX_QUEUED_OUTBOUND_RECORDS ||
        state.outboundQueuedBytes + bytes > MAX_QUEUED_OUTBOUND_BYTES) {
      warnOverload("outbound", "Inline Protocol V3 outbound queue overloaded", {
        queuedRecords: state.outboundQueuedRecords,
        queuedBytes: state.outboundQueuedBytes,
        incomingRecords: records,
        incomingBytes: bytes,
      })
      closeOverloaded(socket)
      return Promise.resolve()
    }
    state.outboundQueuedRecords += records
    state.outboundQueuedBytes += bytes
    state.outboundQueue = state.outboundQueue.then(() => {
      try {
        if (socket.data.closed) return
        runtime.clock.assertHealthy()
        if (!state.carrier) throw new RangeError("Inline Protocol carrier is unavailable")
        operation(state.carrier)
      } finally {
        state.outboundQueuedRecords -= records
        state.outboundQueuedBytes -= bytes
      }
    }).catch((error) => {
      realtimeV3Log.trace("Inline Protocol V3 outbound carrier failed", {
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
  ): Promise<void> => enqueueOutbound(
    socket,
    records.length,
    records.reduce((total, record) => total + record.length + 4, 0),
    (carrier) => {
      for (const record of records) {
        socket.sendBinary(carrier.outbound.process(encodeAbridgedPacket(record)), false)
      }
    },
  )

  const sendQuickAck = (
    socket: ServerWebSocket<InlineProtocolWebSocketData>,
    quickAckId: number,
  ): Promise<void> => enqueueOutbound(socket, 1, 4, (carrier) => {
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
      const responseDurationMs = Math.round(performance.now() - handlerStartedAt)
      realtimeV3Log.trace("Inline Protocol V3 application response ready", {
        connectionId: socket.data.id,
        requestMessageId: task.messageId.toString(),
        responseDurationMs,
        executionPending: completion.settlement !== undefined,
        inFlightApplications: state.applicationTasks.size,
      })
      const finalize = async (
        applicationCompletion: Awaited<ReturnType<InlineProtocolServerApplicationTask["dispatch"]>>,
        executionPending: boolean,
      ): Promise<void> => enqueue(socket, async () => {
        const finalizationStartedAt = performance.now()
        const finalized = await applicationCompletion.finalize()
        const finalizationDurationMs = Math.round(performance.now() - finalizationStartedAt)
        realtimeV3Log.trace("Inline Protocol V3 application finalized", {
          connectionId: socket.data.id,
          requestMessageId: task.messageId.toString(),
          responseDurationMs,
          executionPending,
          finalizationDurationMs,
          responseCount: finalized.responses.length,
          releasedApplicationCount: finalized.applicationTasks.length,
        })
        if (!socket.data.closed) void sendRecords(socket, finalized.responses)
        for (const released of finalized.applicationTasks) scheduleApplicationTask(socket, released)
        closeDestroyedSessionAfterWrites(socket)
      }, { allowClosed: true })
      await finalize(completion, completion.settlement !== undefined)
      if (completion.settlement) {
        const settlement = await completion.settlement
        await finalize(settlement, false)
      }
    })().catch((error) => {
      realtimeV3Log.trace("Inline Protocol V3 application dispatch failed", {
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
    if (!accepting || socket.data.closed || !state || state.registered) return
    const compatibilitySocket = {
      id: socket.data.id,
      close: (code?: number, reason?: string) => socket.close(code, reason),
      raw: {
        sendBinary: (bytes: Uint8Array) => {
          let payload: Uint8Array
          try {
            const legacy = ServerProtocolMessage.fromBinary(bytes)
            if (legacy.body.oneofKind !== "message") return bytes.length
            payload = RealtimeV3Update.toBinary({ message: legacy.body.message })
          } catch (error) {
            realtimeV3Log.trace("Inline Protocol V3 compatibility update was malformed", {
              connectionId: socket.data.id,
              error,
            })
            closeProtocol(socket)
            return 0
          }
          const releaseUpdateBytes = tryReserveApplicationUpdateBytes(payload.length)
          if (!releaseUpdateBytes) {
            warnOverload("retained-update", "Inline Protocol V3 compatibility update capacity exceeded", {
              updateBytes: payload.length,
              bufferedUpdateBytes: bufferedApplicationUpdateBytes,
              updateCapacity: maximumBufferedApplicationUpdateBytes,
            })
            closeOverloaded(socket)
            return 0
          }
          if (state.compatibilityQueuedUpdates >= MAX_QUEUED_OUTBOUND_RECORDS) {
            releaseUpdateBytes()
            warnOverload("compatibility-update", "Inline Protocol V3 compatibility update queue overloaded", {
              queuedUpdates: state.compatibilityQueuedUpdates,
              updateCapacity: MAX_QUEUED_OUTBOUND_RECORDS,
            })
            closeOverloaded(socket)
            return 0
          }
          state.compatibilityQueuedUpdates += 1
          void enqueue(socket, async () => {
            await sendRecords(socket, [state.session.sendApplicationUpdate(payload)])
          }).finally(() => {
            state.compatibilityQueuedUpdates -= 1
            releaseUpdateBytes()
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
      tryAcquireApplication,
      tryReserveApplicationUpdateBytes,
    })
    const state: InlineProtocolConnectionState = {
      queue: Promise.resolve(),
      outboundQueue: Promise.resolve(),
      applicationTasks: new Set(),
      inboundQueuedFrames: 0,
      inboundQueuedBytes: 0,
      outboundQueuedRecords: 0,
      outboundQueuedBytes: 0,
      compatibilityQueuedUpdates: 0,
      overloaded: false,
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
    const state = socket.data.state
    if (!state) {
      closeProtocol(socket)
      return
    }
    if (state.overloaded) return
    const frameBytes = message.byteLength
    if (state.inboundQueuedFrames >= MAX_QUEUED_INBOUND_FRAMES ||
        state.inboundQueuedBytes + frameBytes > MAX_QUEUED_INBOUND_BYTES) {
      warnOverload("inbound", "Inline Protocol V3 inbound queue overloaded", {
        queuedFrames: state.inboundQueuedFrames,
        queuedBytes: state.inboundQueuedBytes,
        incomingBytes: frameBytes,
      })
      closeOverloaded(socket)
      return
    }
    state.inboundQueuedFrames += 1
    state.inboundQueuedBytes += frameBytes
    const frame = bytesForFrame(message).slice()
    enqueue(socket, async () => {
      try {
        runtime.clock.assertHealthy()
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
        if (state.session.hasEstablishedAuthorization) releaseHandshake(socket)
        void sendRecords(socket, accepted.responses)
        for (const task of accepted.applicationTasks) scheduleApplicationTask(socket, task)
        closeDestroyedSessionAfterWrites(socket)
      } finally {
        state.inboundQueuedFrames -= 1
        state.inboundQueuedBytes -= frameBytes
      }
    })
  }

  const close = (socket: ServerWebSocket<InlineProtocolWebSocketData>): void => {
    socket.data.closed = true
    releaseHandshake(socket)
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
      const metadata = requestMetadata(request, server, clientIpHeader)
      const ip = handshakeAdmissionIp(metadata)
      if (!canAdmitHandshake(ip)) {
        warnOverload("handshake", "Inline Protocol V3 handshake admission overloaded", {
          activeHandshakes,
          globalCapacity: MAX_CONCURRENT_HANDSHAKES,
          activeHandshakesForIp: handshakesByIp.get(ip) ?? 0,
          perIpCapacity: MAX_CONCURRENT_HANDSHAKES_PER_IP,
          startsInWindow: handshakeStarts,
          globalStartsPerWindow: MAX_HANDSHAKE_STARTS_PER_WINDOW,
          startsForIpInWindow: handshakeStartsByIp.get(ip) ?? 0,
          perIpStartsPerWindow: MAX_HANDSHAKE_STARTS_PER_IP_PER_WINDOW,
        })
        handshakeCapacityRejectedRequests.add(request)
        return false
      }
      const upgraded = server.upgrade(request, {
        data: {
          protocol: "inline-v3",
          id: crypto.randomUUID(),
          metadata,
          handshakeAdmissionIp: ip,
          closed: false,
        },
      })
      if (upgraded) reserveHandshake(ip)
      return upgraded
    },
    rejectUnsupportedUpgrade: (request) => {
      if (new URL(request.url).pathname !== REALTIME_V3_PATH) return undefined
      if (!clockHealthy()) return new Response("Protocol clock unavailable.", { status: 503 })
      if (handshakeCapacityRejectedRequests.has(request)) {
        return new Response("Realtime V3 handshake capacity exceeded.", { status: 503 })
      }
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
      handshakesByIp.clear()
      handshakeStartsByIp.clear()
      activeHandshakes = 0
      handshakeStarts = 0
      activeApplications = 0
      activeApplicationsByAuthority.clear()
      bufferedApplicationUpdateBytes = 0
      runtime.close()
    },
  }
}
