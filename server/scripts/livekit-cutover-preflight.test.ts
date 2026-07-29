import { describe, expect, test } from "bun:test"
import {
  evaluateLiveKitCutoverPreflight,
  inspectLiveKitCutoverEnvironment,
  type LiveKitCutoverDatabaseState,
} from "./livekit-cutover-preflight"

const completeEnvironment = {
  LIVEKIT_PROVIDER: "cloud",
  LIVEKIT_CLOUD_URL: "wss://cloud.example",
  LIVEKIT_CLOUD_API_KEY: "cloud-key",
  LIVEKIT_CLOUD_API_SECRET: "cloud-secret",
  LIVEKIT_SELF_HOSTED_URL: "wss://self.example",
  LIVEKIT_SELF_HOSTED_API_KEY: "self-key",
  LIVEKIT_SELF_HOSTED_API_SECRET: "self-secret",
}

const drainedDatabase: LiveKitCutoverDatabaseState = {
  migrationApplied: true,
  totalEffects: 0,
  legacyUnboundEffects: 0,
  unknownOwnerEffects: 0,
  claimedEffects: 0,
  maximumAttempts: 0,
  activeRooms: 0,
}

describe("LiveKit cutover preflight", () => {
  test("passes only with the explicit expected provider, both triplets, migration, and drained state", () => {
    const environment = inspectLiveKitCutoverEnvironment(completeEnvironment, "cloud")
    expect(evaluateLiveKitCutoverPreflight(environment, drainedDatabase)).toEqual({
      ready: true,
      failures: [],
      environment: {
        expectedProvider: "cloud",
        selectedProvider: "cloud",
        selectorExplicit: true,
        selectorMatchesExpected: true,
        cloudTripletComplete: true,
        selfHostedTripletComplete: true,
        legacyTripletComplete: false,
        legacyFallbackActive: false,
      },
      database: drainedDatabase,
    })
  })

  test("fails when the selector would default to self-hosted or use legacy fallback", () => {
    const environment = inspectLiveKitCutoverEnvironment(
      {
        LIVEKIT_URL: "wss://legacy.example",
        LIVEKIT_API_KEY: "legacy-key",
        LIVEKIT_API_SECRET: "legacy-secret",
      },
      "cloud",
    )
    const result = evaluateLiveKitCutoverPreflight(environment, drainedDatabase)

    expect(result.ready).toBe(false)
    expect(result.failures).toEqual([
      "provider_selector_not_explicit",
      "provider_selector_mismatch",
      "cloud_triplet_incomplete",
      "self_hosted_triplet_incomplete",
      "legacy_fallback_active",
    ])
  })

  test("fails for migration, effect ownership, claims, or active-room blockers", () => {
    const environment = inspectLiveKitCutoverEnvironment(completeEnvironment, "cloud")
    const result = evaluateLiveKitCutoverPreflight(environment, {
      migrationApplied: false,
      totalEffects: null,
      legacyUnboundEffects: null,
      unknownOwnerEffects: null,
      claimedEffects: null,
      maximumAttempts: null,
      activeRooms: 2,
    })

    expect(result.ready).toBe(false)
    expect(result.failures).toEqual([
      "migration_0100_missing",
      "active_grid_rooms_not_drained",
    ])
  })

  test("reports a database failure without retaining environment values", () => {
    const environment = inspectLiveKitCutoverEnvironment(completeEnvironment, "cloud")
    const result = evaluateLiveKitCutoverPreflight(environment, null)
    const output = JSON.stringify(result)

    expect(result.failures).toEqual(["database_probe_failed"])
    expect(output).not.toContain("cloud-key")
    expect(output).not.toContain("cloud-secret")
    expect(output).not.toContain("self-key")
    expect(output).not.toContain("self-secret")
  })
})
