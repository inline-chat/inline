import http from "node:http"
import { once } from "node:events"
import { describe, expect, it } from "vitest"
import {
  buildOpenClawTelemetryEvent,
  instrumentOpenClawChannelPlugin,
  instrumentOpenClawPluginApi,
  sendOpenClawPluginError,
} from "./telemetry.js"

describe("OpenClaw plugin error telemetry", () => {
  it("stays disabled unless an operator configures a collector", async () => {
    await expect(sendOpenClawPluginError("gateway.start", new Error("not sent"), {
      env: { NODE_ENV: "production" },
    })).resolves.toBe(false)
  })

  it("preserves raw errors and paths while excluding credentials and unrelated context", () => {
    const secret = "private-inline-token"
    const error = new Error(
      `connect https://user:password@example.com/rpc?token=${secret} Bearer ${secret}`,
    )
    error.stack = [
      `${error.name}: ${error.message}`,
      "    at sendInline (/Users/mo/private/openclaw/src/inline/monitor.ts:42:7)",
    ].join("\n")

    const event = buildOpenClawTelemetryEvent("gateway.start_account", error, {
      env: { INLINE_TOKEN: secret },
    })
    const encoded = JSON.stringify(event)

    expect(event.exception.values[0]?.value).toContain("connect https://[REDACTED]@example.com/rpc")
    expect(event.exception.values[0]?.stacktrace?.frames[0]).toMatchObject({
      abs_path: "/Users/mo/private/openclaw/src/inline/monitor.ts",
      lineno: 42,
      colno: 7,
    })
    expect(encoded).not.toContain(secret)
    expect(encoded).not.toContain("password")
    expect(encoded).not.toContain("request")
    expect(encoded).not.toContain("breadcrumbs")
    expect(encoded).not.toContain("user\"")
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
      const sent = await sendOpenClawPluginError(
        "outbound.send_text",
        new Error("raw plugin failure"),
        {
          env: {
            NODE_ENV: "test",
            INLINE_OPENCLAW_SENTRY_DSN: `http://fixture@127.0.0.1:${address.port}/123`,
          },
        },
      )
      expect(sent).toBe(true)
      const lines = body.split("\n").map((line) => JSON.parse(line) as Record<string, unknown>)
      expect(lines).toHaveLength(3)
      expect(lines[1]).toMatchObject({ type: "event" })
      expect(lines[2]).toMatchObject({
        platform: "javascript",
        level: "error",
        logger: "inline.openclaw.plugin",
        tags: { operation: "outbound.send_text" },
      })
    } finally {
      server.close()
      await once(server, "close")
    }
  })

  it("honors the shared telemetry opt-out even with an explicit DSN", async () => {
    await expect(sendOpenClawPluginError("gateway.start", new Error("not sent"), {
      env: {
        INLINE_PLUGIN_TELEMETRY: "off",
        INLINE_OPENCLAW_SENTRY_DSN: "http://fixture@127.0.0.1:1/123",
      },
    })).resolves.toBe(false)
  })

  it("reports failures from plugin-owned host callbacks without changing results", async () => {
    const failure = new Error("callback failed")
    const plugin = instrumentOpenClawChannelPlugin({
      gateway: {
        startAccount: async () => { throw failure },
        logoutAccount: () => ({ ok: true }),
      },
    })

    await expect(plugin.gateway.startAccount()).rejects.toBe(failure)
    expect(plugin.gateway.logoutAccount()).toEqual({ ok: true })
  })

  it("reports registered tool, command, and hook failures without swallowing them", async () => {
    const registrations: {
      tool?: (ctx: unknown) => unknown
      command?: Record<string, unknown>
      hook?: (...args: never[]) => unknown
    } = {}
    const api = instrumentOpenClawPluginApi({
      registerTool: (factory: (ctx: unknown) => unknown) => { registrations.tool = factory },
      registerCommand: (command: Record<string, unknown>) => { registrations.command = command },
      on: (_event: string, handler: (...args: never[]) => unknown) => { registrations.hook = handler },
    })
    const failure = new Error("registered callback failed")

    api.registerTool(() => ({
      name: "inline_members",
      execute: async () => { throw failure },
    }))
    api.registerCommand({
      name: "threadreply",
      handler: async () => { throw failure },
    })
    api.on("gateway_start", async () => { throw failure })

    const tool = registrations.tool?.({}) as { execute: () => Promise<unknown> }
    const commandHandler = registrations.command?.handler as (() => Promise<unknown>) | undefined
    const hook = registrations.hook
    await expect(tool.execute()).rejects.toBe(failure)
    await expect(commandHandler!()).rejects.toBe(failure)
    await expect(hook!()).rejects.toBe(failure)
  })
})
