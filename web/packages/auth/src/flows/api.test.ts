import { describe, expect, it } from "vitest"
import { createSignInApi, mapErrorResponse, type SignInError } from "./api"
import { API_BASE, SECRET_TOKEN, ScriptedFetch, apiError, loginResult, ok } from "./test-support"

const device = { deviceId: "device-1234", deviceName: "Firefox on Linux" }
const noHeaders = { get: () => null }

describe("mapErrorResponse", () => {
  const cases: Array<[number, string | undefined, SignInError]> = [
    [400, "EMAIL_CODE_INVALID", { kind: "invalidCode" }],
    [400, "SMS_CODE_INVALID", { kind: "invalidCode" }],
    [400, "EMAIL_CODE_EMPTY", { kind: "invalidCode" }],
    [400, "INVITE_CODE_REQUIRED", { kind: "inviteRequired" }],
    [400, "INVITE_CODE_INVALID", { kind: "invalidInvite", reason: "format" }],
    [400, "INVITE_CODE_NOT_FOUND", { kind: "invalidInvite", reason: "notFound" }],
    [400, "INVITE_CODE_TAKEN", { kind: "invalidInvite", reason: "taken" }],
    [400, "EMAIL_INVALID", { kind: "invalidEmail" }],
    [400, "PHONE_INVALID", { kind: "invalidPhone" }],
    [400, "SIGNUPS_DISABLED", { kind: "signupsDisabled" }],
    [401, "USER_DEACTIVATED", { kind: "accountDeactivated" }],
    [401, "invalid_ticket", { kind: "invalidTicket" }],
    [420, "FLOOD", { kind: "rateLimited", retryAfterSeconds: null }],
    [429, undefined, { kind: "rateLimited", retryAfterSeconds: null }],
    [400, "INVALID_ARGS", { kind: "server", status: 400, code: "INVALID_ARGS" }],
    [500, "SERVER_ERROR", { kind: "server", status: 500, code: "SERVER_ERROR" }],
    [502, undefined, { kind: "server", status: 502, code: null }],
  ]

  it.each(cases)("maps %i %s", (status, error, expected) => {
    expect(mapErrorResponse(status, error ? { ok: false, error } : undefined, noHeaders)).toEqual(expected)
  })

  it("reads retry-after seconds and ignores anything else", () => {
    const headers = (value: string) => ({ get: (name: string) => (name === "retry-after" ? value : null) })
    expect(mapErrorResponse(420, { error: "FLOOD" }, headers("45"))).toEqual({
      kind: "rateLimited",
      retryAfterSeconds: 45,
    })
    expect(mapErrorResponse(429, {}, headers("Wed, 21 Oct 2026 07:28:00 GMT"))).toEqual({
      kind: "rateLimited",
      retryAfterSeconds: null,
    })
  })

  it("never copies an arbitrary error string into the error", () => {
    expect(mapErrorResponse(500, { error: `leak ${SECRET_TOKEN}` }, noHeaders)).toEqual({
      kind: "server",
      status: 500,
      code: null,
    })
  })
})

describe("createSignInApi", () => {
  const make = (server: ScriptedFetch) =>
    createSignInApi({ fetch: server.fetch, apiBaseUrl: `${API_BASE}/`, device })

  it("omits device fields the app does not know", async () => {
    const server = new ScriptedFetch().on(
      "/sendEmailCode",
      ok({ existingUser: false, needsInviteCode: false }),
    )
    const result = await make(server).sendEmailCode("ada@example.com")
    expect(result).toEqual({
      ok: true,
      value: { existingUser: false, needsInviteCode: false, challengeToken: null },
    })
    expect(server.requests[0]?.body).toEqual({
      email: "ada@example.com",
      deviceId: "device-1234",
      clientType: "web",
      deviceName: "Firefox on Linux",
    })
  })

  it("sends the session token only in the Authorization header on logout", async () => {
    const server = new ScriptedFetch().on("/logout", ok())
    expect(await make(server).logout(SECRET_TOKEN)).toEqual({ ok: true, value: undefined })
    const request = server.requests[0]!
    expect(request.headers["authorization"]).toBe(`Bearer ${SECRET_TOKEN}`)
    expect(request.body).toEqual({})
    expect(request.path).toBe("/logout")
  })

  it("decodes the session and brands the user ID", async () => {
    const server = new ScriptedFetch().on("/verifyEmailCode", ok(loginResult()))
    const result = await make(server).verifyEmailCode({
      email: "ada@example.com",
      code: "123456",
      challengeToken: null,
      inviteCode: null,
    })
    expect(result.ok && result.value.userId).toBe("42")
    expect(result.ok && result.value.user.pendingSetup).toBe(false)
    expect(server.requests[0]?.body).not.toHaveProperty("challengeToken")
    expect(server.requests[0]?.body).not.toHaveProperty("inviteCode")
  })

  it("treats a malformed success as a server error without echoing it", async () => {
    const server = new ScriptedFetch()
      .on("/verifyEmailCode", ok({ userId: 42, token: SECRET_TOKEN, user: { id: 7, date: 0 } }))
      .on("/verifySmsCode", { status: 200, body: "<html>" })
      .on("/checkInviteCode", { status: 200, body: { ok: false, error: "INVITE_CODE_TAKEN" } })
    const api = make(server)
    const mismatched = await api.verifyEmailCode({
      email: "a@b.c",
      code: "123456",
      challengeToken: null,
      inviteCode: null,
    })
    expect(mismatched).toEqual({ ok: false, error: { kind: "server", status: 200, code: null } })
    expect(JSON.stringify(mismatched)).not.toContain(SECRET_TOKEN)
    expect(await api.verifySmsCode({ phoneNumber: "+1", code: "1", inviteCode: null })).toEqual({
      ok: false,
      error: { kind: "server", status: 200, code: null },
    })
    expect(await api.checkInviteCode("A7K2PQ9X")).toEqual({
      ok: false,
      error: { kind: "invalidInvite", reason: "taken" },
    })
  })

  it("maps a provider redeem rate limit from the OAuth module", async () => {
    const server = new ScriptedFetch().on("/auth/provider/redeem", {
      status: 429,
      body: { error: "rate_limited", error_description: "Too many" },
      headers: { "retry-after": "9" },
    })
    expect(await make(server).redeemProviderTicket({ ticket: "t", codeVerifier: "v" })).toEqual({
      ok: false,
      error: { kind: "rateLimited", retryAfterSeconds: 9 },
    })
  })

  it("reports a thrown fetch as a network error", async () => {
    const api = createSignInApi({
      apiBaseUrl: API_BASE,
      device,
      fetch: () => Promise.reject(new TypeError("Failed to fetch")),
    })
    expect(await api.sendSmsCode("+14155550100")).toEqual({ ok: false, error: { kind: "network" } })
  })

  it("keeps the code out of errors", async () => {
    const server = new ScriptedFetch().on("/verifySmsCode", apiError(400, "SMS_CODE_INVALID"))
    const result = await make(server).verifySmsCode({
      phoneNumber: "+14155550100",
      code: "424242",
      inviteCode: null,
    })
    expect(JSON.stringify(result)).not.toContain("424242")
  })
})
