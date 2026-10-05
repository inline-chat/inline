import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { AuthApi, AuthApiError } from "./api"

const origin = "https://auth.example.test"
const email = "fixture+private@example.test"
const code = "fixture-code-123456"
const challengeToken = "fixture-challenge-secret"
const sessionToken = "fixture-session-secret"
const deviceId = "fixture-existing-device"
const fetchMock = vi.fn<typeof fetch>()

const response = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { "Content-Type": "application/json" },
})

const lastRequest = () => {
  const [input, init] = fetchMock.mock.calls.at(-1)!
  return { url: new URL(String(input)), init: init!, headers: new Headers(init?.headers) }
}

beforeEach(() => {
  fetchMock.mockReset()
  vi.stubGlobal("fetch", fetchMock)
  vi.stubGlobal("navigator", { userAgent: "Inline fixture browser" })
  vi.stubGlobal("localStorage", {
    getItem: vi.fn(() => deviceId),
    setItem: vi.fn(),
  })
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("AuthApi", () => {
  it("posts email and verification secrets in JSON without putting them in the URL", async () => {
    const api = new AuthApi(origin)
    fetchMock.mockResolvedValueOnce(response({ ok: true, result: { challengeToken } }))
    expect(await api.sendCode(email)).toBe(challengeToken)
    const send = lastRequest()
    expect(send.url.href).toBe(`${origin}/v1/sendEmailCode`)
    expect(send.init.method).toBe("POST")
    expect(send.headers.get("Content-Type")).toBe("application/json")
    expect(JSON.parse(String(send.init.body))).toEqual({ email })

    fetchMock.mockResolvedValueOnce(response({ ok: true, result: { userId: "9007199254740993", token: sessionToken } }))
    expect(await api.verify(email, code, challengeToken)).toEqual({ userId: "9007199254740993", token: sessionToken })
    const verify = lastRequest()
    expect(verify.url.href).toBe(`${origin}/v1/verifyEmailCode`)
    expect(verify.init.method).toBe("POST")
    expect(verify.headers.get("Content-Type")).toBe("application/json")
    expect(JSON.parse(String(verify.init.body))).toMatchObject({ email, code, challengeToken, deviceId, clientType: "web" })
    for (const request of [send, verify]) {
      expect(request.url.search).toBe("")
      expect(request.init.cache).toBe("no-store")
      expect(request.init.referrerPolicy).toBe("no-referrer")
    }
  })

  it.each(["9007199254740993", "9223372036854775807"])("retains the exact decimal user ID %s", async (userId) => {
    fetchMock.mockResolvedValueOnce(response({ ok: true, result: { userId, token: sessionToken } }))
    expect(await new AuthApi(origin).verify(email, code)).toEqual({ userId, token: sessionToken })
  })

  it.each([9007199254740992, 0, -1, "9223372036854775808", "not-an-id", null])(
    "rejects a session with unsafe or invalid user ID %s", async (userId) => {
      fetchMock.mockResolvedValueOnce(response({ ok: true, result: { userId, token: sessionToken } }))
      await expect(new AuthApi(origin).verify(email, code)).rejects.toThrow("invalid session")
    },
  )

  it.each(["", null, 123])("rejects a session without a usable token: %s", async (token) => {
    fetchMock.mockResolvedValueOnce(response({ ok: true, result: { userId: "1", token } }))
    await expect(new AuthApi(origin).verify(email, code)).rejects.toThrow("invalid session")
  })

  it.each([
    { status: 503, body: { ok: true, result: {} } },
    { status: 200, body: { ok: false, description: "Fixture rejected", result: {} } },
    { status: 200, body: { ok: true } },
    { status: 200, body: { ok: true, result: null } },
  ])("does not report code delivery success for a failed response: $status $body", async ({ status, body }) => {
    fetchMock.mockResolvedValueOnce(response(body, status))
    await expect(new AuthApi(origin).sendCode(email)).rejects.toBeInstanceOf(AuthApiError)
  })

  it("rejects malformed server JSON instead of reporting code delivery success", async () => {
    fetchMock.mockResolvedValueOnce(new Response("not JSON", { status: 200 }))
    await expect(new AuthApi(origin).sendCode(email)).rejects.toBeInstanceOf(AuthApiError)
  })

  it("reports rate limiting without accepting a misleading success body", async () => {
    fetchMock.mockResolvedValueOnce(response({ ok: true, result: { challengeToken } }, 429))
    await expect(new AuthApi(origin).sendCode(email)).rejects.toThrow("Too many attempts")
  })

  it("propagates network failure instead of reporting code delivery success", async () => {
    const failure = new TypeError("Fixture network failure")
    fetchMock.mockRejectedValueOnce(failure)
    await expect(new AuthApi(origin).sendCode(email)).rejects.toBe(failure)
  })

  it("revokes the session using a bearer POST and requires explicit server success", async () => {
    fetchMock.mockResolvedValueOnce(response({ ok: true }))
    await expect(new AuthApi(origin).logout(sessionToken)).resolves.toBeUndefined()
    const logout = lastRequest()
    expect(logout.url.href).toBe(`${origin}/v1/logout`)
    expect(logout.url.search).toBe("")
    expect(logout.init.method).toBe("POST")
    expect(logout.headers.get("Authorization")).toBe(`Bearer ${sessionToken}`)
    expect(logout.init.body).toBeUndefined()
    expect(logout.init.cache).toBe("no-store")
    expect(logout.init.referrerPolicy).toBe("no-referrer")
  })

  it.each([
    { status: 401, body: { ok: true } },
    { status: 200, body: { ok: false } },
    { status: 200, body: {} },
    { status: 200, body: { ok: "true" } },
  ])("does not confirm logout when revocation is unconfirmed: $status $body", async ({ status, body }) => {
    fetchMock.mockResolvedValueOnce(response(body, status))
    await expect(new AuthApi(origin).logout(sessionToken)).rejects.toThrow("Could not revoke")
  })

  it("does not confirm logout after malformed JSON or a network failure", async () => {
    const api = new AuthApi(origin)
    fetchMock.mockResolvedValueOnce(new Response("not JSON", { status: 200 }))
    await expect(api.logout(sessionToken)).rejects.toThrow("Could not revoke")
    const failure = new TypeError("Fixture network failure")
    fetchMock.mockRejectedValueOnce(failure)
    await expect(api.logout(sessionToken)).rejects.toBe(failure)
  })
})
