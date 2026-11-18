import { describe, expect, it } from "vitest"
import { ClientMessage, ConnectionError_Reason, ServerProtocolMessage, TransportPreference } from "@inline-chat/protocol/core"
import type { TransportEvent } from "../types"
import { MockTransport } from "./mock-transport"
import { MemoryTransportPreferenceStore, NegotiatingTransport } from "./negotiating-transport"
import { createBrowserInlineProtocolRuntime } from "./v3-browser-runtime"
import { buildConnectionInit } from "./v3-connection-init"
import { MemoryInlineProtocolKeyStore } from "./v3-credentials"
import { V3SessionUpgrader, upgradeBearerSession } from "./v3-session-upgrade"
import { EventRecorder, LoopbackPeer, VirtualTime, settle } from "./v3-test-peer"
import { V3Transport } from "./v3-transport"

const ACCOUNT = "7"
const URL = "wss://loopback/realtime/v3"

const connectionOpen = (upgradedSessionTransport?: TransportPreference) => ServerProtocolMessage.create({
  body: { oneofKind: "connectionOpen", connectionOpen: upgradedSessionTransport === undefined ? {} : { upgradedSessionTransport } },
})

const setup = async (options: {
  bearer?: boolean
  bound?: boolean
  time?: VirtualTime
  upgrade?: { start(): void; stop(): Promise<void> }
} = {}) => {
  const time = options.time
  const peer = new LoopbackPeer(time ? { now: time.now } : {})
  const runtime = createBrowserInlineProtocolRuntime({
    WebSocket: peer.WebSocket,
    ...(time ? { timers: time.timers, clock: time.clock } : {}),
  })
  const keyStore = new MemoryInlineProtocolKeyStore()
  peer.validBearerTokens.add("bearer-1")
  if (options.bound !== false) {
    await upgradeBearerSession({
      url: URL, runtime, rsaPublicKeys: peer.publicKeys, keyStore,
      source: { userId: ACCOUNT, token: "bearer-1" }, isCurrent: () => true,
    })
  }
  const v2: MockTransport[] = []
  const v3: V3Transport[] = []
  const preference = new MemoryTransportPreferenceStore()
  const bearer = options.bearer ?? true
  const transport = new NegotiatingTransport({
    createV3: () => {
      const child = new V3Transport({ url: URL, runtime, rsaPublicKeys: peer.publicKeys, keyStore, accountId: () => ACCOUNT })
      v3.push(child)
      return child
    },
    createV2: () => {
      const child = new MockTransport()
      v2.push(child)
      return child
    },
    hasV3Credentials: async () => (await keyStore.get(ACCOUNT))?.state === "bound",
    hasBearer: () => bearer,
    preference,
    ...(options.upgrade ? { upgrade: options.upgrade } : {}),
    ...(time ? { timers: time.timers, clock: time.clock } : {}),
  })
  const events = new EventRecorder<TransportEvent>(transport.events)
  return { peer, runtime, keyStore, transport, events, v2, v3, preference }
}

const init = () => ClientMessage.create({
  id: 1n, seq: 1, body: { oneofKind: "connectionInit", connectionInit: buildConnectionInit({ token: "bearer-1" }) },
})

describe("NegotiatingTransport", () => {
  it("uses V3 for a session with bound credentials", async () => {
    const { transport, events, v2, v3 } = await setup()
    await transport.start()
    expect(transport.activeKind).toBe("v3")
    expect(events.types()).toEqual(["connecting", "connected"])
    await transport.send(init())
    await events.find((event) => event.type === "message" && event.message.body.oneofKind === "connectionOpen")
    expect(v3).toHaveLength(1)
    expect(v2).toHaveLength(0)
    await transport.stop()
    expect(events.types().at(-1)).toBe("stopping")
  }, 30_000)

  it("falls back to V2 inside the same start when V3 is refused, and keeps V2 for the cooldown", async () => {
    const { peer, transport, events, v2, v3 } = await setup()
    peer.refuse = true
    await transport.start()
    await settle()
    expect(transport.activeKind).toBe("v2")
    expect(v2).toHaveLength(1)
    // The V3 failure never reaches the session as a disconnect.
    expect(events.types()).toEqual(["connecting", "connecting"])
    await v2[0]!.connect()
    await v2[0]!.emitMessage(connectionOpen())
    await events.find((event) => event.type === "message")
    expect(events.types()).toEqual(["connecting", "connecting", "connected", "message"])

    await v2[0]!.disconnect()
    await events.find((event) => event.type === "disconnected")
    peer.refuse = false
    await transport.start()
    expect(transport.activeKind).toBe("v2")
    expect(v3).toHaveLength(1)
    await transport.stop()
  }, 30_000)

  it("falls back to V2 when a V3 start exceeds the deadline", async () => {
    const time = new VirtualTime()
    const { peer, transport, events, v2 } = await setup({ time })
    peer.silent = true
    void transport.start()
    await time.advance(5_000)
    expect(transport.activeKind).toBe("v3")
    await time.advance(1_500)
    expect(transport.activeKind).toBe("v2")
    expect(v2).toHaveLength(1)
    expect(events.types()).toEqual(["connecting", "connecting"])
    await transport.stop()
    await time.advance(120_000)
  }, 30_000)

  it("does not fall back for a session without a bearer", async () => {
    const { peer, transport, events, v2 } = await setup({ bearer: false })
    peer.refuse = true
    await transport.start()
    await events.find((event) => event.type === "disconnected")
    expect(v2).toHaveLength(0)
    expect(transport.activeKind).toBe("v3")
  }, 30_000)

  it("never answers a V3 authorization question with V2: a revocation close keeps a bearer session on V3", async () => {
    const { peer, transport, events, v2, v3 } = await setup()
    await transport.start()
    expect(transport.activeKind).toBe("v3")
    // Live close claiming revocation: a recheck on V3, not a move to V2.
    peer.closeLast(4401, "session_revoked_confirmed")
    await events.find((event) => event.type === "disconnected")
    await transport.start()
    expect(transport.activeKind).toBe("v3")
    expect(events.types().slice(-2)).toEqual(["connecting", "connected"])

    // The server answers the next binding with a revocation: the session stops on V3 for re-authentication.
    peer.revokePermanentKeys()
    const lost = events.next((event) => event.type === "disconnected")
    peer.closeLast(4401, "session_revoked_confirmed")
    await lost
    await transport.start()
    const rejected = await events.find((event) => event.type === "message" && event.message.body.oneofKind === "connectionError")
    expect(rejected.type === "message" && rejected.message.body.oneofKind === "connectionError" &&
      rejected.message.body.connectionError.reason).toBe(ConnectionError_Reason.INVALID_AUTH)
    await settle()
    expect(v2).toHaveLength(0)
    expect(v3).toHaveLength(1)
    expect(transport.activeKind).toBe("v3")
    await transport.stop()
  }, 30_000)

  it("uses V2 without V3 credentials and starts the session upgrade after the V2 open", async () => {
    let upgrades = 0
    const { transport, events, v2, preference } = await setup({
      bound: false,
      upgrade: { start: () => { upgrades += 1 }, stop: async () => {} },
    })
    preference.record(true)
    await transport.start()
    expect(transport.activeKind).toBe("v2")
    await v2[0]!.connect()
    expect(upgrades).toBe(0)
    await v2[0]!.emitMessage(connectionOpen(TransportPreference.V3))
    await events.find((event) => event.type === "message")
    await settle()
    expect(upgrades).toBe(1)
    expect(preference.prefersLegacy()).toBe(false)
    await transport.stop()
  }, 30_000)

  it("honors the operator's LEGACY preference from a V3 open by moving to V2 on the next start", async () => {
    const { peer, transport, events, preference } = await setup()
    peer.preference = TransportPreference.LEGACY
    await transport.start()
    expect(transport.activeKind).toBe("v3")
    await transport.send(init())
    const lost = await events.find((event) => event.type === "disconnected")
    expect(lost).toEqual({ type: "disconnected", reason: "transport_preference" })
    // The open that carried the rollback is not delivered as a usable session.
    expect(events.events.some((event) => event.type === "message")).toBe(false)
    expect(preference.prefersLegacy()).toBe(true)
    await transport.start()
    expect(transport.activeKind).toBe("v2")
    await transport.stop()
  }, 30_000)

  it("upgrades a bearer session in the background over V2, then selects V3", async () => {
    const peer = new LoopbackPeer()
    peer.validBearerTokens.add("bearer-1")
    const runtime = createBrowserInlineProtocolRuntime({ WebSocket: peer.WebSocket })
    const keyStore = new MemoryInlineProtocolKeyStore()
    const upgrader = new V3SessionUpgrader({
      url: URL, runtime, rsaPublicKeys: peer.publicKeys, keyStore,
      source: () => ({ userId: ACCOUNT, token: "bearer-1" }),
    })
    const v2: MockTransport[] = []
    const transport = new NegotiatingTransport({
      createV3: () => new V3Transport({ url: URL, runtime, rsaPublicKeys: peer.publicKeys, keyStore, accountId: () => ACCOUNT }),
      createV2: () => {
        const child = new MockTransport()
        v2.push(child)
        return child
      },
      hasV3Credentials: async () => (await keyStore.get(ACCOUNT))?.state === "bound",
      hasBearer: () => true,
      upgrade: upgrader,
    })
    const events = new EventRecorder<TransportEvent>(transport.events)
    await transport.start()
    expect(transport.activeKind).toBe("v2")
    await v2[0]!.connect()
    await v2[0]!.emitMessage(connectionOpen())
    await events.find((event) => event.type === "message")
    await settle()
    await upgrader.settled()
    const stored = await keyStore.get(ACCOUNT)
    expect(stored?.state).toBe("bound")
    expect(stored?.accountSessionId).toBe("11")
    // The bearer travels only inside the encrypted carrier; nothing else was sent in the clear.
    await v2[0]!.disconnect()
    await events.find((event) => event.type === "disconnected")
    await transport.start()
    expect(transport.activeKind).toBe("v3")
    expect(events.types().slice(-2)).toEqual(["connecting", "connected"])
    await transport.stop()
  }, 30_000)

  it("leaves a declined upgrade unbound and quiet until the retry delay", async () => {
    const peer = new LoopbackPeer()
    peer.declineUpgrade = 1
    const runtime = createBrowserInlineProtocolRuntime({ WebSocket: peer.WebSocket })
    const keyStore = new MemoryInlineProtocolKeyStore()
    const upgrader = new V3SessionUpgrader({
      url: URL, runtime, rsaPublicKeys: peer.publicKeys, keyStore,
      source: () => ({ userId: ACCOUNT, token: "bearer-1" }),
    })
    upgrader.start()
    await upgrader.settled()
    // The staged key stays, so a later attempt proves the same key instead of minting another.
    const staged = await keyStore.get(ACCOUNT)
    expect(staged?.state).toBe("staged")
    const connections = peer.connections.length
    upgrader.start()
    await upgrader.settled()
    expect(peer.connections.length).toBe(connections)
  }, 30_000)
})
