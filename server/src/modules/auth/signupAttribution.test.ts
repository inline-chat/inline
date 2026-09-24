import { describe, expect, it } from "bun:test"
import { captureSignupReferral, formatSignupAttribution } from "./signupAttribution"

describe("signup attribution", () => {
  it("retains campaign fields and only the referrer hostname", () => {
    const evidence = captureSignupReferral(
      new URL("https://api.inline.chat/oauth/authorize?utm_source=twitter&utm_medium=social&utm_campaign=launch&state=secret"),
      "https://user:password@t.co/private-path?token=secret#fragment",
    )
    expect(evidence).toEqual({
      referrerHost: "t.co", utmSource: "twitter", utmMedium: "social", utmCampaign: "launch",
    })
    expect(JSON.stringify(evidence)).not.toContain("secret")
    expect(formatSignupAttribution({ clientType: "web", attribution: evidence })).toBe(
      "client: web · ref: t.co · utm: source=twitter, medium=social, campaign=launch",
    )
  })

  it("keeps Google authentication separate from acquisition and the OAuth app", () => {
    expect(formatSignupAttribution({
      clientType: "web",
      attribution: { entryPoint: "oauth", oauthClient: "ChatGPT", authMethod: "google" },
    })).toBe("client: web · via: ChatGPT OAuth · login: google · ref: unknown")
  })

  it("does not guess a referral from a native client or its IP", () => {
    expect(formatSignupAttribution({ clientType: "ios", clientVersion: "0.7.14", ip: "203.0.113.10" }))
      .toBe("client: ios 0.7.14 · ref: unknown · ip: 203.0.113.10")
    expect(formatSignupAttribution({ clientType: "macos" })).toBe("client: macos · ref: unknown")
    expect(formatSignupAttribution()).toBe("client: unknown · ref: unknown")
  })

  it("ignores malformed and non-web referrers", () => {
    for (const referrer of [undefined, "", "not a url", "file:///private/name", "javascript:alert(1)"]) {
      expect(captureSignupReferral(new URL("https://api.inline.chat/oauth/authorize"), referrer).referrerHost)
        .toBeUndefined()
    }
  })

  it("omits optional values that are empty after sanitization", () => {
    expect(formatSignupAttribution({
      ip: "\n ",
      attribution: { utmSource: "[]", utmMedium: "\u202e", utmCampaign: "  " },
    })).toBe("client: unknown · ref: unknown")
  })

  it("bounds campaign text and prevents extra rows or markdown links", () => {
    const url = new URL("https://api.inline.chat/oauth/authorize")
    url.searchParams.set("utm_source", "x\n·ref: spoofed\u202e[click](https://example.com)")
    url.searchParams.set("utm_campaign", "a".repeat(1_000))
    const evidence = captureSignupReferral(url)
    expect(evidence.utmCampaign).toHaveLength(80)
    const row = formatSignupAttribution({ attribution: evidence })
    expect(row).not.toMatch(/[\n\r\u202e]/u)
    expect(row).not.toContain("[")
    expect(row).not.toContain("]")
    expect(row.split(" · ")).toHaveLength(3)
  })
})
