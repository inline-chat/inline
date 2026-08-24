import { describe, expect, it } from "bun:test"
import { resolveServerConfigValue } from "./index"

describe("server configuration precedence", () => {
  it("uses server, environment, database, legacy, then default order", () => {
    expect(resolveServerConfigValue("email.default_provider", {
      serverOverride: "ses",
      environmentOverride: "resend",
      databaseValue: "ses",
      legacyEnvironmentValue: "resend",
    })).toEqual({ value: "ses", source: "server_override" })

    expect(resolveServerConfigValue("email.default_provider", {
      environmentOverride: "ses",
      databaseValue: "resend",
      legacyEnvironmentValue: "resend",
    })).toEqual({ value: "ses", source: "environment" })

    expect(resolveServerConfigValue("email.default_provider", {
      databaseValue: "ses",
      legacyEnvironmentValue: "resend",
    })).toEqual({ value: "ses", source: "database" })

    expect(resolveServerConfigValue("email.default_provider", {
      legacyEnvironmentValue: "ses",
    })).toEqual({ value: "ses", source: "legacy_environment" })

    expect(resolveServerConfigValue("email.default_provider", {})).toEqual({
      value: "resend",
      source: "default",
    })
  })

  it("ignores malformed higher-precedence values", () => {
    expect(resolveServerConfigValue("auth.signup_mode", {
      serverOverride: "maybe",
      environmentOverride: 42,
      databaseValue: "disabled",
      legacyEnvironmentValue: "open",
    })).toEqual({ value: "disabled", source: "database" })
  })

  it("keeps Agents parked unless an explicit rollout layer enables them", () => {
    expect(resolveServerConfigValue("agents.rollout", {})).toEqual({
      value: "disabled",
      source: "default",
    })
    expect(resolveServerConfigValue("agents.rollout", {
      environmentOverride: "enabled",
    })).toEqual({
      value: "enabled",
      source: "environment",
    })
  })

  it("keeps Sync V3 producers on legacy events until explicitly switched", () => {
    expect(resolveServerConfigValue("sync.v3_update_producers", {})).toEqual({
      value: "legacy",
      source: "default",
    })
    expect(resolveServerConfigValue("sync.v3_update_producers", {
      databaseValue: "canonical_v3",
    })).toEqual({
      value: "canonical_v3",
      source: "database",
    })
    expect(resolveServerConfigValue("sync.v3_update_producers", {
      databaseValue: "legacy",
    })).toEqual({
      value: "legacy",
      source: "database",
    })
  })
})
