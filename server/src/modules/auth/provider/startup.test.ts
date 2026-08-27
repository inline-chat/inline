import { describe, expect, spyOn, test } from "bun:test"
import { Log } from "@in/server/utils/log"
import type { ProviderAuthConfig } from "./config"
import { assertProviderAuthStartupConfiguration } from "./startup"

describe("provider authentication startup guard", () => {
  const configured = (): ProviderAuthConfig => ({
    baseUrl: "https://api.inline.test",
    attemptTtlMs: 60_000,
    google: { clientId: "google-client", clientSecret: "google-secret" },
    apple: {
      clientId: "apple-client",
      nativeClientIds: ["chat.inline.InlineIOS", "chat.inline.InlineIOS.debug"],
      teamId: "apple-team",
      keyId: "apple-key",
      privateKey: new Uint8Array([1, 2, 3]),
    },
  })

  test("allows missing providers outside production", () => {
    expect(() =>
      assertProviderAuthStartupConfiguration({
        isProduction: false,
        loadConfig: () => ({ ...configured(), google: null, apple: null }),
      }),
    ).not.toThrow()
  })

  test("requires both providers in production", () => {
    const fatal = spyOn(Log.shared, "fatal").mockImplementation(() => {})
    try {
      expect(() =>
        assertProviderAuthStartupConfiguration({
          isProduction: true,
          loadConfig: () => ({ ...configured(), apple: null }),
        }),
      ).toThrow("APPLE_AUTH_PRIVATE_KEY")
    } finally {
      fatal.mockRestore()
    }
  })

  test("fatally logs configuration failures and refuses startup", () => {
    const failure = new Error("synthetic provider configuration failure")
    const fatal = spyOn(Log.shared, "fatal").mockImplementation(() => {})
    try {
      expect(() =>
        assertProviderAuthStartupConfiguration({
          isProduction: false,
          loadConfig: () => {
            throw failure
          },
        }),
      ).toThrow(failure)
      expect(fatal).toHaveBeenCalledWith(
        "Apple and Google sign-in configuration is invalid; refusing to start the server.",
        failure,
      )
    } finally {
      fatal.mockRestore()
    }
  })
})
