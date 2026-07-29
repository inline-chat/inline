import { describe, expect, test } from "bun:test"
import {
  closeGridConnection,
  createGridConnectionCredentials,
  durableLiveKitProviderTarget,
  GRID_PROVIDER_HTTP_POLICY,
  liveKitProviderCapabilities,
  liveKitRequiresGenerationRotation,
  liveKitProviderTarget,
  resolveLiveKitGridConfig,
  revokeGridParticipantAccess,
} from "@in/server/modules/grid/livekit"
import { TokenVerifier } from "livekit-server-sdk"

describe("Grid LiveKit credentials", () => {
  test("bounds provider calls inside the durable outbox deadline", () => {
    expect(GRID_PROVIDER_HTTP_POLICY).toEqual({
      requestTimeoutSeconds: 6,
      workerTimeoutSeconds: 25,
    })
  })

  test("enables Cloud-only capabilities only for LiveKit Cloud project hosts", () => {
    expect(liveKitProviderCapabilities({ serverUrl: "wss://project.livekit.cloud" })).toEqual({
      persistentTokenRevocation: true,
      regionFailover: true,
    })
    expect(liveKitProviderCapabilities({ serverUrl: "wss://livekit.inline.chat" })).toEqual({
      persistentTokenRevocation: false,
      regionFailover: false,
    })
    expect(liveKitProviderTarget({ serverUrl: "wss://LiveKit.Inline.Chat/path" })).toBe(
      "https://livekit.inline.chat",
    )
    expect(durableLiveKitProviderTarget({ serverUrl: "wss://livekit.inline.chat" })).toBe(
      "https://livekit.inline.chat",
    )
    expect(durableLiveKitProviderTarget(null)).toBe("unconfigured")
    expect(liveKitRequiresGenerationRotation({ serverUrl: "wss://project.livekit.cloud" })).toBe(false)
    expect(liveKitRequiresGenerationRotation({ serverUrl: "wss://livekit.inline.chat" })).toBe(true)
    expect(liveKitRequiresGenerationRotation(null)).toBe(true)
  })

  test("defaults to self-hosted and selects either complete provider triplet explicitly", () => {
    const environment = {
      legacy: { serverUrl: "wss://legacy.example", apiKey: "legacy-key", apiSecret: "legacy-secret" },
      cloud: { serverUrl: "wss://project.livekit.cloud", apiKey: "cloud-key", apiSecret: "cloud-secret" },
      selfHosted: { serverUrl: "wss://livekit.inline.chat", apiKey: "self-key", apiSecret: "self-secret" },
    }

    expect(resolveLiveKitGridConfig(environment)).toEqual({
      ...environment.selfHosted,
      provider: "self_hosted",
    })
    expect(resolveLiveKitGridConfig({ ...environment, provider: " cloud " })).toEqual({
      ...environment.cloud,
      provider: "cloud",
    })
    expect(resolveLiveKitGridConfig({ ...environment, provider: "self_hosted" })).toEqual({
      ...environment.selfHosted,
      provider: "self_hosted",
    })
  })

  test("falls back to legacy variables when the selected triplet is incomplete", () => {
    expect(
      resolveLiveKitGridConfig({
        provider: "cloud",
        legacy: { serverUrl: "wss://legacy.example", apiKey: "legacy-key", apiSecret: "legacy-secret" },
        cloud: { serverUrl: "wss://project.livekit.cloud", apiKey: "cloud-key" },
      }),
    ).toEqual({ serverUrl: "wss://legacy.example", apiKey: "legacy-key", apiSecret: "legacy-secret" })
    expect(
      resolveLiveKitGridConfig({
        legacy: { serverUrl: "wss://project.livekit.cloud", apiKey: "legacy-key", apiSecret: "legacy-secret" },
      }),
    ).toEqual({
      serverUrl: "wss://project.livekit.cloud",
      apiKey: "legacy-key",
      apiSecret: "legacy-secret",
    })
  })

  test("fails closed for an invalid provider or when both selected and legacy triplets are incomplete", () => {
    expect(
      resolveLiveKitGridConfig({
        provider: "automatic",
        legacy: { serverUrl: "wss://legacy.example", apiKey: "legacy-key", apiSecret: "legacy-secret" },
      }),
    ).toBeUndefined()
    expect(
      resolveLiveKitGridConfig({
        provider: "self_hosted",
        selfHosted: { serverUrl: "wss://livekit.inline.chat" },
        legacy: { serverUrl: "wss://legacy.example", apiKey: "legacy-key" },
      }),
    ).toBeUndefined()
  })

  test("uses an explicit provider identity instead of inferring capabilities from its URL", () => {
    expect(liveKitProviderCapabilities({ serverUrl: "wss://custom.example", provider: "cloud" })).toEqual({
      persistentTokenRevocation: true,
      regionFailover: true,
    })
    expect(
      liveKitProviderCapabilities({ serverUrl: "wss://project.livekit.cloud", provider: "self_hosted" }),
    ).toEqual({
      persistentTokenRevocation: false,
      regionFailover: false,
    })
  })

  test("issues a short-lived unrestricted-media token scoped to one connection generation", async () => {
    const config = {
      serverUrl: "wss://grid.example.test",
      apiKey: "test-key",
      apiSecret: "test-secret-that-is-long-enough-for-hmac",
    }
    const credentials = await createGridConnectionCredentials(
      {
        connection: { roomId: 42n, generation: 3, startedAt: 100n },
        userId: 7,
        displayName: "Mo",
      },
      config,
    )

    expect(credentials?.serverUrl).toBe(config.serverUrl)
    expect(credentials?.participantIdentity).toBe("inline-grid-user-7")
    const ttl = Number(credentials!.expiresAt) - Math.floor(Date.now() / 1000)
    expect(ttl).toBeGreaterThanOrEqual(295)
    expect(ttl).toBeLessThanOrEqual(300)

    const claims = await new TokenVerifier(config.apiKey, config.apiSecret).verify(credentials!.token)
    expect(claims.sub).toBe("inline-grid-user-7")
    expect(claims.name).toBe("Mo")
    expect(claims.video).toMatchObject({
      roomJoin: true,
      room: "inline-grid-42-3",
      canPublish: true,
      canSubscribe: true,
      canPublishData: false,
      canUpdateOwnMetadata: false,
    })
    expect(claims.video?.canPublishSources).toBeUndefined()
  })

  test("keeps a stale token scoped away from a rotated connection generation", async () => {
    const config = {
      serverUrl: "wss://livekit.inline.chat",
      apiKey: "test-key",
      apiSecret: "test-secret-that-is-long-enough-for-hmac",
    }
    const oldCredentials = await createGridConnectionCredentials(
      {
        connection: { roomId: 42n, generation: 3, startedAt: 100n },
        userId: 7,
        participantIdentity: "inline-grid-user-7-old-membership",
      },
      config,
    )
    const currentCredentials = await createGridConnectionCredentials(
      {
        connection: { roomId: 42n, generation: 4, startedAt: 200n },
        userId: 8,
        participantIdentity: "inline-grid-user-8-current-membership",
      },
      config,
    )

    const verifier = new TokenVerifier(config.apiKey, config.apiSecret)
    const oldClaims = await verifier.verify(oldCredentials!.token)
    const currentClaims = await verifier.verify(currentCredentials!.token)
    expect(oldClaims.video?.room).toBe("inline-grid-42-3")
    expect(currentClaims.video?.room).toBe("inline-grid-42-4")
    expect(oldClaims.video?.room).not.toBe(currentClaims.video?.room)
  })

  test("returns unavailable when the provider is not configured", async () => {
    await expect(
      createGridConnectionCredentials(
        { connection: { roomId: 1n, generation: 1, startedAt: 1n }, userId: 1 },
        null,
      ),
    ).resolves.toBeUndefined()
  })

  test("closes the exact provider room generation and exposes failures to its caller", async () => {
    const closed: string[] = []
    const config = {
      serverUrl: "wss://grid.example.test",
      apiKey: "test-key",
      apiSecret: "test-secret-that-is-long-enough-for-hmac",
    }
    await closeGridConnection({ roomId: 89n, generation: 5 }, config, {
      deleteRoom: async (roomName) => void closed.push(roomName),
    })
    expect(closed).toEqual(["inline-grid-89-5"])

    await expect(
      closeGridConnection({ roomId: 89n, generation: 5 }, config, {
        deleteRoom: async () => {
          throw new Error("provider unavailable")
        },
      }),
    ).rejects.toThrow("provider unavailable")
  })

  test("disconnects a Cloud participant and revokes tokens minted through the current second", async () => {
    const calls: Array<{ room: string; identity: string; revokeTokenTs?: bigint }> = []
    await revokeGridParticipantAccess(
      { roomId: 90n, generation: 6 },
      7,
      {
        serverUrl: "wss://project.livekit.cloud",
        apiKey: "test-key",
        apiSecret: "test-secret-that-is-long-enough-for-hmac",
      },
      {
        now: () => 1_750_000_000_400,
        participantIdentity: "inline-grid-user-7-1234",
        removeParticipant: async (room, identity, requestOptions) => {
          calls.push({ room, identity, revokeTokenTs: requestOptions?.revokeTokenTs })
        },
      },
    )

    expect(calls).toEqual([
      {
        room: "inline-grid-90-6",
        identity: "inline-grid-user-7-1234",
        revokeTokenTs: 1_750_000_001n,
      },
    ])
  })

  test("does not claim persistent token revocation from self-hosted LiveKit", async () => {
    const calls: Array<{ room: string; identity: string; options?: { revokeTokenTs?: bigint } }> = []
    await revokeGridParticipantAccess(
      { roomId: 90n, generation: 6 },
      7,
      {
        serverUrl: "wss://livekit.inline.chat",
        apiKey: "test-key",
        apiSecret: "test-secret-that-is-long-enough-for-hmac",
      },
      {
        participantIdentity: "inline-grid-user-7-1234",
        removeParticipant: async (room, identity, options) => {
          calls.push({ room, identity, options })
        },
      },
    )

    expect(calls).toEqual([
      {
        room: "inline-grid-90-6",
        identity: "inline-grid-user-7-1234",
        options: undefined,
      },
    ])
  })
})
