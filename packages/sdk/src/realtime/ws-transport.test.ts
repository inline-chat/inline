import { describe, expect, it, vi } from "vitest"
import { ClientMessage, ServerProtocolMessage } from "@inline-chat/protocol/core"

vi.mock("ws", () => {
  type Handler = (...args: any[]) => void

  const sockets: FakeWebSocket[] = []

  class FakeWebSocket {
    static OPEN = 1
    static CLOSED = 3

    static __getLast() {
      const last = sockets.at(-1)
      if (!last) throw new Error("no socket")
      return last
    }

    static __count() {
      return sockets.length
    }

    readonly url: string
    readyState = FakeWebSocket.CLOSED
    binaryType: string | undefined
    sent: Uint8Array[] = []

    private handlers = new Map<string, Handler[]>()

    constructor(url: string) {
      this.url = url
      sockets.push(this)
    }

    on(event: string, handler: Handler) {
      const arr = this.handlers.get(event) ?? []
      arr.push(handler)
      this.handlers.set(event, arr)
    }

    removeAllListeners() {
      this.handlers.clear()
    }

    send(data: Uint8Array) {
      this.sent.push(data)
    }

    close() {
      this.readyState = FakeWebSocket.CLOSED
      this.emit("close", 1000, Buffer.from(""))
    }

    emit(event: string, ...args: any[]) {
      const arr = this.handlers.get(event) ?? []
      for (const h of arr) h(...args)
    }

    __open() {
      this.readyState = FakeWebSocket.OPEN
      this.emit("open")
    }

    __message(data: any) {
      this.emit("message", data)
    }

    __error(error: any) {
      this.emit("error", error)
    }

    __close(code = 1006, reason = "") {
      this.emit("close", code, Buffer.from(reason))
    }
  }

  return { WebSocket: FakeWebSocket }
})

describe("WebSocketTransport", () => {
  it("connects, sends binary frames, and decodes messages", async () => {
    const { WebSocketTransport } = await import("./ws-transport")
    const { TransportError } = await import("./transport")
    const { WebSocket } = await import("ws")

    const transport = new WebSocketTransport({ url: "ws://example.test" })
    const iter = transport.events[Symbol.asyncIterator]()

    await transport.start()
    expect((await iter.next()).value).toEqual({ type: "connecting" })

    ;(WebSocket as any).__getLast().__open()
    expect((await iter.next()).value).toEqual({ type: "connected" })

    await expect(transport.send(ClientMessage.create({ id: 1n, seq: 1, body: { oneofKind: "ack", ack: { msgId: 1n } } }))).resolves.toBeUndefined()
    const sock = (WebSocket as any).__getLast()
    expect(sock.sent.length).toBe(1)

    const msg = ServerProtocolMessage.create({ id: 9n, body: { oneofKind: "connectionOpen", connectionOpen: {} } })

    // ArrayBuffer path
    const u = ServerProtocolMessage.toBinary(msg)
    const ab = u.buffer.slice(u.byteOffset, u.byteOffset + u.byteLength)
    sock.__message(ab)

    const decoded = await iter.next()
    expect(decoded.value.type).toBe("message")

    // Array<Buffer> path
    sock.__message([Buffer.from(ServerProtocolMessage.toBinary(msg))])
    expect((await iter.next()).value.type).toBe("message")

    // Uint8Array (non-Buffer) path
    sock.__message(new Uint8Array(ServerProtocolMessage.toBinary(msg)))
    expect((await iter.next()).value.type).toBe("message")

    // Decode failure is caught and logged (no throw).
    sock.__message(Buffer.from([1, 2, 3]))
    await expect(Promise.resolve()).resolves.toBeUndefined()

    await transport.stop()
    const stopping = await iter.next()
    expect(stopping.value.type).toBe("stopping")

    await expect(transport.send(ClientMessage.create({ id: 1n, seq: 1, body: { oneofKind: undefined } }))).rejects.toBeInstanceOf(
      TransportError,
    )
  })

  it("reconnects with backoff + jitter for later attempts", async () => {
    vi.useFakeTimers()
    const randomSpy = vi.spyOn(Math, "random").mockReturnValue(0)

    const { WebSocketTransport } = await import("./ws-transport")
    const { WebSocket } = await import("ws")

    const transport = new WebSocketTransport({ url: "ws://example.test" })
    await transport.start()
    ;(WebSocket as any).__getLast().__open()

    // Force attempt counter to >= 8 by calling reconnect repeatedly.
    for (let i = 0; i < 8; i++) {
      await transport.reconnect({ skipDelay: true })
      vi.runOnlyPendingTimers()
    }

    const before = (WebSocket as any).__count()
    await transport.reconnect()

    // With Math.random() = 0 and attempt >= 8, delay includes 0 jitter and base is capped at 8s.
    vi.advanceTimersByTime(7999)
    expect((WebSocket as any).__count()).toBe(before)

    vi.advanceTimersByTime(1)
    expect((WebSocket as any).__count()).toBe(before + 1)

    vi.useRealTimers()
    randomSpy.mockRestore()
  })

  it("does not reconnect after stop, and reconnects on socket close/error while running", async () => {
    vi.useFakeTimers()
    const randomSpy = vi.spyOn(Math, "random").mockReturnValue(0)

    const { WebSocketTransport } = await import("./ws-transport")
    const { WebSocket } = await import("ws")

    const transport = new WebSocketTransport({ url: "ws://example.test" })
    await transport.start()
    const sock1 = (WebSocket as any).__getLast()
    sock1.__open()

    // stopConnection() should clean up the current socket.
    await transport.stopConnection()
    await transport.reconnect({ skipDelay: true })
    vi.runOnlyPendingTimers()
    const sockRunning = (WebSocket as any).__getLast()
    sockRunning.__open()

    const before = (WebSocket as any).__count()
    sockRunning.__error(new Error("boom"))
    await Promise.resolve()

    // attemptNo=1 => base ~0.6s, no jitter
    await vi.advanceTimersByTimeAsync(599)
    expect((WebSocket as any).__count()).toBe(before)
    await vi.advanceTimersByTimeAsync(1)
    expect((WebSocket as any).__count()).toBe(before + 1)

    // If we stop, pending timers should not create new sockets.
    await transport.reconnect()
    await transport.stop()
    const countAtStop = (WebSocket as any).__count()
    await vi.advanceTimersByTimeAsync(10_000)
    expect((WebSocket as any).__count()).toBe(countAtStop)

    vi.useRealTimers()
    randomSpy.mockRestore()
  })

  it("reconnects on socket close while running", async () => {
    vi.useFakeTimers()
    const randomSpy = vi.spyOn(Math, "random").mockReturnValue(0)

    const { WebSocketTransport } = await import("./ws-transport")
    const { WebSocket } = await import("ws")

    const transport = new WebSocketTransport({ url: "ws://example.test" })
    await transport.start()
    const sock = (WebSocket as any).__getLast()
    sock.__open()

    const before = (WebSocket as any).__count()
    sock.__close(1006, "bye")
    await Promise.resolve()

    await vi.advanceTimersByTimeAsync(600)
    expect((WebSocket as any).__count()).toBe(before + 1)

    vi.useRealTimers()
    randomSpy.mockRestore()
  })

  it("private handlers ignore events when transport is idle / socket mismatched", async () => {
    vi.useFakeTimers()

    const { WebSocketTransport } = await import("./ws-transport")
    const { WebSocket } = await import("ws")

    const transport = new WebSocketTransport({ url: "ws://example.test" }) as any
    await transport.start()
    const sock = (WebSocket as any).__getLast()

    // Cover early return in openConnection when idle.
    await transport.stop()
    await expect(transport.openConnection()).resolves.toBeUndefined()

    // Put it back to connecting and create a new socket.
    await transport.start()
    const sock2 = (WebSocket as any).__getLast()
    expect(sock2).not.toBe(sock)

    // Calling handlers with the old socket should no-op.
    await expect(transport.connectionDidOpen(sock)).resolves.toBeUndefined()
    await expect(transport.handleClose(sock, 1000, Buffer.from("bye"))).resolves.toBeUndefined()
    await expect(transport.handleError(sock, new Error("boom"))).resolves.toBeUndefined()

    // When idle, close/error should also no-op even for the \"current\" socket.
    await transport.stop()
    transport.socket = sock2
    await expect(transport.handleClose(sock2, 1000, Buffer.from("bye"))).resolves.toBeUndefined()
    await expect(transport.handleError(sock2, new Error("boom"))).resolves.toBeUndefined()
    await expect(transport.setIdle()).resolves.toBeUndefined()

    vi.useRealTimers()
  })

  it("covers start/stop idempotency and socket/state guards", async () => {
    vi.useFakeTimers()

    const { WebSocketTransport } = await import("./ws-transport")
    const { WebSocket } = await import("ws")

    const transport = new WebSocketTransport({ url: "ws://example.test" }) as any

    // stop() while idle is a no-op.
    await transport.stop()

    await transport.start()
    const sock = (WebSocket as any).__getLast()

    // start() while not idle is a no-op.
    await transport.start()

    // Guard: connectionDidOpen should no-op when state isn't connecting.
    transport.state = "connected"
    transport.socket = sock
    await expect(transport.connectionDidOpen(sock)).resolves.toBeUndefined()

    // Guard: handleMessage should no-op when socket mismatched.
    await expect(transport.handleMessage({} as any, Buffer.from([]))).resolves.toBeUndefined()

    // Guard: reconnect timer callback should no-op when state is connected.
    await transport.reconnect({ skipDelay: true })
    sock.__open()
    transport.state = "connected"
    vi.runAllTimers()

    vi.useRealTimers()
  })

  it("rejects unsupported WebSocket message payload types", async () => {
    const { WebSocketTransport } = await import("./ws-transport")
    const transport = new WebSocketTransport({ url: "ws://example.test" })

    // Private helper exercised via bracket access to cover the defensive throw.
    expect(() => (transport as any).coerceBinary("nope")).toThrow(/Unsupported WebSocket message payload/)
  })
})
