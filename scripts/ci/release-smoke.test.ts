import { describe, expect, it } from "bun:test"
import { readFileSync } from "node:fs"
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { annotate, checkIntrospection, curl, failed, probeCredentials, readReady, smoke, type Curl, type CurlOptions } from "./release-smoke"

const SHA = "a".repeat(40)

function origin({ revision = SHA, storesMessage = true, upgrades = true, bot: user = { id: 7, is_bot: true }, history = true } = {}) {
  const calls: string[][] = []
  const tokens: Array<string | undefined> = []
  const curl: Curl = async (args, options) => {
    calls.push(args)
    tokens.push(options?.token)
    const url = args.at(-1)!
    if (url.endsWith("/readyz")) return { code: 200, body: JSON.stringify({ ok: true, revision, draining: false }) }
    if (url.endsWith("/bot/getMe")) return { code: 200, body: JSON.stringify({ ok: true, result: { user } }) }
    if (url.endsWith("/bot/sendMessage")) return { code: 200, body: JSON.stringify({ ok: true, result: { message: { message_id: 99 } } }) }
    if (url.includes("/bot/getChatHistory")) {
      const send = calls.find((call) => call.at(-1)!.endsWith("/bot/sendMessage"))
      const sent = send ? JSON.parse(send.at(-2)!).text : undefined
      return { code: 200, body: JSON.stringify({ ok: true, result: history ? { messages: storesMessage && sent ? [{ message_id: 99, text: sent }] : [] } : {} }) }
    }
    if (url.includes("/realtime")) return { code: upgrades ? 101 : 502, body: "" }
    throw new Error(`unexpected ${url}`)
  }
  return { curl, calls, tokens }
}

const grant = {
  active: true, grant_id: "g1", client_id: "c1", scope: "messages:read", aud: "https://mcp.inline.chat/mcp", exp: 4_000_000_000,
  inline_user_id: "42", space_ids: ["7"], allow_dms: true, allow_home_threads: false, inline_token: "private-inline-token",
  via_app: "Release smoke", allow_unsigned: false,
}

// A healthy origin that also serves the route-family probes.
function probed({ v1 = true, upload = true, introspection = grant as Record<string, unknown>, introspectionCode = 200, inactiveCode = 401 } = {}) {
  const base = origin()
  const calls: Array<{ args: string[]; options?: CurlOptions; body?: string }> = []
  const curl: Curl = async (args, options) => {
    const url = args.at(-1)!
    const file = args[args.indexOf("--data-binary") + 1]?.slice(1)
    calls.push({ args, options, body: args.includes("--data-binary") ? readFileSync(file!, "utf8") : undefined })
    if (url.endsWith("/v1/getMe")) return { code: v1 ? 200 : 500, body: JSON.stringify(v1 ? { ok: true, result: { user: { id: 42 } } } : { ok: false }) }
    if (url.endsWith("/v1/uploadFile")) {
      return { code: 200, body: JSON.stringify(upload ? { ok: true, result: { fileUniqueId: "INP_1", documentId: 5 } } : { ok: true, result: {} }) }
    }
    if (url.endsWith("/oauth/introspect")) {
      const token = JSON.parse(calls.at(-1)!.body!).token as string
      if (token.startsWith("mcp_at_release_smoke_")) return { code: inactiveCode, body: JSON.stringify({ active: false }) }
      return { code: introspectionCode, body: JSON.stringify(introspection) }
    }
    return base.curl(args, options)
  }
  return { curl, calls }
}
const credentials = { userToken: "user-token", mcpSecret: "mcp-secret", oauthToken: "mcp_at_grant" }
const base = { origin: "nuremberg", revision: SHA, token: "t", chatId: "123", now: () => 1 }

describe("release smoke", () => {
  it("passes every check on a healthy origin and pins it when given an address", async () => {
    const o = origin()
    const checks = await smoke({ ...base, ip: "203.0.113.7", curl: o.curl })
    expect(checks.map((c) => [c.name, c.ok])).toEqual([
      ["readiness", true], ["bot login", true], ["send and read back", true],
      ["websocket /realtime", true], ["websocket /realtime/v3", true],
      ["v1 getMe", true], ["v1 upload", true], ["oauth introspection", true],
    ])
    expect(checks.filter((c) => c.skipped).map((c) => c.detail)).toEqual([
      "skipped: INLINE_SMOKE_USER_TOKEN is not configured", "skipped: INLINE_SMOKE_USER_TOKEN is not configured",
      "skipped: INLINE_SMOKE_MCP_SECRET is not configured",
    ])
    expect(failed(checks)).toBe(false)
    for (const call of o.calls) expect(call.slice(0, 2)).toEqual(["--resolve", "api.inline.chat:443:203.0.113.7"])
    expect(o.tokens).toEqual([undefined, "t", "t", "t", undefined, undefined])
    expect(o.calls.flat()).not.toContain("Authorization: Bearer t")
  })

  it("fails on another revision, a lost message or a refused upgrade", async () => {
    const failed = async (options: Parameters<typeof origin>[0]) =>
      (await smoke({ ...base, curl: origin(options).curl })).filter((c) => !c.ok).map((c) => c.name)
    expect(await failed({ revision: "b".repeat(40) })).toEqual(["readiness"])
    expect(await failed({ storesMessage: false })).toEqual(["send and read back"])
    expect(await failed({ upgrades: false })).toEqual(["websocket /realtime", "websocket /realtime/v3"])
  })

  it("refuses to run without credentials or a full revision", async () => {
    await expect(smoke({ ...base, token: "", curl: origin().curl })).rejects.toThrow("SMOKE_BOT_TOKEN")
    await expect(smoke({ ...base, revision: "abc", curl: origin().curl })).rejects.toThrow("full commit")
  })

  it("preflights bot identity and smoke-chat access using reads only", async () => {
    const o = origin()
    const checks = await smoke({ ...base, revision: undefined, ip: "203.0.113.7", preflight: true, curl: o.curl })
    expect(checks.map(({ name, ok }) => [name, ok])).toEqual([
      ["readiness", true], ["bot login", true], ["chat access", true],
    ])
    expect(o.calls.map((call) => call.at(-1))).toEqual([
      "https://api.inline.chat/readyz", "https://api.inline.chat/bot/getMe",
      "https://api.inline.chat/bot/getChatHistory?chat_id=123&limit=10",
    ])
    for (const call of o.calls) expect(call.slice(0, 2)).toEqual(["--resolve", "api.inline.chat:443:203.0.113.7"])
  })

  it("rejects malformed bot identity and inaccessible chat history", async () => {
    for (const bot of [{ id: 0, is_bot: true }, { id: 7, is_bot: false }]) {
      const o = origin({ bot })
      const checks = await smoke({ ...base, preflight: true, curl: o.curl })
      expect(checks.at(-1)).toMatchObject({ name: "bot login", ok: false })
      expect(o.calls.some((call) => call.at(-1)!.includes("getChatHistory"))).toBe(false)
    }
    const checks = await smoke({ ...base, preflight: true, curl: origin({ history: false }).curl })
    expect(checks.at(-1)).toMatchObject({ name: "chat access", ok: false })
  })

  it("does not send anything after readiness or bot authentication fails", async () => {
    for (const o of [origin({ revision: "b".repeat(40) }), origin({ bot: { id: 7, is_bot: false } })]) {
      expect((await smoke({ ...base, curl: o.curl })).at(-1)?.ok).toBe(false)
      expect(o.calls.some((call) => call.at(-1)!.includes("sendMessage"))).toBe(false)
    }
  })

  it("rejects unsafe targets and identifiers before making requests", async () => {
    const o = origin()
    for (const ip of ["not-an-ip", "203.0.113.7:443", "203.0.113.7,attacker.example"]) {
      await expect(smoke({ ...base, ip, curl: o.curl })).rejects.toThrow("IPv4 or IPv6")
    }
    for (const chatId of ["0", "1&chat_id=2", "9007199254740993"]) {
      await expect(smoke({ ...base, chatId, curl: o.curl })).rejects.toThrow("SMOKE_CHAT_ID")
    }
    await expect(smoke({ ...base, token: "t\nmalformed", curl: o.curl })).rejects.toThrow("SMOKE_BOT_TOKEN")
    expect(o.calls).toEqual([])
  })

  it("returns the full ready revision and brackets an IPv6 pin", async () => {
    const o = origin()
    expect(await readReady("2001:db8::7", undefined, o.curl)).toBe(SHA)
    expect(o.calls[0]?.slice(0, 2)).toEqual(["--resolve", "api.inline.chat:443:[2001:db8::7]"])
    await expect(readReady("203.0.113.7", "abc", o.curl)).rejects.toThrow("full commit")
    for (const value of [{ ok: true, draining: true, revision: SHA }, { ok: true, draining: false, revision: "short" }, { ok: false, draining: false, revision: SHA }]) {
      await expect(readReady("203.0.113.7", undefined, async () => ({ code: 200, body: JSON.stringify(value) }))).rejects.toThrow()
    }
  })

  it("does not expose malformed JSON response bodies in error details", async () => {
    const checks = await smoke({ ...base, curl: async () => ({ code: 200, body: "private-fixture-body" }) })
    expect(checks).toEqual([{ name: "readiness", ok: false, detail: "Invalid JSON response" }])
  })

  it("probes each route family on a pinned origin with its own credential", async () => {
    const o = probed()
    const checks = await smoke({ ...base, ip: "203.0.113.7", curl: o.curl, probes: credentials, scratch: tmpdir() })
    expect(checks.slice(5).map(({ name, ok, skipped }) => [name, ok, skipped ?? false])).toEqual([
      ["v1 getMe", true, false], ["v1 upload", true, false],
      ["oauth introspection (inactive token)", true, false], ["oauth introspection (active grant)", true, false],
    ])
    expect(failed(checks)).toBe(false)
    const routes = o.calls.slice(6)
    for (const call of routes) expect(call.args.slice(0, 2)).toEqual(["--resolve", "api.inline.chat:443:203.0.113.7"])
    expect(routes.map((call) => call.options)).toEqual([
      { token: "user-token" }, { token: "user-token" },
      { headers: ["x-inline-mcp-secret: mcp-secret", "Content-Type: application/json"] },
      { headers: ["x-inline-mcp-secret: mcp-secret", "Content-Type: application/json"] },
    ])
    // Credentials and grant tokens never enter argv; the upload is a tiny document.
    for (const call of routes) for (const secret of ["user-token", "mcp-secret", "mcp_at_grant"]) expect(call.args.join(" ")).not.toContain(secret)
    expect(routes[1]!.args).toContain("type=document")
    expect(routes[3]!.body).toBe(JSON.stringify({ token: "mcp_at_grant" }))
    // Nothing from the introspection body (it carries the Inline token) reaches the report.
    expect(JSON.stringify(checks)).not.toContain("private-inline-token")
  })

  it("skips only the probes whose credential is missing, and never probes canonical routing or preflight", async () => {
    const partial = await smoke({ ...base, ip: "203.0.113.7", curl: probed().curl, probes: { mcpSecret: "mcp-secret" } })
    expect(partial.slice(5).map(({ name, skipped }) => [name, skipped ?? false])).toEqual([
      ["v1 getMe", true], ["v1 upload", true], ["oauth introspection (inactive token)", false], ["oauth introspection (active grant)", true],
    ])
    for (const options of [{ ip: undefined }, { ip: "203.0.113.7", preflight: true, revision: undefined }]) {
      const o = probed()
      await smoke({ ...base, ...options, curl: o.curl, probes: credentials })
      expect(o.calls.some((call) => /\/v1\/|\/oauth\//.test(call.args.at(-1)!))).toBe(false)
    }
  })

  it("fails on a broken route family unless probes are advisory", async () => {
    const cases: Array<[Parameters<typeof probed>[0], string]> = [
      [{ v1: false }, "v1 getMe"], [{ upload: false }, "v1 upload"],
      [{ inactiveCode: 500 }, "oauth introspection (inactive token)"],
    ]
    for (const [options, name] of cases) {
      const checks = await smoke({ ...base, ip: "203.0.113.7", curl: probed(options).curl, probes: credentials })
      expect(checks.filter((c) => !c.ok).map((c) => c.name), name).toEqual([name])
      expect(failed(checks)).toBe(true)
      const advisory = await smoke({ ...base, ip: "203.0.113.7", curl: probed(options).curl, probes: credentials, advisoryProbes: true })
      expect(advisory.find((c) => c.name === name)).toMatchObject({ ok: false, advisory: true })
      expect(failed(advisory)).toBe(false)
    }
    // The active-grant probe only warns: its stored token expires after about two hours.
    for (const options of [{ introspectionCode: 401 }, { introspection: { ...grant, allow_unsigned: "no" } }]) {
      const checks = await smoke({ ...base, ip: "203.0.113.7", curl: probed(options).curl, probes: credentials })
      expect(checks.at(-1)).toMatchObject({ name: "oauth introspection (active grant)", ok: false, advisory: true })
      expect(failed(checks)).toBe(false)
    }
    // Advisory mode never relaxes the base release checks.
    const base_ = await smoke({ ...base, ip: "203.0.113.7", curl: origin({ upgrades: false }).curl, advisoryProbes: true })
    expect(failed(base_)).toBe(true)
  })

  it("checks every introspection contract field the MCP server consumes", () => {
    expect(checkIntrospection(grant, 1)).toContain("matches")
    const { via_app: _via, allow_unsigned: _unsigned, ...required } = grant
    expect(checkIntrospection(required, 1)).toContain("matches")
    expect(() => checkIntrospection({ ...grant, exp: 1 }, 2)).toThrow("exp")
    expect(() => checkIntrospection({ ...grant, space_ids: [7] }, 1)).toThrow("space_ids")
    expect(() => checkIntrospection({ active: true }, 1)).toThrow("grant_id, client_id, scope, aud, inline_token, inline_user_id")
  })

  it("reads probe credentials by name, rejects malformed ones before any request, and annotates skips", async () => {
    expect(probeCredentials({ INLINE_SMOKE_USER_TOKEN: "u", INLINE_SMOKE_MCP_SECRET: "", INLINE_SMOKE_OAUTH_TOKEN: undefined }))
      .toEqual({ userToken: "u", mcpSecret: undefined, oauthToken: undefined })
    const o = origin()
    await expect(smoke({ ...base, ip: "203.0.113.7", curl: o.curl, probes: { mcpSecret: "a\nb" } })).rejects.toThrow("mcpSecret")
    expect(o.calls).toEqual([])
    const lines: string[] = []
    annotate("fly", [{ name: "v1 getMe", ok: true, skipped: true, detail: "skipped: X" }, { name: "v1 upload", ok: false, advisory: true, detail: "HTTP 500" }, { name: "readiness", ok: true, detail: "ok" }], (line) => lines.push(line))
    expect(lines).toEqual([
      "::notice title=Smoke probe skipped (fly)::v1 getMe: skipped: X",
      "::warning title=Smoke probe failed, advisory (fly)::v1 upload: HTTP 500",
    ])
  })

  it("passes the bot token to the curl process through stdin, never argv", async () => {
    const directory = await mkdtemp(join(tmpdir(), "inline-smoke-curl-"))
    const previous = { PATH: process.env.PATH, INLINE_SMOKE_TEST_ARGS: process.env.INLINE_SMOKE_TEST_ARGS, INLINE_SMOKE_TEST_HEADERS: process.env.INLINE_SMOKE_TEST_HEADERS }
    try {
      const executable = join(directory, "curl")
      await writeFile(executable, '#!/bin/sh\nprintf "%s\\n" "$@" > "$INLINE_SMOKE_TEST_ARGS"\n/bin/cat > "$INLINE_SMOKE_TEST_HEADERS"\nprintf "{}\\n200"\n')
      await chmod(executable, 0o700)
      process.env.PATH = `${directory}:${previous.PATH}`
      process.env.INLINE_SMOKE_TEST_ARGS = join(directory, "args")
      process.env.INLINE_SMOKE_TEST_HEADERS = join(directory, "headers")
      expect(await curl(["https://smoke.invalid/bot/getMe"], { token: "fixture-safe-token" })).toEqual({ code: 200, body: "{}" })
      const args = await readFile(process.env.INLINE_SMOKE_TEST_ARGS, "utf8")
      expect(args).toContain("@-")
      expect(args).not.toContain("fixture-safe-token")
      expect(await readFile(process.env.INLINE_SMOKE_TEST_HEADERS, "utf8")).toBe("Authorization: Bearer fixture-safe-token\n")
      expect(await curl(["https://smoke.invalid/oauth/introspect"], { headers: ["x-inline-mcp-secret: fixture-secret"] })).toEqual({ code: 200, body: "{}" })
      expect(await readFile(process.env.INLINE_SMOKE_TEST_ARGS, "utf8")).not.toContain("fixture-secret")
      expect(await readFile(process.env.INLINE_SMOKE_TEST_HEADERS, "utf8")).toBe("x-inline-mcp-secret: fixture-secret\n")
      await expect(curl(["https://smoke.invalid/"], { headers: ["a: b\r\nc: d"] })).rejects.toThrow("Invalid smoke header")
    } finally {
      for (const [key, value] of Object.entries(previous)) {
        if (value === undefined) delete process.env[key]
        else process.env[key] = value
      }
      await rm(directory, { recursive: true, force: true })
    }
  })
})
