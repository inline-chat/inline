import {
  ConnectionError_Reason,
  ServerProtocolMessage,
  type ClientMessage,
} from "@inline-chat/protocol/core"
import { ProtocolClient } from "../client/protocol-client"
import { MockTransport } from "../transport/mock-transport"
import { ConnectionManager } from "./connection-manager"
import { describe, expect, it, vi } from "vitest"

const waitFor = async (
  predicate: () => boolean,
  timeoutMs = 300,
) => {
  const started = Date.now()
  while (Date.now() - started < timeoutMs) {
    if (predicate()) return
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
  throw new Error("Timed out waiting for connection state")
}

const createConnection = (options?: {
  authTimeoutMs?: number
  backgroundGraceMs?: number
  wakeProbeTimeoutMs?: number
  backoffDelayMs?: (attempt: number) => number
}) => {
  const transport = new MockTransport()
  const session = new ProtocolClient({
    transport,
    getConnectionInit: () => ({
      token: "token",
      layer: 2,
    }),
  })
  const manager = new ConnectionManager({
    session,
    authTimeoutMs: options?.authTimeoutMs,
    backgroundGraceMs: options?.backgroundGraceMs,
    wakeProbeTimeoutMs: options?.wakeProbeTimeoutMs,
    backoffDelayMs: options?.backoffDelayMs,
  })
  return { transport, session, manager }
}

class FailConnectionInitTransport extends MockTransport {
  override async send(message: ClientMessage) {
    if (message.body.oneofKind === "connectionInit") {
      throw new Error("socket write failed")
    }
    await super.send(message)
  }
}

const openConnection = async (
  context: ReturnType<typeof createConnection>,
) => {
  await context.manager.start()
  await context.transport.connect()
  await context.transport.emitMessage(
    ServerProtocolMessage.create({
      body: {
        oneofKind: "connectionOpen",
        connectionOpen: {},
      },
    }),
  )
  await waitFor(() => context.manager.state === "open")
}

describe("ConnectionManager", () => {
  it("coalesces repeated disconnect signals into one backoff attempt", async () => {
    const context = createConnection({
      backoffDelayMs: () => 20,
    })
    const starts = vi.spyOn(context.transport, "start")

    await context.manager.start()
    await context.transport.disconnect("network")
    await context.transport.events.send({
      type: "disconnected",
      reason: "duplicate-close",
    })

    await waitFor(() => context.manager.state === "backoff")
    expect(starts).toHaveBeenCalledTimes(1)
    await waitFor(() => starts.mock.calls.length === 2)
    expect(starts).toHaveBeenCalledTimes(2)
    await context.manager.stop()
  })

  it("backs off an application transport failure instead of reconnecting immediately", async () => {
    const context = createConnection({
      backoffDelayMs: () => 40,
    })
    const starts = vi.spyOn(context.transport, "start")

    await openConnection(context)
    await context.manager.reconnectAfterFailure("rpc-send-failed")

    expect(context.manager.state).toBe("backoff")
    expect(starts).toHaveBeenCalledTimes(1)
    await new Promise((resolve) => setTimeout(resolve, 15))
    expect(starts).toHaveBeenCalledTimes(1)

    await waitFor(() => starts.mock.calls.length === 2)
    expect(context.manager.state).toBe("connectingTransport")
    await context.manager.stop()
  })

  it("owns authentication timeout and starts one replacement attempt", async () => {
    const context = createConnection({
      authTimeoutMs: 10,
      backoffDelayMs: () => 0,
    })
    const starts = vi.spyOn(context.transport, "start")

    await context.manager.start()
    await context.transport.connect()
    await waitFor(
      () =>
        context.transport.sent.some(
          (message) =>
            message.body.oneofKind === "connectionInit",
        ),
    )
    await waitFor(() => starts.mock.calls.length === 2)

    expect(context.manager.state).toBe(
      "connectingTransport",
    )
    await context.manager.stop()
  })

  it("waits for new credentials after a server auth rejection", async () => {
    const context = createConnection({
      backoffDelayMs: () => 0,
    })
    const starts = vi.spyOn(context.transport, "start")

    await context.manager.start()
    await context.transport.connect()
    await context.transport.emitMessage(
      ServerProtocolMessage.create({
        body: {
          oneofKind: "connectionError",
          connectionError: {
            reason: ConnectionError_Reason.INVALID_AUTH,
          },
        },
      }),
    )
    await waitFor(
      () =>
        context.manager.state ===
        "waitingForConstraints",
    )
    await new Promise((resolve) => setTimeout(resolve, 15))

    expect(context.manager.constraints.authAvailable).toBe(
      false,
    )
    expect(starts).toHaveBeenCalledTimes(1)
    await context.manager.stop()
  })

  it("retries a failed connection-init write without invalidating auth", async () => {
    const transport = new FailConnectionInitTransport()
    const session = new ProtocolClient({
      transport,
      getConnectionInit: () => ({
        token: "valid-token",
        layer: 2,
      }),
    })
    const manager = new ConnectionManager({
      session,
      backoffDelayMs: () => 0,
    })
    const starts = vi.spyOn(transport, "start")

    await manager.start()
    await transport.connect()
    await waitFor(() => starts.mock.calls.length === 2)

    expect(manager.constraints.authAvailable).toBe(true)
    expect(manager.state).toBe("connectingTransport")
    await manager.stop()
  })

  it("cancels pending retry when stopped", async () => {
    const context = createConnection({
      backoffDelayMs: () => 30,
    })
    const starts = vi.spyOn(context.transport, "start")

    await context.manager.start()
    await context.transport.disconnect("offline")
    await waitFor(() => context.manager.state === "backoff")
    await context.manager.stop()
    await new Promise((resolve) => setTimeout(resolve, 45))

    expect(starts).toHaveBeenCalledTimes(1)
    expect(context.manager.state).toBe("stopped")
  })

  it("stops retrying while offline and resumes once online", async () => {
    const context = createConnection({
      backoffDelayMs: () => 15,
    })
    const starts = vi.spyOn(context.transport, "start")

    await context.manager.start()
    await context.transport.disconnect("network")
    await waitFor(() => context.manager.state === "backoff")
    await context.manager.setNetworkAvailable(false)
    await new Promise((resolve) => setTimeout(resolve, 25))

    expect(context.manager.state).toBe(
      "waitingForConstraints",
    )
    expect(starts).toHaveBeenCalledTimes(1)

    await context.manager.setNetworkAvailable(true)
    await waitFor(() => starts.mock.calls.length === 2)
    expect(context.manager.state).toBe(
      "connectingTransport",
    )
    await context.manager.stop()
  })

  it("keeps an open connection during background grace", async () => {
    const context = createConnection({
      backgroundGraceMs: 20,
    })
    await openConnection(context)

    await context.manager.setAppActive(false)
    await new Promise((resolve) => setTimeout(resolve, 5))
    expect(context.manager.state).toBe("open")

    await context.manager.setAppActive(true)
    await new Promise((resolve) => setTimeout(resolve, 25))
    expect(context.manager.state).toBe("open")
    expect(context.transport.state).toBe("connected")
    await context.manager.stop()
  })

  it("suspends after background grace and reconnects on foreground", async () => {
    const context = createConnection({
      backgroundGraceMs: 10,
    })
    const starts = vi.spyOn(context.transport, "start")
    await openConnection(context)

    await context.manager.setAppActive(false)
    await waitFor(
      () => context.manager.state === "backgroundSuspended",
    )
    expect(context.transport.state).toBe("idle")
    expect(starts).toHaveBeenCalledTimes(1)

    await context.manager.setAppActive(true)
    await waitFor(() => starts.mock.calls.length === 2)
    expect(context.manager.state).toBe(
      "connectingTransport",
    )
    await context.manager.stop()
  })

  it("uses a wake pong to preserve a healthy open connection", async () => {
    const context = createConnection({
      wakeProbeTimeoutMs: 15,
    })
    const starts = vi.spyOn(context.transport, "start")
    await openConnection(context)

    await context.manager.systemDidWake()
    await waitFor(() =>
      context.transport.sent.some(
        (message) => message.body.oneofKind === "ping",
      ),
    )
    const pings = context.transport.sent.filter(
      (message) => message.body.oneofKind === "ping",
    )
    const ping = pings[pings.length - 1]
    if (ping?.body.oneofKind !== "ping") {
      throw new Error("Expected wake probe ping")
    }
    await context.transport.emitMessage(
      ServerProtocolMessage.create({
        body: {
          oneofKind: "pong",
          pong: { nonce: ping.body.ping.nonce },
        },
      }),
    )
    await new Promise((resolve) => setTimeout(resolve, 25))

    expect(context.manager.state).toBe("open")
    expect(starts).toHaveBeenCalledTimes(1)
    await context.manager.stop()
  })

  it("reconnects an open connection that fails its wake probe", async () => {
    const context = createConnection({
      wakeProbeTimeoutMs: 10,
    })
    const starts = vi.spyOn(context.transport, "start")
    await openConnection(context)

    await context.manager.systemDidWake()
    await waitFor(() => starts.mock.calls.length === 2)

    expect(context.manager.state).toBe(
      "connectingTransport",
    )
    await context.manager.stop()
  })
})
