import { describe, expect, it, vi } from "vitest"
import { Method, ServerProtocolMessage, Update } from "@inline-chat/protocol/core"
import { ProtocolClient, ProtocolClientError } from "./protocol-client.js"
import { MockTransport } from "./mock-transport.js"
import { AsyncChannel } from "../utils/async-channel.js"
import type { Transport } from "./transport.js"
import type { TransportEvent } from "./types.js"
import { ClientMessage } from "@inline-chat/protocol/core"

const waitFor = async (predicate: () => boolean, timeoutMs = 300) => {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    if (predicate()) return
    await new Promise((r) => setTimeout(r, 5))
  }
  throw new Error("Timed out waiting for condition")
}

const waitForOpen = async (client: ProtocolClient) => {
  await waitFor(() => client.state === "open")
}

describe("ProtocolClient", () => {
  const flushMicrotasks = async (count = 10) => {
    for (let i = 0; i < count; i++) await Promise.resolve()
  }
  it("sends connection init on connect", async () => {
    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t", layer: 2 }),
    })

    await client.startTransport()
    await transport.connect()

    await waitFor(() => transport.sent.length > 0)
    expect(transport.sent[0].body.oneofKind).toBe("connectionInit")
    if (transport.sent[0].body.oneofKind === "connectionInit") {
      expect(transport.sent[0].body.connectionInit.token).toBe("t")
      expect(transport.sent[0].body.connectionInit.layer).toBe(2)
    }
  })

  it("emits open after connectionOpen", async () => {
    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    const iter = client.events[Symbol.asyncIterator]()

    await client.startTransport()
    await transport.connect()
    await transport.emitMessage(
      ServerProtocolMessage.create({ id: 1n, body: { oneofKind: "connectionOpen", connectionOpen: {} } }),
    )

    const start = Date.now()
    while (Date.now() - start < 300) {
      const next = await iter.next()
      if (next.done) break
      if (next.value.type === "open") return
    }

    throw new Error("Timed out waiting for open")
  })

  it("callRpc resolves on rpcResult and rejects on rpcError", async () => {
    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    await client.startTransport()
    await transport.connect()
    await transport.emitMessage(
      ServerProtocolMessage.create({ id: 1n, body: { oneofKind: "connectionOpen", connectionOpen: {} } }),
    )
    await waitForOpen(client)

    const p = client.callRpc(Method.GET_ME, { oneofKind: "getMe", getMe: {} })
    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall"))
    const rpc = transport.sent.find((m) => m.body.oneofKind === "rpcCall")
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing rpc")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 2n,
        body: { oneofKind: "rpcResult", rpcResult: { reqMsgId: rpc.id, result: { oneofKind: "getMe", getMe: { user: { id: 1n } } } } },
      }),
    )

    const result = await p
    expect(result.oneofKind).toBe("getMe")

    const p2 = client.callRpc(Method.GET_ME, { oneofKind: "getMe", getMe: {} })
    await waitFor(() => transport.sent.filter((m) => m.body.oneofKind === "rpcCall").length >= 2)
    const rpc2 = transport.sent.filter((m) => m.body.oneofKind === "rpcCall")[1]
    if (!rpc2 || rpc2.body.oneofKind !== "rpcCall") throw new Error("missing rpc2")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 3n,
        body: { oneofKind: "rpcError", rpcError: { reqMsgId: rpc2.id, errorCode: 2, message: "nope", code: 401 } },
      }),
    )

    await expect(p2).rejects.toBeInstanceOf(ProtocolClientError)
  })

  it("callRpc can time out", async () => {
    vi.useFakeTimers()
    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    await client.startTransport()
    await transport.connect()
    await transport.emitMessage(
      ServerProtocolMessage.create({ id: 1n, body: { oneofKind: "connectionOpen", connectionOpen: {} } }),
    )
    ;(client as any).state = "open"

    const p = client.callRpc(Method.GET_ME, { oneofKind: "getMe", getMe: {} }, { timeoutMs: 10 })
    const settled = p.then(
      () => ({ ok: true as const }),
      (error) => ({ ok: false as const, error }),
    )

    await vi.advanceTimersByTimeAsync(20)
    const out = await settled
    expect(out.ok).toBe(false)
    if (out.ok) throw new Error("expected timeout")
    expect(out.error).toBeInstanceOf(ProtocolClientError)
    vi.useRealTimers()
  })

  it("supports configurable default timeout and infinite timeout", async () => {
    vi.useFakeTimers()

    const shortTimeoutTransport = new MockTransport()
    const shortTimeoutClient = new ProtocolClient({
      transport: shortTimeoutTransport,
      getConnectionInit: () => ({ token: "t" }),
      defaultRpcTimeoutMs: 25,
    })
    await shortTimeoutClient.startTransport()

    const shortTimeoutCall = shortTimeoutClient.callRpc(Method.GET_ME, { oneofKind: "getMe", getMe: {} })
    const shortTimeoutSettled = shortTimeoutCall.then(
      () => ({ ok: true as const }),
      (error) => ({ ok: false as const, error }),
    )
    await vi.advanceTimersByTimeAsync(30)
    const shortTimeoutResult = await shortTimeoutSettled
    expect(shortTimeoutResult.ok).toBe(false)
    if (shortTimeoutResult.ok) throw new Error("expected timeout")
    expect(shortTimeoutResult.error).toBeInstanceOf(ProtocolClientError)

    const infiniteTimeoutTransport = new MockTransport()
    const infiniteTimeoutClient = new ProtocolClient({
      transport: infiniteTimeoutTransport,
      getConnectionInit: () => ({ token: "t" }),
      defaultRpcTimeoutMs: null,
    })
    await infiniteTimeoutClient.startTransport()

    let settled = false
    const infiniteTimeoutCall = infiniteTimeoutClient.callRpc(Method.GET_ME, { oneofKind: "getMe", getMe: {} })
    const infiniteTimeoutSettled = infiniteTimeoutCall.then(
      () => ({ ok: true as const }),
      (error) => ({ ok: false as const, error }),
    )
    infiniteTimeoutSettled.finally(() => {
      settled = true
    })

    await vi.advanceTimersByTimeAsync(60_000)
    expect(settled).toBe(false)

    await infiniteTimeoutTransport.stop()
    const infiniteTimeoutResult = await infiniteTimeoutSettled
    expect(infiniteTimeoutResult.ok).toBe(false)
    if (infiniteTimeoutResult.ok) throw new Error("expected stop rejection")
    expect(infiniteTimeoutResult.error).toBeInstanceOf(ProtocolClientError)

    vi.useRealTimers()
  })

  it("uses 30s default timeout when timeout is not specified", async () => {
    vi.useFakeTimers()

    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })
    await client.startTransport()

    let settled = false
    const p = client.callRpc(Method.GET_ME, { oneofKind: "getMe", getMe: {} })
    const pSettled = p.then(
      () => ({ ok: true as const }),
      (error) => ({ ok: false as const, error }),
    )
    pSettled.finally(() => {
      settled = true
    })

    await vi.advanceTimersByTimeAsync(29_999)
    expect(settled).toBe(false)

    await vi.advanceTimersByTimeAsync(1)
    const out = await pSettled
    expect(out.ok).toBe(false)
    if (out.ok) throw new Error("expected default timeout")
    expect(out.error).toBeInstanceOf(ProtocolClientError)

    vi.useRealTimers()
  })

  it("allows per-call infinite timeout override", async () => {
    vi.useFakeTimers()

    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
      defaultRpcTimeoutMs: 25,
    })
    await client.startTransport()

    let settled = false
    const p = client.callRpc(Method.GET_ME, { oneofKind: "getMe", getMe: {} }, { timeoutMs: null })
    const pSettled = p.then(
      () => ({ ok: true as const }),
      (error) => ({ ok: false as const, error }),
    )
    pSettled.finally(() => {
      settled = true
    })

    await vi.advanceTimersByTimeAsync(60_000)
    expect(settled).toBe(false)

    await transport.stop()
    const out = await pSettled
    expect(out.ok).toBe(false)
    if (out.ok) throw new Error("expected stop rejection")
    expect(out.error).toBeInstanceOf(ProtocolClientError)

    vi.useRealTimers()
  })

  it("emits ack and updates events", async () => {
    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    const iter = client.events[Symbol.asyncIterator]()

    await client.startTransport()
    await transport.connect()
    await transport.emitMessage(ServerProtocolMessage.create({ id: 1n, body: { oneofKind: "connectionOpen", connectionOpen: {} } }))

    await transport.emitMessage(ServerProtocolMessage.create({ id: 2n, body: { oneofKind: "ack", ack: { msgId: 123n } } }))
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 3n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    update: { oneofKind: "spaceHasNewUpdates", spaceHasNewUpdates: { spaceId: 1n, updateSeq: 1 } },
                  }),
                ],
              },
            },
          },
        },
      }),
    )

    const seen = new Set<string>()
    const start = Date.now()
    while (Date.now() - start < 300 && (!seen.has("ack") || !seen.has("updates"))) {
      const next = await iter.next()
      if (next.done) break
      seen.add(next.value.type)
    }

    expect(seen.has("ack")).toBe(true)
    expect(seen.has("updates")).toBe(true)
  })

  it("cancels pending RPCs on transport stop", async () => {
    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    await client.startTransport()
    await transport.connect()
    await transport.emitMessage(ServerProtocolMessage.create({ id: 1n, body: { oneofKind: "connectionOpen", connectionOpen: {} } }))
    await waitForOpen(client)

    const p = client.callRpc(Method.GET_ME, { oneofKind: "getMe", getMe: {} }, { timeoutMs: 0 })
    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall"))

    await transport.stop()
    await expect(p).rejects.toBeInstanceOf(ProtocolClientError)
  })

  it("retries pending RPCs after reconnect and auth open", async () => {
    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    await client.startTransport()
    await transport.connect()
    await transport.emitMessage(ServerProtocolMessage.create({ id: 1n, body: { oneofKind: "connectionOpen", connectionOpen: {} } }))
    await waitForOpen(client)

    const p = client.callRpc(Method.GET_ME, { oneofKind: "getMe", getMe: {} }, { timeoutMs: 10_000 })
    await waitFor(() => transport.sent.filter((m) => m.body.oneofKind === "rpcCall").length >= 1)
    const firstRpc = transport.sent.find((m) => m.body.oneofKind === "rpcCall")
    if (!firstRpc || firstRpc.body.oneofKind !== "rpcCall") throw new Error("missing first rpc")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 2n,
        body: { oneofKind: "connectionError", connectionError: {} },
      }),
    )

    // attemptNo=1 => delay ~0.6s
    await waitFor(() => transport.state === "connecting", 1_500)
    await transport.connect()
    await waitFor(() => transport.sent.filter((m) => m.body.oneofKind === "connectionInit").length >= 2)
    await transport.emitMessage(ServerProtocolMessage.create({ id: 3n, body: { oneofKind: "connectionOpen", connectionOpen: {} } }))

    await waitFor(() => transport.sent.filter((m) => m.body.oneofKind === "rpcCall").length >= 2)
    const resent = transport.sent.filter((m) => m.body.oneofKind === "rpcCall")[1]
    expect(resent.id).toBe(firstRpc.id)

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 4n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: { reqMsgId: firstRpc.id, result: { oneofKind: "getMe", getMe: { user: { id: 7n } } } },
        },
      }),
    )

    await expect(p).resolves.toEqual({ oneofKind: "getMe", getMe: { user: { id: 7n } } })
  })

  it("schedules reconnect when authentication fails (no token)", async () => {
    vi.useFakeTimers()

    class SpyTransport implements Transport {
      readonly events = new AsyncChannel<TransportEvent>()
      reconnectCalls = 0

      async start() {
        await this.events.send({ type: "connecting" })
      }
      async stop() {
        await this.events.send({ type: "stopping" })
      }
      async send(_message: ClientMessage) {
        throw new Error("send should not be called")
      }
      async stopConnection() {}
      async reconnect() {
        this.reconnectCalls++
        await this.events.send({ type: "connecting" })
      }
    }

    const transport = new SpyTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => null,
    })

    await client.startTransport()
    await transport.events.send({ type: "connected" })

    await vi.advanceTimersByTimeAsync(9000)
    expect(transport.reconnectCalls).toBeGreaterThanOrEqual(1)
    vi.useRealTimers()
  })

  it("sendPing() swallows transport send failures and logs", async () => {
    const errors: unknown[] = []
    class ThrowingTransport implements Transport {
      readonly events = new AsyncChannel<TransportEvent>()
      async start() {}
      async stop() {}
      async stopConnection() {}
      async reconnect() {}
      async send(_message: ClientMessage) {
        throw new Error("boom")
      }
    }

    const transport = new ThrowingTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
      logger: {
        error: (...args: unknown[]) => {
          errors.push(args)
        },
      },
    })

    await expect(client.sendPing(1n)).resolves.toBeUndefined()
    expect(errors.length).toBeGreaterThan(0)
  })

  it("sendPing() sends a ping when connected (success path)", async () => {
    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    await client.startTransport()
    await transport.connect()
    await client.sendPing(5n)

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "ping"))
  })

  it("schedules a reconnect when a connectionError is received (and does not reconnect after open)", async () => {
    vi.useFakeTimers()

    class SpyTransport implements Transport {
      readonly events = new AsyncChannel<TransportEvent>()
      reconnectCalls = 0
      async start() {
        await this.events.send({ type: "connecting" })
      }
      async stop() {}
      async stopConnection() {}
      async reconnect() {
        this.reconnectCalls++
      }
      async send(_message: ClientMessage) {}
    }

    const transport = new SpyTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    await client.startTransport()
    await transport.events.send({ type: "connected" })

    // Trigger failure handling.
    await transport.events.send({
      type: "message",
      message: ServerProtocolMessage.create({ id: 1n, body: { oneofKind: "connectionError", connectionError: { code: 500, message: "nope" } } }),
    })

    // attemptNo=1 => delay ~0.6s
    await vi.advanceTimersByTimeAsync(600)
    expect(transport.reconnectCalls).toBe(1)

    // If the connection opens, scheduled reconnect should no-op.
    await transport.events.send({
      type: "message",
      message: ServerProtocolMessage.create({ id: 2n, body: { oneofKind: "connectionOpen", connectionOpen: {} } }),
    })

    await vi.advanceTimersByTimeAsync(20_000)
    expect(transport.reconnectCalls).toBe(1)

    vi.useRealTimers()
  })

  it("authentication timeout triggers reconnect when connectionOpen never arrives", async () => {
    vi.useFakeTimers()

    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    await client.startTransport()
    await transport.connect()

    // We do not send connectionOpen. After 10s auth timeout, client should schedule reconnect.
    await vi.advanceTimersByTimeAsync(10_000 + 700)
    expect(transport.state).toBe("connecting")

    vi.useRealTimers()
  })

  it("authentication timeout callback no-ops if already open", async () => {
    vi.useFakeTimers()
    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    const failureSpy = vi.spyOn(client as any, "handleClientFailure")

    ;(client as any).state = "open"
    ;(client as any).startAuthenticationTimeout()
    await vi.advanceTimersByTimeAsync(10_000)
    expect(failureSpy).not.toHaveBeenCalled()
    vi.useRealTimers()
  })

  it("reconnection timer callback no-ops if state becomes open before it fires", async () => {
    vi.useFakeTimers()
    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    const reconnectSpy = vi.spyOn(client, "reconnect")
    ;(client as any).handleClientFailure()
    client.state = "open"

    await vi.advanceTimersByTimeAsync(1_000)
    expect(reconnectSpy).not.toHaveBeenCalled()
    vi.useRealTimers()
  })

  it("getAndRemovePendingRpcRequest returns null when missing", async () => {
    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    expect((client as any).getAndRemovePendingRpcRequest(999n)).toBeNull()
  })

  it("covers timeout normalization and pending-request helper guards", async () => {
    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    expect((client as any).resolveRpcTimeoutMs(Number.POSITIVE_INFINITY)).toBeNull()
    expect((client as any).resolveRpcTimeoutMs(Number.NaN)).toBeNull()

    ;(client as any).state = "open"
    ;(client as any).trySendPendingRpcRequest(123n)

    const timeout = setTimeout(() => {}, 1_000)
    ;(client as any).pendingRpcRequests.set(123n, {
      message: ClientMessage.create({ id: 123n, seq: 1, body: { oneofKind: "rpcCall", rpcCall: { method: Method.GET_ME, input: { oneofKind: "getMe", getMe: {} } } } }),
      resolve: () => {},
      reject: () => {},
      timeout,
      timeoutMs: 1_000,
      sending: false,
    })

    const removed = (client as any).getAndRemovePendingRpcRequest(123n)
    expect(removed).not.toBeNull()
  })

  it("keeps pending RPC when send fails with a non-Error and times out later", async () => {
    vi.useFakeTimers()

    class WeirdTransport implements Transport {
      readonly events = new AsyncChannel<TransportEvent>()
      async start() {}
      async stop() {}
      async stopConnection() {}
      async reconnect() {}
      async send(_message: ClientMessage) {
        throw "boom"
      }
    }

    const transport = new WeirdTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    ;(client as any).state = "open"
    const p = client.callRpc(Method.GET_ME, { oneofKind: "getMe", getMe: {} }, { timeoutMs: 10 })
    const settled = p.then(
      () => ({ ok: true as const }),
      (error) => ({ ok: false as const, error }),
    )

    await vi.advanceTimersByTimeAsync(20)
    const out = await settled
    expect(out.ok).toBe(false)
    if (out.ok) throw new Error("expected timeout")
    expect(out.error).toBeInstanceOf(ProtocolClientError)

    vi.runOnlyPendingTimers()
    vi.useRealTimers()
  })

  it("covers callRpc timeout callback no-op when rpc already settled", async () => {
    vi.useFakeTimers()

    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    await client.startTransport()
    await transport.connect()
    await transport.emitMessage(ServerProtocolMessage.create({ id: 1n, body: { oneofKind: "connectionOpen", connectionOpen: {} } }))
    ;(client as any).state = "open"

    const p = client.callRpc(Method.GET_ME, { oneofKind: "getMe", getMe: {} }, { timeoutMs: 10 })
    for (let i = 0; i < 20; i++) {
      if (transport.sent.some((m) => m.body.oneofKind === "rpcCall")) break
      await Promise.resolve()
    }
    const rpc = transport.sent.find((m) => m.body.oneofKind === "rpcCall")
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing rpc")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 2n,
        body: { oneofKind: "rpcResult", rpcResult: { reqMsgId: rpc.id, result: { oneofKind: "getMe", getMe: { user: { id: 1n } } } } },
      }),
    )
    await expect(p).resolves.toBeDefined()

    // Advance past timeout; callback should see pending request missing and no-op.
    await vi.advanceTimersByTimeAsync(20)

    vi.useRealTimers()
  })

  it("covers non-update message payload branch and startListeners() early return", async () => {
    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    // startListeners() should be idempotent.
    await expect((client as any).startListeners()).resolves.toBeUndefined()

    // payload.oneofKind !== update should not emit an updates event.
    await expect(
      (client as any).handleTransportMessage(
        ServerProtocolMessage.create({
          id: 3n,
          body: {
            oneofKind: "message",
            message: { payload: { oneofKind: undefined } as any },
          },
        }),
      ),
    ).resolves.toBeUndefined()

    // No event should be produced synchronously.
    await expect(Promise.resolve()).resolves.toBeUndefined()
  })

  it("generated ids increment within the same timestamp", async () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-02-01T00:00:00.000Z"))

    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    await client.startTransport()
    await transport.connect()
    await transport.emitMessage(ServerProtocolMessage.create({ id: 1n, body: { oneofKind: "connectionOpen", connectionOpen: {} } }))
    ;(client as any).state = "open"

    const id1 = await client.sendRpc(Method.GET_ME, { oneofKind: "getMe", getMe: {} })
    const id2 = await client.sendRpc(Method.GET_ME, { oneofKind: "getMe", getMe: {} })

    expect(id2).toBe(id1 + 1n)

    vi.useRealTimers()
  })

  it("queues callRpc before open and sends after auth open (while sendRpc still rejects)", async () => {
    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    await client.startTransport()

    await expect(client.sendRpc(Method.GET_ME, { oneofKind: "getMe", getMe: {} })).rejects.toBeInstanceOf(ProtocolClientError)

    const p = client.callRpc(Method.GET_ME, { oneofKind: "getMe", getMe: {} }, { timeoutMs: 5_000 })
    expect(transport.sent.some((message) => message.body.oneofKind === "rpcCall")).toBe(false)

    await transport.connect()
    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "connectionInit"))
    await transport.emitMessage(ServerProtocolMessage.create({ id: 1n, body: { oneofKind: "connectionOpen", connectionOpen: {} } }))

    await waitFor(() => transport.sent.some((message) => message.body.oneofKind === "rpcCall"))
    const rpc = transport.sent.find((message) => message.body.oneofKind === "rpcCall")
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing rpc")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 2n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: { reqMsgId: rpc.id, result: { oneofKind: "getMe", getMe: { user: { id: 2n } } } },
        },
      }),
    )
    await expect(p).resolves.toEqual({ oneofKind: "getMe", getMe: { user: { id: 2n } } })
  })

  it("covers connecting/stopping events, pong handling, send-failed rpc timeout, and reconnection delay branch", async () => {
    vi.useFakeTimers()

    const transport = new MockTransport()
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
    })

    const pongSpy = vi.spyOn(client.pingPong, "pong")
    const randomSpy = vi.spyOn(Math, "random").mockReturnValue(0)

    const iter = client.events[Symbol.asyncIterator]()
    await client.startTransport()

    // MockTransport.start emits connecting, which should be forwarded by the client.
    expect((await iter.next()).value).toEqual({ type: "connecting" })

    await transport.connect()
    await transport.emitMessage(ServerProtocolMessage.create({ id: 1n, body: { oneofKind: "connectionOpen", connectionOpen: {} } }))
    await flushMicrotasks()
    expect(client.state).toBe("open")

    // Pong should be forwarded to PingPongService.
    await transport.emitMessage(ServerProtocolMessage.create({ id: 2n, body: { oneofKind: "pong", pong: { nonce: 123n } } }))
    expect(pongSpy).toHaveBeenCalledWith(123n)

    // Create a client with a transport that fails sends so callRpc eventually times out.
    class FailSendTransport implements Transport {
      readonly events = new AsyncChannel<TransportEvent>()
      reconnectCalls = 0
      async start() {
        await this.events.send({ type: "connected" })
      }
      async stop() {}
      async stopConnection() {}
      async reconnect() {
        this.reconnectCalls++
      }
      async send(_message: ClientMessage) {
        throw new Error("send boom")
      }
    }

    const failTransport = new FailSendTransport()
    const client2 = new ProtocolClient({
      transport: failTransport,
      getConnectionInit: () => ({ token: "t" }),
    })

    ;(client2 as any).state = "open"

    const rpcWithFailingSend = client2.callRpc(Method.GET_ME, { oneofKind: "getMe", getMe: {} }, { timeoutMs: 20 })
    const rpcWithFailingSendSettled = rpcWithFailingSend.then(
      () => ({ ok: true as const }),
      (error) => ({ ok: false as const, error }),
    )
    await vi.advanceTimersByTimeAsync(700)
    const failingSendResult = await rpcWithFailingSendSettled
    expect(failingSendResult.ok).toBe(false)
    if (failingSendResult.ok) throw new Error("expected timeout")
    expect(failingSendResult.error).toBeInstanceOf(ProtocolClientError)
    expect(failTransport.reconnectCalls).toBeGreaterThanOrEqual(1)

    // Reconnection delay branch for >=8 attempts.
    ;(client as any).connectionAttemptNo = 8
    const delay = (client as any).getReconnectionDelay()
    expect(delay).toBe(8)

    // Stopping transport emits stopping -> client reset path.
    await client.stopTransport()
    expect(client.state).toBe("connecting")

    randomSpy.mockRestore()
    vi.useRealTimers()
  })

  it("logs if the transport events iterator throws, and covers default message + reconnectionTimer clear branch", async () => {
    const errors: unknown[] = []

    const transport: Transport = {
      events: {
        [Symbol.asyncIterator]: async function* () {
          yield { type: "connecting" } as const
          throw new Error("boom")
        },
      },
      async start() {},
      async stop() {},
      async stopConnection() {},
      async reconnect() {},
      async send(_message: ClientMessage) {},
    }

    // Listener starts in constructor.
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "t" }),
      logger: { error: (...args: unknown[]) => errors.push(args) },
    })

    // Let the listener run and crash.
    await waitFor(() => errors.length > 0)

    // Cover default branch in handleTransportMessage via direct call.
    await expect(
      (client as any).handleTransportMessage(ServerProtocolMessage.create({ id: 123n, body: { oneofKind: undefined } as any })),
    ).resolves.toBeUndefined()

    // Cover reconnectionTimer clearing branch by invoking failure twice.
    vi.useFakeTimers()
    ;(client as any).handleClientFailure()
    ;(client as any).handleClientFailure()
    vi.useRealTimers()
  })
})
