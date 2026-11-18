import { describe, expect, it } from "vitest"
import {
  ClientMessage,
  ConnectionError_Reason,
  Method,
  ServerProtocolMessage,
  TransportPreference,
} from "@inline-chat/protocol/core"
import { TEMPORARY_KEY_ROTATION_MILLISECONDS } from "@inline-chat/protocol/secure/connection"
import type { TransportEvent } from "../types"
import { createBrowserInlineProtocolRuntime } from "./v3-browser-runtime"
import { buildConnectionInit, browserClientIdentity } from "./v3-connection-init"
import { MemoryInlineProtocolKeyStore } from "./v3-credentials"
import { upgradeBearerSession } from "./v3-session-upgrade"
import { EventRecorder, LoopbackPeer, VirtualTime, settle } from "./v3-test-peer"
import { V3Transport, v3RealtimeUrl } from "./v3-transport"

const ACCOUNT = "7"
const URL = "wss://loopback/realtime/v3"

const setup = async (options: { time?: VirtualTime } = {}) => {
  const time = options.time
  const peer = new LoopbackPeer(time ? { now: time.now } : {})
  const runtime = createBrowserInlineProtocolRuntime({
    WebSocket: peer.WebSocket,
    ...(time ? { timers: time.timers, clock: time.clock } : {}),
  })
  const keyStore = new MemoryInlineProtocolKeyStore()
  peer.validBearerTokens.add("bearer-1")
  let account: string | null = ACCOUNT
  const credentials = await upgradeBearerSession({
    url: URL, runtime, rsaPublicKeys: peer.publicKeys, keyStore,
    source: { userId: ACCOUNT, token: "bearer-1" },
    isCurrent: () => true,
  })
  const transport = new V3Transport({
    url: URL, runtime, rsaPublicKeys: peer.publicKeys, keyStore,
    accountId: () => account,
  })
  const events = new EventRecorder<TransportEvent>(transport.events)
  return {
    peer, runtime, keyStore, credentials, transport, events,
    signOut: () => { account = null },
  }
}

let nextId = 1n
const message = (body: ClientMessage["body"]) => ClientMessage.create({ id: nextId++, seq: 1, body })

const isMessage = (kind: ServerProtocolMessage["body"]["oneofKind"]) => (event: TransportEvent) =>
  event.type === "message" && event.message.body.oneofKind === kind

const identity = browserClientIdentity({
  clientVersion: "0.4.1",
  deviceId: "device-1",
  userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Chrome/141.0 Safari/537.36",
  timeZone: "Europe/Berlin",
})

describe("V3Transport", () => {
  it("upgrades a bearer session, connects, opens with the web identity, and carries RPCs, pings and updates", async () => {
    const { peer, keyStore, credentials, transport, events } = await setup()
    expect(credentials.state).toBe("bound")
    expect(credentials.accountSessionId).toBe("11")
    expect((await keyStore.get(ACCOUNT))?.temporary).toBeDefined()

    await transport.start()
    expect(events.types()).toEqual(["connecting", "connected"])
    // The cached temporary key from the upgrade is reused: no new handshake.
    expect(peer.connections.filter((connection) => connection.client.readyState === 1)).toHaveLength(1)

    const init = message({ oneofKind: "connectionInit", connectionInit: buildConnectionInit({
      token: "bearer-1", buildNumber: 42, layer: 2, supportsWorking: true, identity,
    }) })
    await transport.send(init)
    const open = await events.find(isMessage("connectionOpen"))
    expect(open.type === "message" && open.message.id).toBe(init.id)
    expect(peer.receivedInits).toHaveLength(1)
    expect(peer.receivedInits[0]).toMatchObject({
      token: "", clientType: "web", clientVersion: "0.4.1", deviceId: "device-1",
      deviceName: "Chrome on macOS", timeZone: "Europe/Berlin", supportsWorking: true, buildNumber: 42, layer: 2,
    })

    const call = message({ oneofKind: "rpcCall", rpcCall: { method: Method.GET_ME, input: { oneofKind: "getMe", getMe: {} } } })
    await transport.send(call)
    const result = await events.find(isMessage("rpcResult"))
    expect(result.type === "message" && result.message.body.oneofKind === "rpcResult" && result.message.body.rpcResult)
      .toMatchObject({ reqMsgId: call.id, result: { oneofKind: "getMe", getMe: { user: { id: 7n } } } })

    const nonce = 0xffff_ffff_ffff_fff0n // above int64 max: the V3 ping ID is its signed form
    await transport.send(message({ oneofKind: "ping", ping: { nonce } }))
    const pong = await events.find(isMessage("pong"))
    expect(pong.type === "message" && pong.message.body.oneofKind === "pong" && pong.message.body.pong.nonce).toBe(nonce)

    peer.pushUpdate({ message: { payload: { oneofKind: "update", update: { updates: [] } } } })
    const update = await events.find(isMessage("message"))
    expect(update.type === "message" && update.message.body.oneofKind === "message" && update.message.body.message.payload.oneofKind)
      .toBe("update")

    await transport.stop()
    expect(events.types().at(-1)).toBe("stopping")
    await expect(transport.send(call)).rejects.toMatchObject({ code: "not-connected" })
  }, 30_000)

  it("reports a lost connection and reconnects with a replacement temporary key after a server restart", async () => {
    const { peer, keyStore, transport, events } = await setup()
    await transport.start()
    const before = (await keyStore.get(ACCOUNT))!
    peer.restart()
    const lost = await events.find((event) => event.type === "disconnected")
    expect(lost).toEqual({ type: "disconnected", reason: "v3-closed" })
    expect(transport.state).toBe("idle")

    await transport.start()
    expect(events.types().slice(-2)).toEqual(["connecting", "connected"])
    const after = (await keyStore.get(ACCOUNT))!
    expect(after.permanent.keyId).toEqual(before.permanent.keyId)
    expect(after.temporary!.keyId).not.toEqual(before.temporary!.keyId)

    const call = message({ oneofKind: "rpcCall", rpcCall: { method: Method.GET_ME, input: { oneofKind: "getMe", getMe: {} } } })
    await transport.send(call)
    await events.find((event) => event.type === "message" && event.message.body.oneofKind === "rpcResult" &&
      event.message.body.rpcResult.reqMsgId === call.id)
    await transport.stop()
  }, 30_000)

  it("rotates the temporary key at the authenticated rotation boundary on a virtual clock", async () => {
    const time = new VirtualTime()
    const { peer, keyStore, transport, events } = await setup({ time })
    await transport.start()
    expect(events.types()).toEqual(["connecting", "connected"])
    const first = (await keyStore.get(ACCOUNT))!.temporary!
    const boundary = first.expiresAt! * 1_000 - TEMPORARY_KEY_ROTATION_MILLISECONDS

    await time.advance(boundary - time.now() - 60_000)
    expect(events.types()).toEqual(["connecting", "connected"])

    await time.advance(120_000)
    expect(events.events.at(-1)).toEqual({ type: "disconnected", reason: "v3-temporary-key-rotation" })
    const connectionsBefore = peer.connections.length
    // The connection manager restarts the transport; the due key is not probed again.
    const restarted = transport.start()
    await time.advance(0)
    await restarted
    expect(events.types().slice(-2)).toEqual(["connecting", "connected"])
    expect(peer.connections.length).toBe(connectionsBefore + 1)
    const second = (await keyStore.get(ACCOUNT))!.temporary!
    expect(second.keyId).not.toEqual(first.keyId)
    expect(second.expiresAt!).toBeGreaterThan(first.expiresAt!)
    await transport.stop()
  }, 30_000)

  it("holds admission at the boundary and rotates once the in-flight request settles", async () => {
    const time = new VirtualTime()
    const { peer, keyStore, transport, events } = await setup({ time })
    await transport.start()
    const first = (await keyStore.get(ACCOUNT))!.temporary!
    const boundary = first.expiresAt! * 1_000 - TEMPORARY_KEY_ROTATION_MILLISECONDS
    await time.advance(boundary - time.now() - 10_000)

    let release = () => {}
    peer.rpcGate = new Promise<void>((resolve) => { release = resolve })
    const inFlight = message({ oneofKind: "rpcCall", rpcCall: { method: Method.GET_ME, input: { oneofKind: "getMe", getMe: {} } } })
    await transport.send(inFlight)
    await time.advance(20_000)
    // Past the boundary with a request in flight: still connected, but no new admissions.
    expect(events.types()).toEqual(["connecting", "connected"])
    const refused = message({ oneofKind: "rpcCall", rpcCall: { method: Method.GET_ME, input: { oneofKind: "getMe", getMe: {} } } })
    await expect(transport.send(refused)).rejects.toMatchObject({ code: "not-connected" })

    release()
    peer.rpcGate = undefined
    const result = await events.find(isMessage("rpcResult"))
    expect(result.type === "message" && result.message.body.oneofKind === "rpcResult" && result.message.body.rpcResult.reqMsgId)
      .toBe(inFlight.id)
    await events.find((event) => event.type === "disconnected")
    expect(events.events.at(-1)).toEqual({ type: "disconnected", reason: "v3-temporary-key-rotation" })
  }, 30_000)

  it("does not trust a revocation close on a live connection: it erases nothing, rechecks with a new temporary key and reconnects", async () => {
    const { peer, keyStore, transport, events } = await setup()
    await transport.start()
    const before = (await keyStore.get(ACCOUNT))!
    // The close frame is outside V3's cryptography: anyone who can intercept the TLS stream can send it.
    peer.closeLast(4401, "session_revoked_confirmed")
    const lost = await events.find((event) => event.type === "disconnected")
    expect(lost).toEqual({ type: "disconnected", reason: "v3-authorization-recheck" })
    expect(events.events.some(isMessage("connectionError"))).toBe(false)
    const kept = (await keyStore.get(ACCOUNT))!
    expect(kept.state).toBe("bound")
    expect(kept.permanent.keyId).toEqual(before.permanent.keyId)

    // The server never revoked anything: the recheck binds a new temporary key and the session carries on.
    const connections = peer.connections.length
    await transport.start()
    expect(events.types().slice(-2)).toEqual(["connecting", "connected"])
    expect(peer.connections.length).toBe(connections + 1)
    expect((await keyStore.get(ACCOUNT))!.temporary!.keyId).not.toEqual(before.temporary!.keyId)
    await transport.stop()
  }, 30_000)

  it("stops without erasing when the server answers the recheck binding with a revocation", async () => {
    const { peer, keyStore, transport, events } = await setup()
    await transport.start()
    peer.revokePermanentKeys()
    peer.closeLast(4401, "session_revoked_confirmed")
    await events.find((event) => event.type === "disconnected")

    await transport.start()
    const stopped = await events.find(isMessage("connectionError"))
    // Re-authentication, not sign-out: only a revocation inside an authenticated record may erase.
    expect(stopped.type === "message" && stopped.message.body.oneofKind === "connectionError" &&
      stopped.message.body.connectionError.reason).toBe(ConnectionError_Reason.INVALID_AUTH)
    expect(events.events.at(-1)).toEqual({ type: "disconnected", reason: "v3-session-revoked" })
    expect(events.events.some((event) => event.type === "message" && event.message.body.oneofKind === "connectionError" &&
      event.message.body.connectionError.reason === ConnectionError_Reason.SESSION_REVOKED)).toBe(false)
    expect((await keyStore.get(ACCOUNT))?.state).toBe("bound")
  }, 30_000)

  it("rechecks instead of revoking when the cached key's probe is answered with a revocation close", async () => {
    const { peer, keyStore, transport, events } = await setup()
    const before = (await keyStore.get(ACCOUNT))!
    // Whoever sits on the wire closes the probe connection with the revocation reason; the server would not have.
    peer.silent = true
    const started = transport.start()
    await expect.poll(() => peer.openConnections).toBe(1)
    peer.silent = false
    peer.closeLast(4401, "session_revoked_confirmed")
    await started
    expect(events.types().slice(-2)).toEqual(["connecting", "connected"])
    expect(events.events.some(isMessage("connectionError"))).toBe(false)
    const after = (await keyStore.get(ACCOUNT))!
    expect(after.permanent.keyId).toEqual(before.permanent.keyId)
    expect(after.temporary!.keyId).not.toEqual(before.temporary!.keyId)
    await transport.stop()
  }, 30_000)

  it("does not connect without bound credentials, and erase on sign-out is final", async () => {
    const { keyStore, transport, events, credentials, signOut } = await setup()
    const permanentKey = credentials.permanent.key
    await keyStore.erase(ACCOUNT)
    expect(await keyStore.get(ACCOUNT)).toBeUndefined()
    // The store's own copy is wiped; callers' copies are theirs.
    expect(permanentKey.some((byte) => byte !== 0)).toBe(true)
    await transport.start()
    expect(events.events.at(-1)).toEqual({ type: "disconnected", reason: "v3-no-credentials" })
    signOut()
    await transport.start()
    expect(events.events.at(-1)).toEqual({ type: "disconnected", reason: "v3-no-credentials" })
  }, 30_000)

  it("relays the server's transport preference in the open", async () => {
    const { peer, transport, events } = await setup()
    peer.preference = TransportPreference.LEGACY
    await transport.start()
    await transport.send(message({ oneofKind: "connectionInit", connectionInit: buildConnectionInit({ token: "bearer-1" }) }))
    const open = await events.find(isMessage("connectionOpen"))
    expect(open.type === "message" && open.message.body.oneofKind === "connectionOpen" &&
      open.message.body.connectionOpen.upgradedSessionTransport).toBe(TransportPreference.LEGACY)
    await transport.stop()
    await settle()
  }, 30_000)
})

describe("v3RealtimeUrl", () => {
  it("derives the V3 path from the V2 realtime URL", () => {
    expect(v3RealtimeUrl("wss://api.inline.chat/realtime")).toBe("wss://api.inline.chat/realtime/v3")
    expect(v3RealtimeUrl("ws://localhost:8000/realtime/")).toBe("ws://localhost:8000/realtime/v3")
  })
})
