import {
  InlineProtocolServerSession,
  acceptObfuscatedClientHeader,
  decodeAbridgedFrame,
  encodeAbridgedPacket,
  encodeAbridgedQuickAck,
  type HandshakeRsaServerKey,
  type ObfuscatedServerHeader,
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
import { InlineProtocolUploadRepository } from "@in/server/db/models/inlineProtocolUploads"
import { makeAuthorizationKeyCipher } from "@in/server/modules/inlineProtocol/keyCipher"
import { InlineProtocolAuthorizationKeys } from "@in/server/modules/inlineProtocol/authorizationKeys"
import { TemporaryAuthorizationKeyStore } from "@in/server/modules/inlineProtocol/temporaryKeys"
import { makeInlineProtocolReplayRepository } from "@in/server/modules/inlineProtocol/replay"
import { makeInlineProtocolRsaSigner } from "@in/server/modules/inlineProtocol/rsaSigner"
import { InlineProtocolAuthOperations } from "@in/server/modules/inlineProtocol/auth"
import { InlineProtocolUploadOperations } from "@in/server/modules/inlineProtocol/uploads"
import { InlineProtocolOperations } from "@in/server/modules/inlineProtocol/operations"
import { makeInlineProtocolApplicationDispatcher } from "@in/server/modules/inlineProtocol/application"
import type { InlineProtocolEnabledConfiguration } from "@in/server/modules/inlineProtocol/config"
import { connectionManager, ConnVersion } from "@in/server/ws/connections"
import type { RealtimeRequestMetadata } from "@in/server/realtime/types"
import type { TrustedClientIpHeader } from "./middleware"

const REALTIME_V3_PATH = "/realtime/v3"
const PROTOCOL_CLOSE_CODE = 1002
const PROTOCOL_CLOSE_REASON = "Protocol error"
const BACKPRESSURE_LIMIT = 16 * 1024 * 1024

export type InlineProtocolRuntime = {
  rsaKeys: readonly HandshakeRsaServerKey[]
  authorizationKeys: ServerAuthorizationKeyRepository
  replay: ServerReplayRepository
  operations: InlineProtocolOperations
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
  registered: boolean
}

export interface InlineProtocolRealtimeTransport {
  readonly tryUpgrade: (request: Request, server: Server<InlineProtocolWebSocketData>) => boolean
  readonly rejectUnsupportedUpgrade: (request: Request) => Response | undefined
  readonly handleHttpUpload: (request: Request, directClientIp?: string) => Promise<Response | undefined>
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

const trustedClientIp = (
  request: Request,
  directClientIp: string | undefined,
  trustedHeader: TrustedClientIpHeader | undefined,
): string | undefined => {
  const forwarded = trustedHeader ? metadataValue(request.headers.get(trustedHeader)) : undefined
  return forwarded && isIP(forwarded) !== 0 ? forwarded : directClientIp
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
  const uploads = new InlineProtocolUploadOperations(new InlineProtocolUploadRepository())
  return {
    rsaKeys: signer.handshakeKeys,
    authorizationKeys: new InlineProtocolAuthorizationKeys(permanent, temporary),
    replay: makeInlineProtocolReplayRepository(),
    operations: new InlineProtocolOperations(
      new InlineProtocolAuthOperations(configuration.authCodePepperRing),
      uploads,
    ),
    close: () => temporary.clear(),
  }
}

export const makeInlineProtocolRealtimeTransport = (
  runtime: InlineProtocolRuntime,
  { clientIpHeader }: { clientIpHeader?: TrustedClientIpHeader } = {},
): InlineProtocolRealtimeTransport => {
  const sockets = new Set<ServerWebSocket<InlineProtocolWebSocketData>>()
  let accepting = true

  const enqueue = (socket: ServerWebSocket<InlineProtocolWebSocketData>, operation: () => Promise<void>): void => {
    const state = socket.data.state
    if (!state || socket.data.closed) return
    state.queue = state.queue.then(operation).catch(() => closeProtocol(socket))
  }

  const sendRecord = (socket: ServerWebSocket<InlineProtocolWebSocketData>, record: Uint8Array): void => {
    const carrier = socket.data.state?.carrier
    if (!carrier || socket.data.closed) throw new RangeError("Inline Protocol carrier is unavailable")
    const frame = carrier.outbound.process(encodeAbridgedPacket(record))
    socket.sendBinary(frame, false)
  }

  const sendQuickAck = (socket: ServerWebSocket<InlineProtocolWebSocketData>, quickAckId: number): void => {
    const carrier = socket.data.state?.carrier
    if (!carrier || socket.data.closed) throw new RangeError("Inline Protocol carrier is unavailable")
    socket.sendBinary(carrier.outbound.process(encodeAbridgedQuickAck(quickAckId)), false)
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
            sendRecord(socket, state.session.sendApplicationUpdate(payload))
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
      application: makeInlineProtocolApplicationDispatcher({
        operations: runtime.operations,
        connectionId: socket.data.id,
        metadata: socket.data.metadata,
        onAuthorized: (authorization) => {
          if (authorization.userId !== undefined && authorization.accountSessionId !== undefined) {
            registerAuthenticatedConnection(socket, authorization.userId, authorization.accountSessionId)
          }
        },
      }),
      randomBytes: (length) => Uint8Array.from(randomBytes(length)),
      nowMilliseconds: Date.now,
      gunzip: (packed, maximumOutputBytes) => Uint8Array.from(gunzipSync(packed, {
        maxOutputLength: maximumOutputBytes,
      })),
      carrierProfile: "websocket",
      dc: 1,
    })
    const state: InlineProtocolConnectionState = {
      queue: Promise.resolve(),
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
    const frame = bytesForFrame(message)
    enqueue(socket, async () => {
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
      const responses = await state.session.receive(decoded.payload, decoded.quickAckRequested
        ? { onQuickAck: (quickAckId) => sendQuickAck(socket, quickAckId) }
        : undefined)
      for (const response of responses) sendRecord(socket, response)
      if (state.session.destroyed && !socket.data.closed) socket.close(1000, "Protocol session closed")
    })
  }

  const close = (socket: ServerWebSocket<InlineProtocolWebSocketData>): void => {
    socket.data.closed = true
    sockets.delete(socket)
    if (socket.data.state?.registered) connectionManager.removeConnection(socket.data.id)
  }

  return {
    tryUpgrade: (request, server) => {
      if (!accepting || new URL(request.url).pathname !== REALTIME_V3_PATH) return false
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
      return undefined
    },
    handleHttpUpload: (request, directClientIp) => runtime.operations.uploads.handleHttp(
      request,
      trustedClientIp(request, directClientIp, clientIpHeader),
    ),
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
      for (const socket of active) socket.close(1001, "Server shutting down")
      await Promise.allSettled(active.map((socket) => socket.data.state?.queue))
      sockets.clear()
      runtime.close()
    },
  }
}
