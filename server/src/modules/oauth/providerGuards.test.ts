import { describe, expect, it } from "bun:test"
import { oauthConfig } from "./config"
import {
  handleProviderCallback,
  handleProviderContinueInvite,
  handleProviderRedeem,
  handleProviderStart,
  handleProviderVerifyEmailCode,
} from "./httpHandlers"
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

  it("rate limits provider callbacks per client IP", async () => {
    const limiter = new InMemoryRateLimiter()
    const rule = oauthConfig().endpointRateLimits.providerCallback
    const request = () => new Request("http://inline.test/v1/auth/provider/callback/google")

    for (let index = 0; index < rule.max; index += 1) {
      expect((await handleProviderCallback("google", request(), undefined, "203.0.113.12", limiter)).status)
        .toBe(400)
    }

    const limited = await handleProviderCallback("google", request(), undefined, "203.0.113.12", limiter)
    expect(limited.status).toBe(429)
    expect(Number(limited.headers.get("retry-after"))).toBeGreaterThan(0)
  })

  it("rate limits provider continuation and redemption before database work", async () => {
    const limiter = new InMemoryRateLimiter()
    const config = oauthConfig()
    const nowMs = Date.now()
    for (let index = 0; index < config.endpointRateLimits.providerContinueInvite.max; index += 1) {
      limiter.consume({
        key: "oauth:endpoint:provider-invite:203.0.113.13",
        nowMs,
        rule: config.endpointRateLimits.providerContinueInvite,
      })
    }
    for (let index = 0; index < config.endpointRateLimits.providerRedeem.max; index += 1) {
      limiter.consume({
        key: "oauth:endpoint:provider-redeem:203.0.113.13",
        nowMs,
        rule: config.endpointRateLimits.providerRedeem,
      })
    }
    for (let index = 0; index < config.endpointRateLimits.verifyEmailCode.max; index += 1) {
      limiter.consume({
        key: "oauth:endpoint:provider-verify-email:203.0.113.13",
        nowMs,
        rule: config.endpointRateLimits.verifyEmailCode,
      })
    }

    const invite = await handleProviderContinueInvite({}, "203.0.113.13", limiter)
    const redeem = await handleProviderRedeem({}, "203.0.113.13", limiter)
    const verify = await handleProviderVerifyEmailCode({}, "203.0.113.13", limiter)
    expect([invite.status, redeem.status, verify.status]).toEqual([429, 429, 429])
    expect(invite.headers.get("retry-after")).not.toBeNull()
    expect(redeem.headers.get("retry-after")).not.toBeNull()
    expect(verify.headers.get("retry-after")).not.toBeNull()
  })
})
