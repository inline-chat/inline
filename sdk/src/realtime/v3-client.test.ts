import { afterEach, describe, expect, it, vi } from "vitest"
import type { RpcCall, RpcResult } from "@inline-chat/protocol/core"
import {
  InlineProtocolV3Connection,
  InlineProtocolV3Error,
  type InlineProtocolAuthorization,
  type InlineProtocolV3ConnectionOptions,
} from "./v3-connection.js"
import { InlineRealtimeV3Client } from "./v3-client.js"

const authorization = (temporary: boolean, marker: number): InlineProtocolAuthorization => ({
  key: new Uint8Array(256).fill(marker),
  keyId: new Uint8Array(8).fill(marker),
  serverSalt: BigInt(marker),
  temporary,
  ...(temporary ? { expiresAt: 2_000_000_000 } : {}),
})

const fakeConnection = (
  auth: InlineProtocolAuthorization,
  callRpc = vi.fn<() => Promise<RpcResult["result"]>>().mockResolvedValue({ oneofKind: undefined }),
) => ({
  authorization: auth,
  ping: vi.fn().mockResolvedValue(undefined),
  probeTemporaryAuthorization: vi.fn().mockResolvedValue(undefined),
  temporaryAuthorizationNeedsRotation: vi.fn().mockReturnValue(false),
  bindTemporary: vi.fn().mockResolvedValue(undefined),
  callRpc,
  createHttpUpload: vi.fn(),
  finishHttpUpload: vi.fn(),
  close: vi.fn().mockResolvedValue(undefined),
}) as unknown as InlineProtocolV3Connection

describe("InlineRealtimeV3Client temporary-key rotation", () => {
  afterEach(() => vi.restoreAllMocks())

  it("drains an admitted direct RPC before replacing the temporary session", async () => {
    let resolveRpc: ((result: RpcResult["result"]) => void) | undefined
    const admittedRpc = new Promise<RpcResult["result"]>((resolve) => { resolveRpc = resolve })
    const oldCallRpc = vi.fn().mockReturnValue(admittedRpc)
    const permanent = authorization(false, 1)
    const oldSession = fakeConnection(authorization(true, 2), oldCallRpc)
    const newResult = { oneofKind: undefined } as RpcResult["result"]
    const newCallRpc = vi.fn().mockResolvedValue(newResult)
    const newSession = fakeConnection(authorization(true, 3), newCallRpc)
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect")
      .mockResolvedValueOnce(oldSession)
      .mockResolvedValueOnce(newSession)
    const client = new InlineRealtimeV3Client({
      url: "ws://inline.test/realtime/v3",
      rsaPublicKeys: [],
    })

    await client.connect({ permanent, temporary: oldSession.authorization })
    const inFlight = client.callRpc({} as RpcCall)
    await vi.waitFor(() => expect(oldCallRpc).toHaveBeenCalledOnce())
    const options = connect.mock.calls[0]?.[0] as InlineProtocolV3ConnectionOptions
    options.onRotationDue?.()
    await Promise.resolve()

    expect(oldSession.close).not.toHaveBeenCalled()
    expect(newSession.bindTemporary).not.toHaveBeenCalled()

    const oldResult = { oneofKind: undefined } as RpcResult["result"]
    resolveRpc?.(oldResult)
    await expect(inFlight).resolves.toBe(oldResult)
    await vi.waitFor(() => expect(newSession.bindTemporary).toHaveBeenCalledWith(permanent))
    expect(oldSession.close).toHaveBeenCalledOnce()

    await expect(client.callRpc({} as RpcCall)).resolves.toBe(newResult)
    expect(newCallRpc).toHaveBeenCalledOnce()
    await client.close()
  })

  it("replaces an authenticated-rejected cached temporary key once and persists before open", async () => {
    const permanent = authorization(false, 1)
    const cached = fakeConnection(authorization(true, 2))
    cached.probeTemporaryAuthorization = vi.fn().mockRejectedValue(
      new InlineProtocolV3Error("unauthorized", "cached key is unknown"),
    )
    const replacement = fakeConnection(authorization(true, 3))
    vi.spyOn(InlineProtocolV3Connection, "connect")
      .mockResolvedValueOnce(cached)
      .mockResolvedValueOnce(replacement)
    let client: InlineRealtimeV3Client
    const onCredentials = vi.fn(async (credentials) => {
      expect(client.authenticated).toBe(false)
      expect(credentials.temporary?.key[0]).toBe(3)
    })
    client = new InlineRealtimeV3Client({
      url: "ws://inline.test/realtime/v3",
      rsaPublicKeys: [],
      onCredentials,
    })

    await client.connect({ permanent, temporary: cached.authorization })

    expect(cached.close).toHaveBeenCalled()
    expect(replacement.bindTemporary).toHaveBeenCalledWith(permanent)
    expect(onCredentials).toHaveBeenCalledOnce()
    expect(client.authenticated).toBe(true)
    expect(client.credentials?.temporary?.key[0]).toBe(3)
    await client.close()
  })

  it("does not replace a cached temporary key after a transient probe failure", async () => {
    const permanent = authorization(false, 1)
    const cached = fakeConnection(authorization(true, 2))
    cached.probeTemporaryAuthorization = vi.fn().mockRejectedValue(
      new InlineProtocolV3Error("closed", "network failed"),
    )
    const connect = vi.spyOn(InlineProtocolV3Connection, "connect").mockResolvedValueOnce(cached)
    const client = new InlineRealtimeV3Client({
      url: "ws://inline.test/realtime/v3",
      rsaPublicKeys: [],
    })

    await expect(client.connect({ permanent, temporary: cached.authorization }))
      .rejects.toMatchObject({ code: "closed" })
    expect(connect).toHaveBeenCalledOnce()
    expect(client.authenticated).toBe(false)
  })

  it("does not publish a replacement session when credential persistence fails", async () => {
    const permanent = authorization(false, 1)
    const replacement = fakeConnection(authorization(true, 3))
    vi.spyOn(InlineProtocolV3Connection, "connect").mockResolvedValueOnce(replacement)
    const client = new InlineRealtimeV3Client({
      url: "ws://inline.test/realtime/v3",
      rsaPublicKeys: [],
      onCredentials: async () => { throw new Error("disk unavailable") },
    })

    await expect(client.connect({ permanent })).rejects.toThrow("disk unavailable")
    expect(replacement.close).toHaveBeenCalledOnce()
    expect(client.authenticated).toBe(false)
    expect(client.credentials?.temporary).toBeUndefined()
  })
})
