import { userId } from "@inline/ids"
import { describe, expect, it, vi } from "vitest"
import type {
  InlineCoreClientMessage,
  InlineCoreHostMessage,
} from "./InlineCoreProtocol"
import {
  InlineBroadcastCoreCoordinator,
  type InlineBroadcastChannel,
  type InlineBroadcastLockManager,
} from "./InlineBroadcastCoreCoordinator"
import type {
  InlineCoreMessageEvent,
  InlineCoreMessagePort,
} from "./InlineCoreHost"

type ChannelListener = (event: { data: unknown }) => void

class FakeBroadcastNetwork {
  private readonly channels = new Map<string, Set<FakeBroadcastChannel>>()

  create = (name: string): InlineBroadcastChannel => {
    const channel = new FakeBroadcastChannel(this, name)
    const channels = this.channels.get(name) ?? new Set()
    channels.add(channel)
    this.channels.set(name, channels)
    return channel
  }

  send(sender: FakeBroadcastChannel, name: string, message: unknown) {
    for (const channel of this.channels.get(name) ?? []) {
      if (channel === sender) continue
      const cloned = structuredClone(message)
      queueMicrotask(() => channel.receive(cloned))
    }
  }

  close(channel: FakeBroadcastChannel, name: string) {
    const channels = this.channels.get(name)
    channels?.delete(channel)
    if (channels?.size === 0) this.channels.delete(name)
  }
}

class FakeBroadcastChannel implements InlineBroadcastChannel {
  private readonly messageListeners = new Set<ChannelListener>()
  private readonly errorListeners = new Set<ChannelListener>()
  private closed = false

  constructor(
    private readonly network: FakeBroadcastNetwork,
    private readonly name: string,
  ) {}

  postMessage(message: Parameters<InlineBroadcastChannel["postMessage"]>[0]) {
    if (this.closed) throw new Error("channel closed")
    this.network.send(this, this.name, message)
  }

  addEventListener(type: "message" | "messageerror", listener: ChannelListener) {
    ;(type === "message" ? this.messageListeners : this.errorListeners).add(
      listener,
    )
  }

  removeEventListener(
    type: "message" | "messageerror",
    listener: ChannelListener,
  ) {
    ;(type === "message" ? this.messageListeners : this.errorListeners).delete(
      listener,
    )
  }

  close() {
    if (this.closed) return
    this.closed = true
    this.network.close(this, this.name)
    this.messageListeners.clear()
    this.errorListeners.clear()
  }

  receive(data: unknown) {
    if (this.closed) return
    for (const listener of this.messageListeners) listener({ data })
  }
}

class FakeLockManager implements InlineBroadcastLockManager {
  held = false
  readonly events: string[] = []

  async request<T>(
    _name: string,
    _options: { mode: "exclusive"; ifAvailable: true },
    callback: (lock: unknown | null) => Promise<T>,
  ): Promise<T> {
    if (this.held) return callback(null)
    this.held = true
    try {
      return await callback({ name: "inline-core" })
    } finally {
      this.held = false
      this.events.push("lock-released")
    }
  }
}

class FakeHost {
  readonly received: Array<{
    port: InlineCoreMessagePort
    message: InlineCoreClientMessage
  }> = []
  readonly attached = new Set<InlineCoreMessagePort>()
  readonly detached: InlineCoreMessagePort[] = []
  readonly events: string[] = []
  private readonly listeners = new Map<
    InlineCoreMessagePort,
    (event: InlineCoreMessageEvent) => void
  >()

  constructor(private readonly ownerId: string) {}

  attachPort(port: InlineCoreMessagePort) {
    const listener = (event: InlineCoreMessageEvent) => {
      const message = event.data as InlineCoreClientMessage
      this.received.push({ port, message })
      if (message.type === "inlineCoreHeartbeat") {
        port.postMessage({
          type: "inlineCoreHeartbeatAck",
          nonce: message.nonce,
          ownerId: this.ownerId,
        })
      }
    }
    this.attached.add(port)
    this.listeners.set(port, listener)
    port.addEventListener("message", listener)
  }

  detachPort(port: InlineCoreMessagePort) {
    const listener = this.listeners.get(port)
    if (listener) port.removeEventListener?.("message", listener)
    this.listeners.delete(port)
    this.attached.delete(port)
    this.detached.push(port)
  }

  async shutdown() {
    this.events.push("host-shutdown")
    for (const port of Array.from(this.attached)) this.detachPort(port)
  }
}

const heartbeat = (nonce: string): InlineCoreClientMessage => ({
  type: "inlineCoreHeartbeat",
  nonce,
})

const collectHostMessages = (coordinator: InlineBroadcastCoreCoordinator) => {
  const messages: InlineCoreHostMessage[] = []
  coordinator.port.addEventListener("message", (event) => {
    messages.push(event.data as InlineCoreHostMessage)
  })
  return messages
}

describe("InlineBroadcastCoreCoordinator", () => {
  it("routes owner and follower clients through one account host", async () => {
    const network = new FakeBroadcastNetwork()
    const locks = new FakeLockManager()
    const hosts: FakeHost[] = []
    const create = (routeId: string) =>
      new InlineBroadcastCoreCoordinator(userId(7), {
        routeId,
        locks,
        channelFactory: network.create,
        hostFactory: () => {
          const host = new FakeHost(routeId)
          hosts.push(host)
          return host
        },
      })
    const owner = create("owner")
    const follower = create("follower")
    const ownerMessages = collectHostMessages(owner)
    const followerMessages = collectHostMessages(follower)

    owner.port.postMessage(heartbeat("owner-ping"))
    follower.port.postMessage(heartbeat("follower-ping"))

    await vi.waitFor(() => {
      expect(ownerMessages).toContainEqual({
        type: "inlineCoreHeartbeatAck",
        nonce: "owner-ping",
        ownerId: "owner",
      })
      expect(followerMessages).toContainEqual({
        type: "inlineCoreHeartbeatAck",
        nonce: "follower-ping",
        ownerId: "owner",
      })
    })
    expect(hosts).toHaveLength(1)
    expect(hosts[0]?.received.map(({ message }) => message)).toEqual([
      heartbeat("owner-ping"),
      heartbeat("follower-ping"),
    ])

    await follower.shutdown()
    await vi.waitFor(() => expect(hosts[0]?.detached).toHaveLength(1))
    await owner.shutdown()
    expect(hosts[0]?.events).toContain("host-shutdown")
    expect(locks.events).toEqual(["lock-released"])
  })

  it("keeps the ownership lock until host shutdown resolves", async () => {
    const network = new FakeBroadcastNetwork()
    const locks = new FakeLockManager()
    let finishHostShutdown: (() => void) | undefined
    const host = new FakeHost("owner")
    host.shutdown = vi.fn(async () => {
      host.events.push("host-shutdown-started")
      await new Promise<void>((resolve) => {
        finishHostShutdown = resolve
      })
      host.events.push("host-shutdown-finished")
    })
    const owner = new InlineBroadcastCoreCoordinator(userId(7), {
      routeId: "owner",
      locks,
      channelFactory: network.create,
      hostFactory: () => host,
    })

    const shutdown = owner.shutdown()
    await vi.waitFor(() => {
      expect(host.events).toContain("host-shutdown-started")
    })
    expect(locks.held).toBe(true)
    expect(locks.events).toEqual([])

    finishHostShutdown?.()
    await shutdown
    expect(host.events).toEqual([
      "host-shutdown-started",
      "host-shutdown-finished",
    ])
    expect(locks.events).toEqual(["lock-released"])
  })

  it("makes owner loss terminal for followers instead of replaying mutations", async () => {
    const network = new FakeBroadcastNetwork()
    const locks = new FakeLockManager()
    const owner = new InlineBroadcastCoreCoordinator(userId(7), {
      routeId: "owner",
      locks,
      channelFactory: network.create,
      hostFactory: () => new FakeHost("owner"),
    })
    const follower = new InlineBroadcastCoreCoordinator(userId(7), {
      routeId: "follower",
      locks,
      channelFactory: network.create,
      hostFactory: () => new FakeHost("follower"),
    })
    const errors: Event[] = []
    follower.addEventListener("error", (event) => errors.push(event))
    follower.port.postMessage(heartbeat("discover"))
    await vi.waitFor(() => expect(locks.held).toBe(true))

    await owner.shutdown()
    await vi.waitFor(() => expect(errors).toHaveLength(1))

    await follower.shutdown()
  })

  it("fails visibly when the browser has no safe ownership primitives", async () => {
    const coordinator = new InlineBroadcastCoreCoordinator(userId(7), {
      routeId: "unsupported",
      locks: undefined,
      channelFactory: undefined,
    })
    const errors: Event[] = []
    coordinator.addEventListener("error", (event) => errors.push(event))

    coordinator.port.postMessage(heartbeat("unsupported"))
    await vi.waitFor(() => expect(errors).toHaveLength(1))

    await coordinator.shutdown()
  })

  it("bounds messages queued while no owner is discoverable", async () => {
    const network = new FakeBroadcastNetwork()
    const locks = new FakeLockManager()
    locks.held = true
    const coordinator = new InlineBroadcastCoreCoordinator(userId(7), {
      routeId: "waiting-follower",
      locks,
      channelFactory: network.create,
      hostFactory: () => new FakeHost("unexpected-owner"),
    })
    const errors: Event[] = []
    coordinator.addEventListener("error", (event) => errors.push(event))

    for (let index = 0; index < 65; index += 1) {
      coordinator.port.postMessage(heartbeat(`queued-${index}`))
    }
    await vi.waitFor(() => expect(errors).toHaveLength(1))

    await coordinator.shutdown()
  })
})
