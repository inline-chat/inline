import type { GridConnection, GridConnectionCredentials } from "@inline-chat/protocol/core"
import { LIVEKIT_API_KEY, LIVEKIT_API_SECRET, LIVEKIT_URL } from "@in/server/env"
import { Log } from "@in/server/utils/log"
import { AccessToken, RoomServiceClient, TrackSource } from "livekit-server-sdk"

const TOKEN_TTL_SECONDS = 5 * 60
const log = new Log("grid.livekit")

/**
 * Provider cleanup retries belong to the durable Grid outbox, not to an
 * opaque SDK failover loop. Each control-plane request therefore has one
 * transport-level AbortSignal deadline. The worker keeps a slightly wider
 * logical deadline as a final guard around injected or buggy executors.
 */
export const GRID_PROVIDER_HTTP_POLICY = {
  requestTimeoutSeconds: 10,
  failover: false,
} as const

export type GridConnectionIdentity = Pick<GridConnection, "roomId" | "generation">

export type LiveKitGridConfig = {
  serverUrl: string
  apiKey: string
  apiSecret: string
}

export async function createGridConnectionCredentials(
  input: {
    connection: GridConnection
    userId: number
    displayName?: string
    participantIdentity?: string
  },
  config: LiveKitGridConfig | null | undefined = getLiveKitGridConfig(),
): Promise<GridConnectionCredentials | undefined> {
  const startedAt = Date.now()
  if (!config) {
    log.debug("GRID_TRACE phase=credentials_config_unavailable", {
      roomId: input.connection.roomId.toString(),
      generation: input.connection.generation,
      userId: input.userId,
    })
    return undefined
  }
  const participantIdentity = input.participantIdentity ?? legacyGridParticipantIdentity(input.userId)
  const token = new AccessToken(config.apiKey, config.apiSecret, {
    identity: participantIdentity,
    name: input.displayName,
    ttl: TOKEN_TTL_SECONDS,
    metadata: JSON.stringify({
      inlineUserId: input.userId,
      gridRoomId: input.connection.roomId.toString(),
      generation: input.connection.generation,
    }),
  })
  token.addGrant({
    roomJoin: true,
    room: providerRoomName(input.connection),
    canPublish: true,
    canPublishSources: [TrackSource.MICROPHONE],
    canSubscribe: true,
    canPublishData: false,
    canUpdateOwnMetadata: false,
  })

  const jwt = await token.toJwt()
  log.debug("GRID_TRACE phase=credentials_minted", {
    roomId: input.connection.roomId.toString(),
    generation: input.connection.generation,
    userId: input.userId,
    elapsedMs: Date.now() - startedAt,
  })
  return {
    connection: input.connection,
    serverUrl: config.serverUrl,
    participantIdentity,
    token: jwt,
    expiresAt: BigInt(Math.floor(Date.now() / 1000) + TOKEN_TTL_SECONDS),
  }
}

export function getLiveKitGridConfig(): LiveKitGridConfig | undefined {
  const serverUrl = LIVEKIT_URL?.trim()
  const apiKey = LIVEKIT_API_KEY?.trim()
  const apiSecret = LIVEKIT_API_SECRET?.trim()
  if (!serverUrl || !apiKey || !apiSecret) return undefined
  return { serverUrl, apiKey, apiSecret }
}

export async function closeGridConnections(
  connections: GridConnectionIdentity[],
  config: LiveKitGridConfig | null | undefined = getLiveKitGridConfig(),
): Promise<void> {
  if (!config || connections.length === 0) return
  await Promise.all(
    connections.map(async (connection) => {
      try {
        await closeGridConnection(connection, config)
      } catch (error) {
        Log.shared.warn("Failed to close Grid LiveKit room", {
          roomId: connection.roomId.toString(),
          generation: connection.generation,
          error,
        })
      }
    }),
  )
}

/** Throws on provider failure so the durable effect worker can retry it. */
export async function closeGridConnection(
  connection: GridConnectionIdentity,
  config: LiveKitGridConfig | null | undefined = getLiveKitGridConfig(),
  options: {
    deleteRoom?: (roomName: string) => Promise<void>
  } = {},
): Promise<void> {
  if (!config) return
  const deleteRoom = options.deleteRoom ?? (async (roomName: string) => {
    const service = roomServiceClient(config)
    await service.deleteRoom(roomName)
  })
  await deleteRoom(providerRoomName(connection))
}

/**
 * Disconnects one removed member and invalidates every token minted for this
 * participant identity before the revocation timestamp. Inline membership is
 * still authoritative; this closes the provider-side window immediately.
 */
export async function revokeGridParticipantAccess(
  connection: GridConnectionIdentity,
  userId: number,
  config: LiveKitGridConfig | null | undefined = getLiveKitGridConfig(),
  options: {
    now?: () => number
    participantIdentity?: string
    removeParticipant?: (
      roomName: string,
      participantIdentity: string,
      revokeTokenTs: bigint,
    ) => Promise<void>
  } = {},
): Promise<void> {
  if (!config) return

  const roomName = providerRoomName(connection)
  const participantIdentity = options.participantIdentity ?? legacyGridParticipantIdentity(userId)
  // Token nbf values use whole seconds. Advancing one second ensures a token
  // minted during the current second is also invalidated.
  const revokeTokenTs = BigInt(Math.floor((options.now?.() ?? Date.now()) / 1_000) + 1)
  const removeParticipant = options.removeParticipant ?? (async (room, identity, timestamp) => {
    const service = roomServiceClient(config)
    await service.removeParticipant(room, identity, { revokeTokenTs: timestamp })
  })

  const startedAt = Date.now()
  await removeParticipant(roomName, participantIdentity, revokeTokenTs)
  log.info("GRID_TRACE phase=participant_access_revoked", {
    roomId: connection.roomId.toString(),
    generation: connection.generation,
    userId,
    elapsedMs: Date.now() - startedAt,
  })
}

export function providerRoomName(connection: GridConnectionIdentity): string {
  return `inline-grid-${connection.roomId}-${connection.generation}`
}

/**
 * LiveKit identities are membership-scoped so cleanup from an old leave cannot
 * disconnect a rapid rejoin in the same room generation.
 */
export function gridParticipantIdentity(userId: number, mediaMembershipId: string): string {
  return `${legacyGridParticipantIdentity(userId)}-${mediaMembershipId}`
}

function legacyGridParticipantIdentity(userId: number): string {
  return `inline-grid-user-${userId}`
}

function roomServiceClient(config: LiveKitGridConfig): RoomServiceClient {
  return new RoomServiceClient(httpServiceURL(config.serverUrl), config.apiKey, config.apiSecret, {
    requestTimeout: GRID_PROVIDER_HTTP_POLICY.requestTimeoutSeconds,
    failover: GRID_PROVIDER_HTTP_POLICY.failover,
  })
}

function httpServiceURL(url: string): string {
  if (url.startsWith("wss://")) return `https://${url.slice("wss://".length)}`
  if (url.startsWith("ws://")) return `http://${url.slice("ws://".length)}`
  return url
}
