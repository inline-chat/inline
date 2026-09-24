import { expect, test } from "bun:test"
import { beforeSendEvent, beforeSendSpan } from "./sentryPrivacy"
import type { Event } from "@sentry/bun"

test("scrubs SDK request enrichment and transaction spans without mutating the request", () => {
  const event: Event = {
    event_id: "safe-event-id",
    request: {
      url: "https://host.test/v1/synthetic-token/logout?code=synthetic-code",
      method: "GET", data: "synthetic-body", cookies: { session: "synthetic-cookie" },
      headers: { authorization: "Bearer synthetic-auth", "x-inline-origin-secret": "synthetic-origin-secret" }, query_string: "synthetic-query",
    },
    transaction: "GET /bot42:synthetic-bot/getMe",
    spans: [{ span_id: "1234567890123456", trace_id: "12345678901234567890123456789012", start_timestamp: 1,
      description: "GET /v1/synthetic-span/logout?otp=synthetic-otp", data: { "http.url": "https://test.invalid/?token=synthetic-url", "http.request.header.x-inline-origin-secret": "synthetic-origin-secret" } }],
    breadcrumbs: [{ message: "GET /v1/synthetic-crumb/logout", data: { url: "synthetic-breadcrumb-url" } }],
    exception: { values: [{ value: "failed /bot42:synthetic-exception/getMe" }] },
  }
  const result = beforeSendEvent(event)
  expect(JSON.stringify(result)).not.toContain("synthetic-")
  expect(result.request).toEqual({ method: "GET", url: "/v1/<redacted>/logout" })
  expect(result.event_id).toBe("safe-event-id")
  expect(event.request?.data).toBe("synthetic-body")
  expect(JSON.stringify(beforeSendSpan(event.spans![0]!))).not.toContain("synthetic-")
})
