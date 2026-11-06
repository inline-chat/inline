import { afterEach, describe, expect, it, vi } from "vitest"
import type { ClientMessage } from "@inline-chat/protocol/core"
import type { InlineProtocolAuthorization } from "./v3-connection.js"
import { InlineProtocolV3Connection, InlineProtocolV3Error } from "./v3-connection.js"
import { ConnectionError_Reason } from "@inline-chat/protocol/core"
import { InlineProtocolV3Transport } from "./v3-transport.js"
import { InlineSdkClient } from "../sdk/inline-sdk-client.js"

const authorization = (temporary: boolean): InlineProtocolAuthorization => ({
  key: new Uint8Array(256).fill(temporary ? 2 : 1),
  keyId: new Uint8Array(8).fill(temporary ? 4 : 3),
  serverSalt: 5n,
  temporary,
  ...(temporary ? { expiresAt: Math.floor(Date.now() / 1_000) + 86_400 } : {}),
})

const deferred = <T>() => {
  let resolve!: (value: T) => void
  let reject!: (error: Error) => void
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}

const fakeConnection = (temporary = authorization(true)) => {
  const close = vi.fn(async () => {})
  return {
    authorization: temporary,
    bindTemporary: vi.fn(async () => {}),
    ping: vi.fn(async () => {}),
    probeTemporaryAuthorization: vi.fn(async () => {}),
    temporaryAuthorizationNeedsRotation: vi.fn(() => false),
    invoke: vi.fn(),
    close,
  } as unknown as InlineProtocolV3Connection
}

describe("InlineProtocolV3Transport", () => {
  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it("closes a connection that finishes opening after stop", async () => {
    const pending = deferred<InlineProtocolV3Connection>()
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect").mockReturnValue(pending.promise)
    const connection = fakeConnection()
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
    })

    const start = transport.start()
    await vi.waitFor(() => expect(connect).toHaveBeenCalledOnce())
    await transport.stop()
    pending.resolve(connection)

    await expect(start).rejects.toThrow("superseded")
    expect(connection.close).toHaveBeenCalledOnce()
    expect(transport.getDiagnostics()).toMatchObject({ state: "idle", connected: false })
  })

  it("does not publish a replacement session when credential persistence fails", async () => {
    const connection = fakeConnection()
    vi.spyOn(InlineProtocolV3Connection, "connect").mockResolvedValue(connection)
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [{ modulus: "1", exponent: "3", fingerprint: "1" }],
      credentials: { permanent: authorization(false) },
      onCredentials: async () => { throw new Error("store failed") },
    })

    await expect(transport.start()).rejects.toThrow("store failed")
    expect(connection.bindTemporary).toHaveBeenCalledOnce()
    expect(connection.close).toHaveBeenCalledOnce()
    expect(transport.getDiagnostics()).toMatchObject({ state: "idle", connected: false })
  })

  it("reopens the same session owner after its active connection is stopped", async () => {
    const first = fakeConnection()
    const second = fakeConnection()
    vi.spyOn(InlineProtocolV3Connection, "connect")
      .mockResolvedValueOnce(first)
      .mockResolvedValueOnce(second)
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
    })

    await transport.start()
    await transport.stopConnection()
    await transport.reconnect({ skipDelay: true })

    expect(first.close).toHaveBeenCalledOnce()
    expect(second.probeTemporaryAuthorization).toHaveBeenCalledOnce()
    expect(transport.getDiagnostics()).toMatchObject({ state: "connected", connected: true })
    await transport.stop()
  })

  it("replaces a verified temporary authorization at the rotation boundary", async () => {
    const cached = fakeConnection()
    cached.temporaryAuthorizationNeedsRotation = vi.fn(() => true)
    const replacement = fakeConnection()
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect")
      .mockResolvedValueOnce(cached)
      .mockResolvedValueOnce(replacement)
    cached.probeTemporaryAuthorization = vi.fn(async () => {
      connect.mock.calls[0]?.[0].onRotationDue?.()
    })
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [{ modulus: "1", exponent: "3", fingerprint: "1" }],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
    })

    await transport.start()

    expect(cached.probeTemporaryAuthorization).toHaveBeenCalledOnce()
    expect(cached.close).toHaveBeenCalledOnce()
    expect(replacement.bindTemporary).toHaveBeenCalledOnce()
    expect(connect).toHaveBeenCalledTimes(2)
    await new Promise((resolve) => setTimeout(resolve, 1))
    expect(connect).toHaveBeenCalledTimes(2)
    await transport.stop()
  })

  it("regenerates after a cached temporary-key close without invalidating the transport", async () => {
    const cached = fakeConnection()
    const replacement = fakeConnection()
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect")
      .mockResolvedValueOnce(cached)
      .mockResolvedValueOnce(replacement)
    cached.probeTemporaryAuthorization = vi.fn(async () => {
      const rejected = new InlineProtocolV3Error("authorization-invalidated", "cached key was forgotten")
      connect.mock.calls[0]?.[0].onClose?.(rejected)
      throw rejected
    })
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [{ modulus: "1", exponent: "3", fingerprint: "1" }],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
    })

    await transport.start()

    expect(connect).toHaveBeenCalledTimes(2)
    expect(cached.close).toHaveBeenCalledOnce()
    expect(replacement.bindTemporary).toHaveBeenCalledOnce()
    expect(transport.getDiagnostics()).toMatchObject({ state: "connected", connected: true })
    await transport.stop()
  })

  it.each(["authorization-invalidated", "session-revoked"] as const)(
    "bounds replacement failure %s and only logs out for confirmed revocation", async (code) => {
      vi.useFakeTimers()
      const cached = fakeConnection()
      const replacement = fakeConnection()
      replacement.bindTemporary = vi.fn(async () => {
        throw new InlineProtocolV3Error(code, "replacement failed")
      })
      const connect = vi.spyOn(InlineProtocolV3Connection, "connect")
        .mockResolvedValueOnce(cached)
        .mockResolvedValueOnce(replacement)
      const transport = new InlineProtocolV3Transport({
        url: "ws://localhost/realtime/v3",
        rsaPublicKeys: [{ modulus: "1", exponent: "3", fingerprint: "1" }],
        credentials: { permanent: authorization(false), temporary: authorization(true) },
      })
      const iterator = transport.events[Symbol.asyncIterator]()
      await transport.start()
      await iterator.next()
      await iterator.next()
      connect.mock.calls[0]![0].onClose!(new InlineProtocolV3Error("authorization-invalidated", "forgotten"))
      expect((await iterator.next()).value).toEqual({ type: "connecting" })
      await vi.advanceTimersByTimeAsync(999)
      expect(connect).toHaveBeenCalledOnce()
      await vi.advanceTimersByTimeAsync(1)
      await vi.advanceTimersByTimeAsync(60_000)
      expect(connect).toHaveBeenCalledTimes(2)
      expect(replacement.bindTemporary).toHaveBeenCalledOnce()
      expect(replacement.close).toHaveBeenCalledOnce()
      expect(transport.getDiagnostics()).toMatchObject({ state: "idle", connected: false })
      await transport.reconnect({ skipDelay: true })
      expect(connect).toHaveBeenCalledTimes(2)
      await transport.events.send({ type: "stopping" })
      expect((await iterator.next()).value).toMatchObject(code === "session-revoked"
        ? { type: "message", message: { body: { connectionError: { reason: ConnectionError_Reason.SESSION_REVOKED } } } }
        : { type: "stopping" })
    },
  )

  it("coalesces live invalidation and concurrent reconnects into one replacement", async () => {
    vi.useFakeTimers()
    const cached = fakeConnection()
    const replacement = fakeConnection()
    const persisted = vi.fn()
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect")
      .mockResolvedValueOnce(cached)
      .mockResolvedValueOnce(replacement)
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [{ modulus: "1", exponent: "3", fingerprint: "1" }],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
      onCredentials: persisted,
    })
    await transport.start()
    connect.mock.calls[0]![0].onClose!(new InlineProtocolV3Error("authorization-invalidated", "forgotten"))
    await Promise.all([transport.reconnect(), transport.reconnect()])
    await vi.advanceTimersByTimeAsync(1_000)
    expect(connect).toHaveBeenCalledTimes(2)
    expect(replacement.bindTemporary).toHaveBeenCalledWith(authorization(false))
    expect(persisted).toHaveBeenCalledTimes(2)
    expect(transport.getDiagnostics()).toMatchObject({ state: "connected" })
    await transport.stop()
  })

  it.each(["connect", "bind", "probe"])("retries a transient %s failure within the recovery episode", async (phase) => {
    vi.useFakeTimers()
    const cached = fakeConnection()
    const failed = fakeConnection()
    const replacement = fakeConnection()
    const interrupted = new InlineProtocolV3Error(phase === "probe" ? "timeout" : "closed", "restart")
    if (phase === "bind") failed.bindTemporary = vi.fn().mockRejectedValue(interrupted)
    if (phase === "probe") failed.ping = vi.fn().mockRejectedValue(interrupted)
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect").mockResolvedValueOnce(cached)
    if (phase === "connect") connect.mockRejectedValueOnce(interrupted)
    else connect.mockResolvedValueOnce(failed)
    connect.mockResolvedValueOnce(replacement)
    const persist = vi.fn()
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [{ modulus: "1", exponent: "3", fingerprint: "1" }],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
      onCredentials: persist,
    })
    await transport.start()
    connect.mock.calls[0]![0].onClose!(new InlineProtocolV3Error("authorization-invalidated", "forgotten"))
    await vi.advanceTimersByTimeAsync(1_000)
    expect(connect).toHaveBeenCalledTimes(2)
    expect(transport.getDiagnostics()).toMatchObject({ state: "connecting", connected: false, recoveringAuthorization: true })
    await vi.advanceTimersByTimeAsync(999)
    expect(connect).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(1)
    expect(connect).toHaveBeenCalledTimes(3)
    expect(replacement.bindTemporary).toHaveBeenCalledOnce()
    expect(persist).toHaveBeenCalledTimes(2)
    expect(transport.getDiagnostics()).toMatchObject({ state: "connected", connected: true, recoveringAuthorization: false })
    if (phase !== "connect") expect(failed.close).toHaveBeenCalledOnce()
    await transport.stop()
  })

  it("bounds exhausted network recovery to three bootstrap attempts without logging out", async () => {
    vi.useFakeTimers()
    const cached = fakeConnection()
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect")
      .mockResolvedValueOnce(cached)
      .mockRejectedValue(new InlineProtocolV3Error("timeout", "restart continues"))
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [{ modulus: "1", exponent: "3", fingerprint: "1" }],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
    })
    const iterator = transport.events[Symbol.asyncIterator]()
    await transport.start()
    await iterator.next()
    await iterator.next()
    connect.mock.calls[0]![0].onClose!(new InlineProtocolV3Error("authorization-invalidated", "forgotten"))
    expect((await iterator.next()).value).toEqual({ type: "connecting" })
    await vi.advanceTimersByTimeAsync(3_999)
    expect(connect).toHaveBeenCalledTimes(3)
    await vi.advanceTimersByTimeAsync(1)
    expect(connect).toHaveBeenCalledTimes(4)
    expect(transport.getDiagnostics()).toMatchObject({ state: "idle", connected: false, recoveringAuthorization: false })
    await vi.advanceTimersByTimeAsync(60_000)
    expect(connect).toHaveBeenCalledTimes(4)
    await transport.events.send({ type: "stopping" })
    expect((await iterator.next()).value).toEqual({ type: "stopping" })
  })

  it("does not retry a persistence failure even when its code resembles a network timeout", async () => {
    vi.useFakeTimers()
    const cached = fakeConnection()
    const replacement = fakeConnection()
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect")
      .mockResolvedValueOnce(cached).mockResolvedValueOnce(replacement)
    const persist = vi.fn().mockResolvedValueOnce(undefined)
      .mockRejectedValue(new InlineProtocolV3Error("timeout", "store timeout"))
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [{ modulus: "1", exponent: "3", fingerprint: "1" }],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
      onCredentials: persist,
    })
    await transport.start()
    connect.mock.calls[0]![0].onClose!(new InlineProtocolV3Error("authorization-invalidated", "forgotten"))
    await vi.advanceTimersByTimeAsync(60_000)
    expect(connect).toHaveBeenCalledTimes(2)
    expect(persist).toHaveBeenCalledTimes(2)
    expect(replacement.close).toHaveBeenCalledOnce()
    expect(transport.getDiagnostics()).toMatchObject({ state: "idle", connected: false })
  })

  it.each(["backoff", "handshake", "persistence"])("manual stop fences recovery during %s", async (phase) => {
    vi.useFakeTimers()
    const cached = fakeConnection()
    const replacement = fakeConnection()
    const opening = deferred<InlineProtocolV3Connection>()
    const persisting = deferred<void>()
    const persist = vi.fn().mockResolvedValueOnce(undefined).mockImplementationOnce(() => persisting.promise)
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect")
      .mockResolvedValueOnce(cached)
      .mockReturnValueOnce(opening.promise)
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [{ modulus: "1", exponent: "3", fingerprint: "1" }],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
      onCredentials: persist,
    })
    await transport.start()
    connect.mock.calls[0]![0].onClose!(new InlineProtocolV3Error("authorization-invalidated", "forgotten"))
    if (phase !== "backoff") await vi.advanceTimersByTimeAsync(1_000)
    if (phase === "persistence") {
      opening.resolve(replacement)
      await vi.advanceTimersByTimeAsync(0)
      expect(persist).toHaveBeenCalledTimes(2)
    }
    await transport.stop()
    opening.resolve(replacement)
    persisting.resolve()
    await vi.advanceTimersByTimeAsync(60_000)
    expect(transport.getDiagnostics()).toMatchObject({ state: "idle", connected: false })
    expect(connect).toHaveBeenCalledTimes(phase === "backoff" ? 1 : 2)
    if (phase === "handshake") {
      expect(replacement.bindTemporary).not.toHaveBeenCalled()
      expect(persist).toHaveBeenCalledOnce()
    }
    if (phase !== "backoff") expect(replacement.close).toHaveBeenCalledOnce()
  })

  it("does not replace a cached key when revocation is confirmed during startup", async () => {
    const cached = fakeConnection()
    cached.probeTemporaryAuthorization = vi.fn(async () => {
      throw new InlineProtocolV3Error("session-revoked", "revoked")
    })
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect").mockResolvedValue(cached)
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [{ modulus: "1", exponent: "3", fingerprint: "1" }],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
    })
    const iterator = transport.events[Symbol.asyncIterator]()
    await transport.start()
    await iterator.next()
    expect((await iterator.next()).value).toMatchObject({ type: "message", message: {
      body: { connectionError: { reason: ConnectionError_Reason.SESSION_REVOKED } },
    } })
    expect(connect).toHaveBeenCalledOnce()
    expect(transport.getDiagnostics()).toMatchObject({ state: "idle" })
  })

  it("keeps an old account recovery from publishing after a new account takes over", async () => {
    vi.useFakeTimers()
    const old = fakeConnection()
    const stale = fakeConnection()
    const current = fakeConnection()
    const opening = deferred<InlineProtocolV3Connection>()
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect")
      .mockResolvedValueOnce(old)
      .mockReturnValueOnce(opening.promise)
      .mockResolvedValueOnce(current)
    const persistOld = vi.fn()
    const persistCurrent = vi.fn()
    const options = {
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [{ modulus: "1", exponent: "3", fingerprint: "1" }],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
    }
    const oldOwner = new InlineProtocolV3Transport({ ...options, onCredentials: persistOld })
    await oldOwner.start()
    connect.mock.calls[0]![0].onClose!(new InlineProtocolV3Error("authorization-invalidated", "forgotten"))
    await vi.advanceTimersByTimeAsync(1_000)
    await oldOwner.stop()
    const newPermanent = { ...authorization(false), keyId: new Uint8Array(8).fill(9) }
    const newOwner = new InlineProtocolV3Transport({
      ...options, credentials: { permanent: newPermanent }, onCredentials: persistCurrent,
    })
    await newOwner.start()
    opening.resolve(stale)
    await vi.advanceTimersByTimeAsync(0)
    expect(stale.bindTemporary).not.toHaveBeenCalled()
    expect(stale.close).toHaveBeenCalledOnce()
    expect(persistOld).toHaveBeenCalledOnce()
    expect(current.bindTemporary).toHaveBeenCalledWith(newPermanent)
    expect(persistCurrent).toHaveBeenCalledOnce()
    expect(newOwner.getDiagnostics()).toMatchObject({ state: "connected" })
    await newOwner.stop()
  })

  it("honors SDK connect cancellation during cached-key recovery backoff", async () => {
    vi.useFakeTimers()
    const cached = fakeConnection()
    cached.probeTemporaryAuthorization = vi.fn(async () => {
      throw new InlineProtocolV3Error("authorization-invalidated", "forgotten")
    })
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect").mockResolvedValue(cached)
    const persist = vi.fn()
    const client = new InlineSdkClient({ inlineProtocol: {
      realtimeUrl: "ws://localhost/realtime/v3",
      rsaPublicKeys: [{ modulus: "1", exponent: "3", fingerprint: "1" }],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
      onCredentials: persist,
    } })
    const controller = new AbortController()
    const opening = client.connect(controller.signal)
    const rejected = expect(opening).rejects.toThrow()
    await vi.advanceTimersByTimeAsync(0)
    expect(cached.probeTemporaryAuthorization).toHaveBeenCalledOnce()
    controller.abort()
    await vi.advanceTimersByTimeAsync(1_000)
    await rejected
    expect(connect).toHaveBeenCalledOnce()
    expect(persist).not.toHaveBeenCalled()
    await client.close()
  })

  it("does not lose an invalidation arriving while a reconnect publishes open", async () => {
    vi.useFakeTimers()
    const first = fakeConnection()
    const second = fakeConnection()
    const replacement = fakeConnection()
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect")
      .mockResolvedValueOnce(first)
      .mockResolvedValueOnce(second)
      .mockResolvedValueOnce(replacement)
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [{ modulus: "1", exponent: "3", fingerprint: "1" }],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
    })
    await transport.start()
    const send = transport.events.send.bind(transport.events)
    let invalidated = false
    vi.spyOn(transport.events, "send").mockImplementation(async (event) => {
      if (event.type === "connected" && !invalidated) {
        invalidated = true
        connect.mock.calls[1]![0].onClose!(new InlineProtocolV3Error("authorization-invalidated", "forgotten"))
      }
      await send(event)
    })
    await transport.reconnect()
    await vi.advanceTimersByTimeAsync(1_000)
    expect(connect).toHaveBeenCalledTimes(3)
    expect(replacement.bindTemporary).toHaveBeenCalledOnce()
    expect(transport.getDiagnostics()).toMatchObject({ state: "connected" })
    await transport.stop()
  })

  it("stops admission at the rotation boundary and drains the admitted RPC before reconnecting", async () => {
    const first = fakeConnection()
    const response = deferred<Awaited<ReturnType<InlineProtocolV3Connection["invoke"]>>>()
    first.invoke = vi.fn(() => response.promise)
    const second = fakeConnection()
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect")
      .mockResolvedValueOnce(first)
      .mockResolvedValueOnce(second)
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
    })

    await transport.start()
    const request = {
      id: 1n,
      seq: 0,
      body: {
        oneofKind: "rpcCall" as const,
        rpcCall: { method: 1, input: { oneofKind: undefined } },
      },
    } as ClientMessage
    const admitted = transport.send(request)
    await vi.waitFor(() => expect(first.invoke).toHaveBeenCalledOnce())

    connect.mock.calls[0]?.[0].onRotationDue?.()
    await new Promise((resolve) => setTimeout(resolve, 1))
    await expect(transport.send(request)).rejects.toMatchObject({ code: "rejected-before-execution" })
    expect(connect).toHaveBeenCalledOnce()

    response.resolve({ body: { oneofKind: "rpcResult", rpcResult: { reqMsgId: 0n, result: { oneofKind: undefined } } } })
    await admitted
    await vi.waitFor(() => expect(connect).toHaveBeenCalledTimes(2))
    await transport.stop()
  })

  it("redelivers a server-rejected request after bounded backoff without reconnecting", async () => {
    vi.useFakeTimers()
    const connection = fakeConnection()
    connection.invoke = vi.fn()
      .mockRejectedValueOnce(new InlineProtocolV3Error(
        "rejected-before-execution",
        "server overloaded before execution",
      ))
      .mockResolvedValueOnce({
        body: { oneofKind: "rpcResult", rpcResult: { reqMsgId: 0n, result: { oneofKind: undefined } } },
      })
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect").mockResolvedValue(connection)
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
    })
    await transport.start()

    const send = transport.send({
      id: 1n,
      seq: 0,
      body: {
        oneofKind: "rpcCall",
        rpcCall: { method: 1, input: { oneofKind: undefined } },
      },
    })
    await vi.waitFor(() => expect(connection.invoke).toHaveBeenCalledOnce())
    await vi.advanceTimersByTimeAsync(100)
    expect(connection.invoke).toHaveBeenCalledOnce()
    await vi.advanceTimersByTimeAsync(900)
    await send

    expect(connection.invoke).toHaveBeenCalledTimes(2)
    expect(connect).toHaveBeenCalledOnce()
    expect(transport.getDiagnostics()).toMatchObject({ state: "connected", connected: true })
    await transport.stop()
  })

  it("does not reopen after stop wins a reconnect-close race", async () => {
    const closing = deferred<void>()
    const first = fakeConnection()
    first.close = vi.fn(() => closing.promise)
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect").mockResolvedValue(first)
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
    })

    await transport.start()
    const reconnect = transport.reconnect({ skipDelay: true })
    await vi.waitFor(() => expect(first.close).toHaveBeenCalledOnce())
    await transport.stop()
    closing.resolve()
    await reconnect

    expect(connect).toHaveBeenCalledOnce()
    expect(transport.getDiagnostics()).toMatchObject({ state: "idle", connected: false })
  })

  it("reconnects immediately when the active connection closes", async () => {
    const first = fakeConnection()
    const second = fakeConnection()
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect")
      .mockResolvedValueOnce(first)
      .mockResolvedValueOnce(second)
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
    })

    await transport.start()
    const firstOptions = connect.mock.calls[0]?.[0]
    expect(firstOptions).toBeDefined()
    firstOptions?.onClose?.(new Error("socket closed"))

    await vi.waitFor(() => expect(connect).toHaveBeenCalledTimes(2))
    await vi.waitFor(() => expect(transport.getDiagnostics()).toMatchObject({
      state: "connected",
      connected: true,
    }))
    expect(first.close).toHaveBeenCalledOnce()
    await transport.stop()
  })

  it("stops reconnecting and publishes session revocation after an authenticated close", async () => {
    const connection = fakeConnection()
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect").mockResolvedValue(connection)
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
    })
    const iterator = transport.events[Symbol.asyncIterator]()
    await transport.start()
    await iterator.next()
    await iterator.next()

    connect.mock.calls[0]?.[0].onClose?.(new InlineProtocolV3Error(
      "session-revoked",
      "session revoked",
    ))

    const terminal = await iterator.next()
    expect(terminal.value).toMatchObject({
      type: "message",
      message: {
        body: {
          oneofKind: "connectionError",
          connectionError: { reason: ConnectionError_Reason.SESSION_REVOKED },
        },
      },
    })
    await new Promise((resolve) => setTimeout(resolve, 5))
    expect(connect).toHaveBeenCalledOnce()
    expect(transport.getDiagnostics()).toMatchObject({ state: "idle", connected: false })
  })

  it("queues updates received while credentials are being persisted", async () => {
    const persistence = deferred<void>()
    const connection = fakeConnection()
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect").mockResolvedValue(connection)
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
      onCredentials: () => persistence.promise,
    })
    const iterator = transport.events[Symbol.asyncIterator]()
    const start = transport.start()
    expect((await iterator.next()).value).toEqual({ type: "connecting" })
    await vi.waitFor(() => expect(connect).toHaveBeenCalledOnce())

    connect.mock.calls[0]?.[0].onUpdate?.({
      message: { payload: { oneofKind: undefined } },
    })
    persistence.resolve()
    await start

    expect((await iterator.next()).value).toEqual({ type: "connected" })
    expect((await iterator.next()).value).toMatchObject({
      type: "message",
      message: { body: { oneofKind: "message" } },
    })
    await transport.stop()
  })

  it("preserves buffered-before-live update order while publishing a connection", async () => {
    const persistence = deferred<void>()
    const connection = fakeConnection()
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect").mockResolvedValue(connection)
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
      onCredentials: () => persistence.promise,
    })
    const iterator = transport.events[Symbol.asyncIterator]()
    const start = transport.start()
    expect((await iterator.next()).value).toEqual({ type: "connecting" })
    await vi.waitFor(() => expect(connect).toHaveBeenCalledOnce())

    connect.mock.calls[0]?.[0].onUpdate?.({
      message: { payload: { oneofKind: "update", update: { updates: [{ seq: 1, date: 1n, update: { oneofKind: undefined } }] } as any } },
    })
    const connected = iterator.next()
    persistence.resolve()
    expect((await connected).value).toEqual({ type: "connected" })
    connect.mock.calls[0]?.[0].onUpdate?.({
      message: { payload: { oneofKind: "update", update: { updates: [{ seq: 2, date: 2n, update: { oneofKind: undefined } }] } as any } },
    })
    await start

    const first = await iterator.next()
    const second = await iterator.next()
    expect(first.value).toMatchObject({
      message: { body: { message: { payload: { update: { updates: [{ date: 1n }] } } } } },
    })
    expect(second.value).toMatchObject({
      message: { body: { message: { payload: { update: { updates: [{ date: 2n }] } } } } },
    })
    await transport.stop()
  })

  it("keeps a cached temporary key on transient verification failure", async () => {
    const connection = fakeConnection()
    connection.probeTemporaryAuthorization = vi.fn(async () => {
      throw new InlineProtocolV3Error("closed", "network failed")
    })
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect").mockResolvedValue(connection)
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [{ modulus: "1", exponent: "3", fingerprint: "1" }],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
    })

    await expect(transport.start()).rejects.toThrow("network failed")
    expect(connect).toHaveBeenCalledOnce()
    expect(connection.bindTemporary).not.toHaveBeenCalled()
  })

  const rpc = (id: bigint, method: number): ClientMessage => ({
    id,
    seq: 0,
    body: { oneofKind: "rpcCall", rpcCall: { method, input: { oneofKind: undefined } } },
  })
  const rpcResult = { body: { oneofKind: "rpcResult", rpcResult: { reqMsgId: 0n, result: { oneofKind: undefined } } } }
  const rsaPublicKeys = [{ modulus: "AQAB", exponent: "AQAB", fingerprint: "1" }]

  it("runs transfer RPCs on a separate transfer-only connection without delaying chat", async () => {
    const main = fakeConnection()
    const transfer = fakeConnection()
    let releaseTransfer!: () => void
    const slowTransfer = new Promise<void>((resolve) => { releaseTransfer = resolve })
    main.invoke = vi.fn(async () => rpcResult) as never
    transfer.invoke = vi.fn(async (request: { body: { oneofKind: string } }) => {
      if (request.body.oneofKind === "connectionInit") return { body: { oneofKind: "connectionOpen", connectionOpen: {} } }
      await slowTransfer
      return rpcResult
    }) as never
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect")
      .mockResolvedValueOnce(main)
      .mockResolvedValueOnce(transfer)
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys,
      credentials: { permanent: authorization(false), temporary: authorization(true) },
    })
    await transport.start()

    // 118 = SAVE_UPLOAD_PART; 2 = SEND_MESSAGE.
    const upload = transport.send(rpc(1n, 118))
    await vi.waitFor(() => expect(transfer.invoke).toHaveBeenCalledTimes(2))
    const startedAt = performance.now()
    await transport.send(rpc(2n, 2))
    expect(performance.now() - startedAt).toBeLessThan(50)
    expect(main.invoke).toHaveBeenCalledOnce()
    releaseTransfer()
    await upload

    expect(connect).toHaveBeenCalledTimes(2)
    expect(connect.mock.calls[1]![0]).toMatchObject({ temporary: true })
    expect(transfer.bindTemporary).toHaveBeenCalledOnce()
    expect((transfer.invoke as ReturnType<typeof vi.fn>).mock.calls[0]![0]).toMatchObject({
      body: { oneofKind: "connectionInit", connectionInit: { transferOnly: true } },
    })
    expect(transport.hasTransferConnection).toBe(true)
    await transport.stop()
    expect(transfer.close).toHaveBeenCalled()
  })

  it("falls back to the main connection when the transfer connection fails and closes it when idle", async () => {
    vi.useFakeTimers()
    const main = fakeConnection()
    const transfer = fakeConnection()
    main.invoke = vi.fn(async () => rpcResult) as never
    let transferCalls = 0
    transfer.invoke = vi.fn(async (request: { body: { oneofKind: string } }) => {
      if (request.body.oneofKind === "connectionInit") return { body: { oneofKind: "connectionOpen", connectionOpen: {} } }
      transferCalls += 1
      if (transferCalls === 1) throw new InlineProtocolV3Error("closed", "transfer socket dropped")
      return rpcResult
    }) as never
    const second = fakeConnection()
    second.invoke = vi.fn(async (request: { body: { oneofKind: string } }) =>
      request.body.oneofKind === "connectionInit"
        ? { body: { oneofKind: "connectionOpen", connectionOpen: {} } }
        : rpcResult) as never
    vi.spyOn(InlineProtocolV3Connection, "connect")
      .mockResolvedValueOnce(main)
      .mockResolvedValueOnce(transfer)
      .mockResolvedValueOnce(second)
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys,
      credentials: { permanent: authorization(false), temporary: authorization(true) },
    })
    await transport.start()

    // 136 = GET_FILE_PART: retried on the main connection after the transfer socket failed.
    await transport.send(rpc(1n, 136))
    expect(main.invoke).toHaveBeenCalledOnce()
    expect(transfer.close).toHaveBeenCalled()
    expect(transport.hasTransferConnection).toBe(false)

    await transport.send(rpc(2n, 136))
    expect(second.invoke).toHaveBeenCalledTimes(2)
    expect(transport.hasTransferConnection).toBe(true)
    await vi.advanceTimersByTimeAsync(110_000)
    expect(second.close).toHaveBeenCalled()
    expect(transport.hasTransferConnection).toBe(false)
    await transport.stop()
  })

  it("keeps transfer RPCs on the main connection without pinned keys for a fresh temporary key", async () => {
    const main = fakeConnection()
    main.invoke = vi.fn(async () => rpcResult) as never
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect").mockResolvedValue(main)
    const transport = new InlineProtocolV3Transport({
      url: "ws://localhost/realtime/v3",
      rsaPublicKeys: [],
      credentials: { permanent: authorization(false), temporary: authorization(true) },
    })
    await transport.start()
    await transport.send(rpc(1n, 118))
    expect(connect).toHaveBeenCalledOnce()
    expect(main.invoke).toHaveBeenCalledOnce()
    await transport.stop()
  })
})
