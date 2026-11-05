import { describe, expect, test } from "bun:test"
import { ClientMessage, Message, ServerProtocolMessage, type Update } from "@inline-chat/protocol/core"
import { crossOriginSmoke, NativeWebSocket, originSocketTarget, type CrossOriginOptions } from "./realtime-cross-origin-smoke"

const SHA = "a".repeat(40)
const TOKEN = "11:synthetic-release-token"
const bot = { id: 11, is_bot: true, username: "inline_release_smoke_bot" }
const chat = { chat_id: 7, type: "thread", title: "Inline Release Smoke", is_public: false }

function fixture(options: { hintsOnly?: boolean; wrongBot?: boolean; wrongChat?: boolean; wrongRevision?: boolean; ambiguousSend?: boolean } = {}) {
  const receivers = new Map<string, Bun.ServerWebSocket<{ ip: string }>>()
  const calls: Array<{ ip: string; path: string }> = []
  const receivedClientKinds: string[] = []
  let nextId = 100
  let maximumReceivers = 0
  let sends = 0
  const server = Bun.serve<{ ip: string }>({
    hostname: "127.0.0.1", port: 0,
    fetch(request, current) {
      if (current.upgrade(request, { data: { ip: new URL(request.url).searchParams.get("ip")! } })) return
      return new Response(null, { status: 400 })
    },
    websocket: {
      open(socket) { receivers.set(socket.data.ip, socket); maximumReceivers = Math.max(maximumReceivers, receivers.size) },
      close(socket) { receivers.delete(socket.data.ip) },
      message(socket, data) {
        const frame = ClientMessage.fromBinary(new Uint8Array(data as Buffer))
        receivedClientKinds.push(frame.body.oneofKind ?? "unknown")
        expect(frame.body.oneofKind).toBe("connectionInit")
        if (frame.body.oneofKind === "connectionInit") {
          expect(frame.body.connectionInit.token).toBe(TOKEN)
          expect(frame.body.connectionInit.layer).toBe(1)
          socket.send(ServerProtocolMessage.toBinary({ id: 1n, body: { oneofKind: "connectionOpen", connectionOpen: {} } }))
        }
      },
    },
  })
  const probe: CrossOriginOptions = {
    revision: SHA, flyIp: "127.0.0.1", nbgIp: "127.0.0.2", token: TOKEN, chatId: "7", performWrites: true, timeoutMs: 100,
    createSocket: (ip) => new NativeWebSocket(`ws://127.0.0.1:${server.port}/?ip=${ip}`),
    api: async (ip, path, token, body) => {
      calls.push({ ip, path })
      if (path === "/readyz") return { ok: true, revision: options.wrongRevision ? "b".repeat(40) : SHA, draining: false }
      expect(token).toBe(TOKEN)
      if (path === "/bot/getMe") return { ok: true, result: { user: options.wrongBot ? { ...bot, username: "someone_else_bot" } : bot } }
      if (path.startsWith("/bot/getChat?")) return { ok: true, result: { chat: options.wrongChat ? { ...chat, space_id: 22 } : chat } }
      if (path !== "/bot/sendMessage") throw new Error("Unexpected API call")
      sends++
      if (options.ambiguousSend) throw new Error("private-provider-detail-must-not-escape")
      const request = body as { chat_id: number; text: string; silent: boolean; parse_markdown: boolean }
      expect(request).toMatchObject({ chat_id: 7, silent: true, parse_markdown: false })
      const id = ++nextId
      const receiver = [...receivers.entries()].find(([receiverIp]) => receiverIp !== ip)?.[1]
      if (!receiver) throw new Error("Missing opposite-origin receiver")
      const update: Update = options.hintsOnly
        ? { update: { oneofKind: "chatHasNewUpdates", chatHasNewUpdates: { chatId: 7n, updateSeq: 1 } } }
        : { update: { oneofKind: "newMessage", newMessage: { message: Message.create({
          id: BigInt(id), chatId: 7n, fromId: 11n, message: request.text,
        }) } } }
      receiver.send(ServerProtocolMessage.toBinary({ id: 2n, body: { oneofKind: "message", message: {
        payload: { oneofKind: "update", update: { updates: [update] } },
      } } }))
      return { ok: true, result: { message: { message_id: id } } }
    },
  }
  return { probe, calls, receivedClientKinds, get sends() { return sends }, get maximumReceivers() { return maximumReceivers },
    close: () => server.stop(true) }
}

describe("cross-origin live qualification", () => {
  test("requires a full unsolicited large projection in both directions with one receiver at a time", async () => {
    const f = fixture()
    try {
      const report = await crossOriginSmoke(f.probe)
      expect(report.deliveries.map((delivery) => delivery.direction)).toEqual(["fly->nuremberg", "nuremberg->fly"])
      expect(report.deliveries.map((delivery) => delivery.messageId)).toEqual([101, 102])
      for (const delivery of report.deliveries) {
        expect(delivery.textBytes).toBe(20_100)
        expect(delivery.updatesBytes).toBeGreaterThan(20_000)
        expect(delivery.unsolicitedLivePush).toBe(true)
        expect(delivery.getUpdatesRequests).toBe(0)
      }
      expect(f.maximumReceivers).toBe(1)
      expect(f.receivedClientKinds).toEqual(["connectionInit", "connectionInit"])
      expect(f.sends).toBe(2)
    } finally { f.close() }
  })

  test("does not mistake a durable hint for live message delivery or retry the ambiguous send", async () => {
    const f = fixture({ hintsOnly: true })
    try {
      await expect(crossOriginSmoke(f.probe)).rejects.toThrow("No full cross-origin push for message 101")
      expect(f.sends).toBe(1)
      expect(f.receivedClientKinds).toEqual(["connectionInit"])
      expect(f.calls.every((call) => !call.path.includes("getUpdates"))).toBe(true)
    } finally { f.close() }
  })

  test("read-only preflight authenticates both origins without opening sockets or sending", async () => {
    const f = fixture()
    try {
      const report = await crossOriginSmoke({ ...f.probe, revision: undefined, performWrites: false })
      expect(report.preflight).toBe(true)
      expect(report.deliveries).toEqual([])
      expect(f.sends).toBe(0)
      expect(f.maximumReceivers).toBe(0)
    } finally { f.close() }
  })

  test("classifies a failed send as ambiguous without exposing its cause or resending", async () => {
    const f = fixture({ ambiguousSend: true })
    try {
      await expect(crossOriginSmoke(f.probe)).rejects.toThrow("Send outcome is ambiguous; inspect the smoke chat before retrying")
      expect(f.sends).toBe(1)
    } finally { f.close() }
  })

  test("pins the receiver to an origin IP while preserving the canonical TLS identity and Host", () => {
    expect(originSocketTarget("203.0.113.9")).toEqual({ url: "wss://203.0.113.9/realtime", options: {
      headers: { Host: "api.inline.chat" }, tls: { serverName: "api.inline.chat", rejectUnauthorized: true },
    } })
    expect(originSocketTarget("2001:db8::9").url).toBe("wss://[2001:db8::9]/realtime")
    expect(() => originSocketTarget("203.0.113.9:443")).toThrow()
  })

  for (const fault of ["wrongBot", "wrongChat", "wrongRevision"] as const) {
    test(`rejects ${fault} before any send`, async () => {
      const f = fixture({ [fault]: true })
      try {
        await expect(crossOriginSmoke(f.probe)).rejects.toThrow()
        expect(f.sends).toBe(0)
        expect(f.maximumReceivers).toBe(0)
      } finally { f.close() }
    })
  }

  test("rejects unsafe credentials, revisions, origin pins and target IDs before network access", async () => {
    const f = fixture()
    try {
      for (const override of [{ token: "bad\ntoken" }, { revision: "short" }, { chatId: "1&chat_id=2" }, { flyIp: "bad" }, { nbgIp: "127.0.0.1" }]) {
        await expect(crossOriginSmoke({ ...f.probe, ...override })).rejects.toThrow()
      }
      expect(f.calls).toEqual([])
      expect(f.sends).toBe(0)
    } finally { f.close() }
  })
})
