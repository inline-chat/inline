import { describe, expect, it } from "vitest"
import {
  productionContentSecurityPolicy,
  withInlineWebSecurityHeaders,
} from "./InlineWebSecurityHeaders"

describe("Inline web response security", () => {
  it("locks the production document to the app and known Inline transports", () => {
    const response = withInlineWebSecurityHeaders(
      new Response("<html></html>", {
        headers: { "content-type": "text/html; charset=utf-8" },
      }),
      { production: true },
    )

    expect(response.headers.get("Content-Security-Policy")).toBe(
      productionContentSecurityPolicy,
    )
    expect(productionContentSecurityPolicy).toContain("object-src 'none'")
    expect(productionContentSecurityPolicy).toContain("frame-ancestors 'none'")
    expect(productionContentSecurityPolicy).not.toContain("script-src https:")
    expect(response.headers.get("X-Frame-Options")).toBe("DENY")
    expect(response.headers.get("Referrer-Policy")).toBe("no-referrer")
    expect(response.headers.get("Strict-Transport-Security")).toContain(
      "max-age=31536000",
    )
  })

  it("does not put the production CSP or HSTS on the local dev server", () => {
    const response = withInlineWebSecurityHeaders(
      new Response("ok", {
        headers: { "content-type": "text/html" },
      }),
      { production: false },
    )

    expect(response.headers.has("Content-Security-Policy")).toBe(false)
    expect(response.headers.has("Strict-Transport-Security")).toBe(false)
    expect(response.headers.get("X-Content-Type-Options")).toBe("nosniff")
  })

  it("keeps CSP document-scoped while securing static responses", () => {
    const response = withInlineWebSecurityHeaders(
      new Response("asset", {
        headers: { "content-type": "application/javascript" },
      }),
      { production: true },
    )

    expect(response.headers.has("Content-Security-Policy")).toBe(false)
    expect(response.headers.get("Cross-Origin-Opener-Policy")).toBe(
      "same-origin",
    )
  })
})
