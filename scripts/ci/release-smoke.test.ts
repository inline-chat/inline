import { describe, expect, it } from "bun:test"
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { curl, readReady, smoke, type Curl } from "./release-smoke"

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
const base = { origin: "nuremberg", revision: SHA, token: "t", chatId: "123", now: () => 1 }

describe("release smoke", () => {
  it("passes every check on a healthy origin and pins it when given an address", async () => {
    const o = origin()
    const checks = await smoke({ ...base, ip: "203.0.113.7", curl: o.curl })
    expect(checks.map((c) => [c.name, c.ok])).toEqual([
      ["readiness", true], ["bot login", true], ["send and read back", true],
      ["websocket /realtime", true], ["websocket /realtime/v3", true],
    ])
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
    } finally {
      for (const [key, value] of Object.entries(previous)) {
        if (value === undefined) delete process.env[key]
        else process.env[key] = value
      }
      await rm(directory, { recursive: true, force: true })
    }
  })
})
