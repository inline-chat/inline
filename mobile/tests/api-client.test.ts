import { afterEach, expect, mock, test } from "bun:test"

mock.module("../src/config/app", () => ({
  appConfig: { apiBaseUrl: "https://inline.test", apiWsUrl: "wss://inline.test/realtime", version: "0.1.0" },
}))
mock.module("../src/observability/logger", () => ({
  createLogger: () => ({ debug() {}, info() {}, warn() {}, error() {} }),
}))
const { postJson, ApiError } = await import("../src/api/client")
const originalFetch = globalThis.fetch
afterEach(() => { globalThis.fetch = originalFetch })

test("unwraps the server login envelope so challenge and credentials reach callers", async () => {
  const result = { challengeToken: "test-challenge", needsInviteCode: true }
  globalThis.fetch = mock(async () => Response.json({ ok: true, result })) as typeof fetch
  expect(await postJson("sendEmailCode", { email: "test@example.com" })).toEqual(result)
})

test("preserves the public server error description", async () => {
  globalThis.fetch = mock(async () => Response.json({
    ok: false, error: "EMAIL_CODE_INVALID", errorCode: 400, description: "Request a new confirmation code.",
  }, { status: 400 })) as typeof fetch
  await expect(postJson("verifyEmailCode", {})).rejects.toMatchObject({
    message: "Request a new confirmation code.", code: "EMAIL_CODE_INVALID", status: 400,
  })
})

test("rejects malformed success responses", async () => {
  globalThis.fetch = mock(async () => Response.json({ challengeToken: "unwrapped" })) as typeof fetch
  await expect(postJson("sendEmailCode", {})).rejects.toBeInstanceOf(ApiError)
})

test("logout uses bearer authentication and accepts an empty successful result", async () => {
  const fetchMock = mock(async (_url: string | URL | Request, options?: RequestInit) => {
    expect(new Headers(options?.headers).get("authorization")).toBe("Bearer 42:test-token")
    expect(options?.signal).toBeInstanceOf(AbortSignal)
    return Response.json({ ok: true })
  })
  globalThis.fetch = fetchMock as typeof fetch
  expect(await postJson("logout", {}, { token: "42:test-token", timeoutMs: 2_000 })).toBeUndefined()
})

test("bounds a stalled request", async () => {
  globalThis.fetch = mock(async (_url: string | URL | Request, options?: RequestInit) => {
    return new Promise<Response>((_resolve, reject) => {
      options?.signal?.addEventListener("abort", () => reject(new Error("aborted")), { once: true })
    })
  }) as typeof fetch
  await expect(postJson("logout", {}, { token: "42:test-token", timeoutMs: 10 })).rejects.toThrow("aborted")
})
