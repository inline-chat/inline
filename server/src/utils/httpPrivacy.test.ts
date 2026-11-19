import { expect, test } from "bun:test"
import { redactCredentialPath, requiresPrivateResponse } from "./httpPrivacy"

test("preserves ordinary diagnostic paths and excludes public Bot documentation from API policy", () => {
  expect(redactCredentialPath("/v1/getMe")).toBe("/v1/getMe")
  expect(redactCredentialPath("/bot/getMe")).toBe("/bot/getMe")
  expect(redactCredentialPath("/bot-api-reference/json")).toBe("/bot-api-reference/json")
  for (const path of ["/bot42%3Asynthetic/getMe", "/botopaque/getMe", "/v1/opaque/logout"]) {
    expect(redactCredentialPath(path)).toContain("<redacted>")
    expect(requiresPrivateResponse(path)).toBeTrue()
  }
  expect(requiresPrivateResponse("/health")).toBeFalse()
  expect(requiresPrivateResponse("/bot-api-reference/json")).toBeFalse()
  expect(requiresPrivateResponse("/_internal/grid-transcription/claim")).toBeTrue()
})
