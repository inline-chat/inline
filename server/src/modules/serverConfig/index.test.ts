import { describe, expect, it } from "bun:test"
import { isInviteCodesRequired } from "@in/server/env"
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

    expect(resolveServerConfigValue("auth.signup_mode", {})).toEqual({
      value: "open",
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

    expect(resolveServerConfigValue("auth.signup_mode", {
      serverOverride: "maybe",
      environmentOverride: "closed",
      legacyEnvironmentValue: "typo",
    })).toEqual({ value: "open", source: "default" })
  })

  it("keeps the deprecated legacy helper opt-in instead of restrictive by default", () => {
    const priorLegacyMode = process.env["INVITE_CODES_REQUIRED"]
    try {
      delete process.env["INVITE_CODES_REQUIRED"]
      expect(isInviteCodesRequired()).toBe(false)

      process.env["INVITE_CODES_REQUIRED"] = "typo"
      expect(isInviteCodesRequired()).toBe(false)

      process.env["INVITE_CODES_REQUIRED"] = "true"
      expect(isInviteCodesRequired()).toBe(true)

      process.env["INVITE_CODES_REQUIRED"] = "1"
      expect(isInviteCodesRequired()).toBe(true)
    } finally {
      if (priorLegacyMode === undefined) delete process.env["INVITE_CODES_REQUIRED"]
      else process.env["INVITE_CODES_REQUIRED"] = priorLegacyMode
    }
  })
})
