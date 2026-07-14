import { describe, expect, test } from "bun:test"
import {
  closeGridConnection,
  createGridConnectionCredentials,
  GRID_PROVIDER_HTTP_POLICY,
  revokeGridParticipantAccess,
} from "@in/server/modules/grid/livekit"
import { TokenVerifier } from "livekit-server-sdk"

describe("Grid LiveKit credentials", () => {
  test("gives each provider request one transport abort deadline and leaves retries to the outbox", () => {
    expect(GRID_PROVIDER_HTTP_POLICY).toEqual({
      requestTimeoutSeconds: 10,
      failover: false,
    })
  })

  test("issues a short-lived microphone-only token scoped to one connection generation", async () => {
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
      canPublishSources: ["microphone"],
      canSubscribe: true,
      canPublishData: false,
      canUpdateOwnMetadata: false,
    })
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

  test("disconnects a removed member and revokes tokens minted through the current second", async () => {
    const calls: Array<{ room: string; identity: string; revokeTokenTs: bigint }> = []
    await revokeGridParticipantAccess(
      { roomId: 90n, generation: 6 },
      7,
      {
        serverUrl: "wss://grid.example.test",
        apiKey: "test-key",
        apiSecret: "test-secret-that-is-long-enough-for-hmac",
      },
      {
        now: () => 1_750_000_000_400,
        participantIdentity: "inline-grid-user-7-1234",
        removeParticipant: async (room, identity, revokeTokenTs) => {
          calls.push({ room, identity, revokeTokenTs })
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
})
