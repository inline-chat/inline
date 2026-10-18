import { describe, expect, it } from "bun:test"
import { TransportPreference } from "@inline-chat/protocol/core"
import { upgradedSessionTransportPreference } from "./transportPreference"

const variable = "INLINE_CONFIG_REALTIME_UPGRADED_SESSION_TRANSPORT"

describe("upgraded session transport preference", () => {
  it("answers connection opens synchronously from overrides and defaults", () => {
    const previous = process.env[variable]
    try {
      process.env[variable] = "v2"
      // A pending promise here would mean connection admission waits on configuration storage.
      expect(upgradedSessionTransportPreference()).toBe(TransportPreference.LEGACY)
      process.env[variable] = "v3"
      expect(upgradedSessionTransportPreference()).toBe(TransportPreference.V3)
      delete process.env[variable]
      expect(upgradedSessionTransportPreference()).toBe(TransportPreference.V3)
    } finally {
      if (previous === undefined) delete process.env[variable]
      else process.env[variable] = previous
    }
  })
})
