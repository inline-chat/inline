import { describe, expect, it } from "bun:test"
import { oauthConfig } from "./config"
import { handleProviderStart } from "./httpHandlers"
import { InMemoryRateLimiter } from "./rateLimiter"

describe("provider auth entry guards", () => {
  it("rejects oversized client metadata before creating an attempt", async () => {
    const url = new URL("http://inline.test/v1/auth/provider/start")
    url.searchParams.set("provider", "google")
    url.searchParams.set("purpose", "app")
    url.searchParams.set("device_name", "x".repeat(257))

    const response = await handleProviderStart(
      new Request(url),
      "203.0.113.10",
      new InMemoryRateLimiter(),
    )

    expect(response.status).toBe(400)
    expect(await response.text()).toContain("Invalid sign-in request")
  })

  it("rate limits provider starts per client IP", async () => {
    const limiter = new InMemoryRateLimiter()
    const rule = oauthConfig().endpointRateLimits.providerStart
    const request = () => new Request(
      "http://inline.test/v1/auth/provider/start?provider=invalid&purpose=app",
    )

    for (let index = 0; index < rule.max; index += 1) {
      expect(
        (await handleProviderStart(request(), "203.0.113.11", limiter)).status,
      ).toBe(400)
    }

    const limited = await handleProviderStart(
      request(),
      "203.0.113.11",
      limiter,
    )
    expect(limited.status).toBe(429)
    expect(Number(limited.headers.get("retry-after"))).toBeGreaterThan(0)
  })
})
