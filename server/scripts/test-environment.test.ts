import { describe, expect, mock, test } from "bun:test"
import { createTestEnvironment } from "./test-environment"
import { localOnlyFetch } from "../src/__tests__/network"

describe("test environment", () => {
  test("the runner gives unit files no database credentials even in the full suite", () => {
    expect(process.env["DATABASE_URL"]).toBe("postgres://localhost:1/inline_unit_test")
    expect(process.env["TEST_DATABASE_URL"]).toBe("postgres://localhost:1/inline_unit_test")
  })

  test("does not inherit provider credentials, deployment flags, or a database target", () => {
    const env = createTestEnvironment({
      PATH: "/bin", RESEND_API_KEY: "real-credential", DATABASE_URL: "postgres://remote/production",
      INLINE_ALERTS_BOT_TOKEN: "real-token", ENCRYPTION_KEY: "real-key", INLINE_CONTENT_ENCRYPTION_WRITE: "true",
    })
    expect(env["PATH"]).toBe("/bin")
    expect(env["RESEND_API_KEY"]).toBe("test-key")
    expect(env["DATABASE_URL"]).toBe("postgres://localhost:1/inline_unit_test")
    expect(env["INLINE_ALERTS_BOT_TOKEN"]).toBeUndefined()
    expect(env["INLINE_CONTENT_ENCRYPTION_WRITE"]).toBeUndefined()
    expect(env["ENCRYPTION_KEY"]).not.toBe("real-key")
  })

  test("blocks a provider before dispatch, without disclosing request credentials", async () => {
    const realFetch = mock(async () => new Response("unexpected"))
    const denied = mock()
    const fetch = localOnlyFetch(realFetch as unknown as typeof globalThis.fetch, denied)
    await expect(fetch("https://provider.example/private?token=secret")).rejects.toThrow(
      "External fetch blocked in tests (provider.example); inject a provider fake.",
    )
    expect(realFetch).not.toHaveBeenCalled()
    expect(denied).toHaveBeenCalledWith("provider.example")
  })

  test.each(["localhost", "127.0.0.1", "[::1]"])("allows a local HTTP fixture at %s but never follows redirects", async (host) => {
    const realFetch = mock(async () => new Response("ok"))
    const denied = mock()
    const fetch = localOnlyFetch(realFetch as unknown as typeof globalThis.fetch, denied)
    const url = `http://${host}:1234/test`
    expect(await (await fetch(url, { redirect: "follow" })).text()).toBe("ok")
    expect(realFetch).toHaveBeenCalledWith(url, { redirect: "error" })
    expect(denied).not.toHaveBeenCalled()
  })
})
