import type { GridConnection, GridConnectionCredentials } from "@inline-chat/protocol/core"
import {
  LIVEKIT_API_KEY,
  LIVEKIT_API_SECRET,
  LIVEKIT_CLOUD_API_KEY,
  LIVEKIT_CLOUD_API_SECRET,
  LIVEKIT_CLOUD_URL,
  LIVEKIT_PROVIDER,
  LIVEKIT_SELF_HOSTED_API_KEY,
  LIVEKIT_SELF_HOSTED_API_SECRET,
  LIVEKIT_SELF_HOSTED_URL,
  LIVEKIT_URL,
} from "@in/server/env"
import { Log } from "@in/server/utils/log"
import { AccessToken, RoomServiceClient } from "livekit-server-sdk"

const TOKEN_TTL_SECONDS = 5 * 60
const log = new Log("grid.livekit")

export const UNCONFIGURED_LIVEKIT_PROVIDER_TARGET = "unconfigured"

export const GRID_PROVIDER_HTTP_POLICY = {
  requestTimeoutSeconds: 6,
  workerTimeoutSeconds: 25,
} as const

export type GridConnectionIdentity = Pick<GridConnection, "roomId" | "generation">

export type LiveKitGridConfig = {
  serverUrl: string
  apiKey: string
  apiSecret: string
  provider?: LiveKitProvider
}

export type LiveKitProvider = "cloud" | "self_hosted"

export type LiveKitGridEnvironment = {
  provider?: string
  legacy?: Partial<LiveKitGridConfig>
  cloud?: Partial<LiveKitGridConfig>
  selfHosted?: Partial<LiveKitGridConfig>
}

export type LiveKitProviderCapabilities = {
  persistentTokenRevocation: boolean
  regionFailover: boolean
}

const LIVEKIT_CLOUD_CAPABILITIES: LiveKitProviderCapabilities = {
  persistentTokenRevocation: true,
  regionFailover: true,
}

const SELF_HOSTED_LIVEKIT_CAPABILITIES: LiveKitProviderCapabilities = {
  persistentTokenRevocation: false,
  regionFailover: false,
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
  return resolveLiveKitGridConfig({
    provider: LIVEKIT_PROVIDER,
    legacy: { serverUrl: LIVEKIT_URL, apiKey: LIVEKIT_API_KEY, apiSecret: LIVEKIT_API_SECRET },
    cloud: {
      serverUrl: LIVEKIT_CLOUD_URL,
      apiKey: LIVEKIT_CLOUD_API_KEY,
      apiSecret: LIVEKIT_CLOUD_API_SECRET,
    },
    selfHosted: {
      serverUrl: LIVEKIT_SELF_HOSTED_URL,
      apiKey: LIVEKIT_SELF_HOSTED_API_KEY,
      apiSecret: LIVEKIT_SELF_HOSTED_API_SECRET,
    },
  })
}

export function resolveLiveKitGridConfig(environment: LiveKitGridEnvironment): LiveKitGridConfig | undefined {
  const provider = environment.provider?.trim().toLowerCase() || "self_hosted"
  if (provider === "cloud") {
    return completeLiveKitConfig(environment.cloud, "cloud")
      ?? completeLiveKitConfig(environment.legacy)
  }
  if (provider === "self_hosted") {
    return completeLiveKitConfig(environment.selfHosted, "self_hosted")
      ?? completeLiveKitConfig(environment.legacy)
  }
  return undefined
}

/** Explicit dual-provider selection wins; legacy configuration falls back to host inference. */
export function liveKitProviderCapabilities(
  config: Pick<LiveKitGridConfig, "serverUrl" | "provider">,
): LiveKitProviderCapabilities {
  if ("provider" in config && config.provider) {
    return config.provider === "cloud" ? LIVEKIT_CLOUD_CAPABILITIES : SELF_HOSTED_LIVEKIT_CAPABILITIES
  }
  return liveKitServerHostname(config.serverUrl).endsWith(".livekit.cloud")
    ? LIVEKIT_CLOUD_CAPABILITIES
    : SELF_HOSTED_LIVEKIT_CAPABILITIES
}

/**
 * A room-generation boundary replaces persistent token revocation when the
 * provider cannot invalidate an already issued participant token. Missing
 * configuration stays fail-safe because no provider revocation can be proven.
 */
export function liveKitRequiresGenerationRotation(
  config: Pick<LiveKitGridConfig, "serverUrl" | "provider"> | null | undefined = getLiveKitGridConfig(),
): boolean {
  return !config || !liveKitProviderCapabilities(config).persistentTokenRevocation
}

/** Non-secret stable identity used to keep durable effects on their originating provider. */
export function liveKitProviderTarget(
  config: Pick<LiveKitGridConfig, "serverUrl"> | null | undefined = getLiveKitGridConfig(),
): string | undefined {
  if (!config) return undefined
  return new URL(httpServiceURL(config.serverUrl)).origin.toLowerCase()
}

/**
 * Durable effects must never fall back to the provider configured at execution
 * time. The sentinel keeps new effects fail-closed when ownership cannot be
 * established; only rows predating the provider-target migration stay null.
 */
export function durableLiveKitProviderTarget(
  config: Pick<LiveKitGridConfig, "serverUrl"> | null | undefined = getLiveKitGridConfig(),
): string {
  return liveKitProviderTarget(config) ?? UNCONFIGURED_LIVEKIT_PROVIDER_TARGET
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
 * Disconnects one removed member. LiveKit Cloud also invalidates previously
 * minted tokens for this participant identity. Self-hosted LiveKit ignores the
 * revocation field, so the authoritative Grid lifecycle rotates the room
 * generation when access is revoked.
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
      options?: { revokeTokenTs?: bigint },
    ) => Promise<void>
  } = {},
): Promise<void> {
  if (!config) return

  const roomName = providerRoomName(connection)
  const participantIdentity = options.participantIdentity ?? legacyGridParticipantIdentity(userId)
  const capabilities = liveKitProviderCapabilities(config)
  const removalOptions = capabilities.persistentTokenRevocation
    ? {
        // Token nbf values use whole seconds. Advancing one second ensures a
        // token minted during the current second is also invalidated.
        revokeTokenTs: BigInt(Math.floor((options.now?.() ?? Date.now()) / 1_000) + 1),
      }
    : undefined
  const removeParticipant = options.removeParticipant ?? (async (room, identity, requestOptions) => {
    const service = roomServiceClient(config)
    await service.removeParticipant(room, identity, requestOptions)
  })

  const startedAt = Date.now()
  await removeParticipant(roomName, participantIdentity, removalOptions)
  log.info("GRID_TRACE phase=participant_disconnected", {
    roomId: connection.roomId.toString(),
    generation: connection.generation,
    userId,
    persistentTokenRevocation: capabilities.persistentTokenRevocation,
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
  const capabilities = liveKitProviderCapabilities(config)
  return new RoomServiceClient(httpServiceURL(config.serverUrl), config.apiKey, config.apiSecret, {
    requestTimeout: GRID_PROVIDER_HTTP_POLICY.requestTimeoutSeconds,
    failover: capabilities.regionFailover,
  })
}

function liveKitServerHostname(url: string): string {
  return new URL(httpServiceURL(url)).hostname.toLowerCase()
}

function completeLiveKitConfig(
  config: Partial<LiveKitGridConfig> | null | undefined,
  provider?: LiveKitProvider,
): LiveKitGridConfig | undefined {
  const serverUrl = config?.serverUrl?.trim()
  const apiKey = config?.apiKey?.trim()
  const apiSecret = config?.apiSecret?.trim()
  if (!serverUrl || !apiKey || !apiSecret) return undefined
  return provider
    ? { serverUrl, apiKey, apiSecret, provider }
    : { serverUrl, apiKey, apiSecret }
}

function httpServiceURL(url: string): string {
  if (url.startsWith("wss://")) return `https://${url.slice("wss://".length)}`
  if (url.startsWith("ws://")) return `http://${url.slice("ws://".length)}`
  return url
}
