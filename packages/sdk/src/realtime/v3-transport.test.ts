import { afterEach, describe, expect, it, vi } from "vitest"
import type { ClientMessage } from "@inline-chat/protocol/core"
import type { InlineProtocolAuthorization } from "./v3-connection.js"
import { InlineProtocolV3Connection, InlineProtocolV3Error } from "./v3-connection.js"
import { ConnectionError_Reason } from "@inline-chat/protocol/core"
import { InlineProtocolV3Transport } from "./v3-transport.js"

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
      const rejected = new InlineProtocolV3Error("unauthorized", "cached key was forgotten")
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
      "unauthorized",
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
})
