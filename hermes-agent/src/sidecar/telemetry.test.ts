import http from "node:http"
import { once } from "node:events"
import { describe, expect, it } from "vitest"
import { buildHermesTelemetryEvent, sendHermesPluginError } from "./telemetry.js"

describe("Hermes sidecar error telemetry", () => {
  it("preserves raw errors and paths while excluding credentials and user context", () => {
    const secret = "private-sidecar-token"
    const error = new Error(`connect https://user:password@example.com?token=${secret}`)
    error.stack = [
      `${error.name}: ${error.message}`,
      "    at consumeEvents (/opt/hermes/plugin/inline/sidecar/index.mjs:88:12)",
    ].join("\n")
    const event = buildHermesTelemetryEvent("inbound.loop", error, {
      env: { INLINE_SIDECAR_TOKEN: secret },
    })
    const encoded = JSON.stringify(event)

    expect(event.exception.values[0]?.value).toContain("connect https://[REDACTED]@example.com")
    expect(event.exception.values[0]?.stacktrace?.frames[0]).toMatchObject({
      abs_path: "/opt/hermes/plugin/inline/sidecar/index.mjs",
      lineno: 88,
      colno: 12,
    })
    expect(encoded).not.toContain(secret)
    expect(encoded).not.toContain("password")
    expect(encoded).not.toContain("user\"")
    expect(encoded).not.toContain("breadcrumbs")
  })

  it("sends one bounded Sentry envelope to an explicit test collector", async () => {
    let body = ""
    const server = http.createServer((request, response) => {
      request.setEncoding("utf8")
      request.on("data", (chunk) => { body += chunk })
      request.on("end", () => {
        response.writeHead(200, { "content-type": "application/json" })
        response.end("{}")
      })
    })
    server.listen(0, "127.0.0.1")
    await once(server, "listening")
    const address = server.address()
    if (!address || typeof address === "string") throw new Error("missing test listener")

    try {
      const sent = await sendHermesPluginError("endpoint.request", new Error("raw sidecar failure"), {
        env: {
          NODE_ENV: "test",
          INLINE_HERMES_SENTRY_DSN: `http://fixture@127.0.0.1:${address.port}/123`,
        },
      })
      expect(sent).toBe(true)
      const lines = body.split("\n").map((line) => JSON.parse(line) as Record<string, unknown>)
      expect(lines).toHaveLength(3)
      expect(lines[1]).toMatchObject({ type: "event" })
      expect(lines[2]).toMatchObject({
        platform: "javascript",
        level: "error",
        logger: "inline.hermes.sidecar",
        tags: { operation: "endpoint.request", component: "sidecar" },
      })
    } finally {
      server.close()
      await once(server, "close")
    }
  })

  it("honors the shared telemetry opt-out even with an explicit DSN", async () => {
    await expect(sendHermesPluginError("endpoint.request", new Error("not sent"), {
      env: {
        INLINE_PLUGIN_TELEMETRY: "0",
        INLINE_HERMES_SENTRY_DSN: "http://fixture@127.0.0.1:1/123",
      },
    })).resolves.toBe(false)
  })
})
