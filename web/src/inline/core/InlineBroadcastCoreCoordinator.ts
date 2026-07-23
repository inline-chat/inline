import type { UserID } from "@inline/ids"
import {
  InlineCoreHost,
  type InlineCoreMessageEvent,
  type InlineCoreMessagePort,
} from "./InlineCoreHost"
import type {
  InlineCoreClientMessage,
  InlineCoreHostMessage,
} from "./InlineCoreProtocol"
import { INLINE_CORE_PROTOCOL_VERSION } from "./InlineCoreProtocol"
import { inlineCoreAccountLockName } from "./InlineCoreAccountOwnership"
import type {
  InlineCoreClientMessageEvent,
  InlineCoreClientPort,
} from "./InlineCoreRendererClient"

const BROADCAST_TRANSPORT_VERSION = 1 as const
const MAX_PRE_OWNER_MESSAGES = 64
const MAX_ROUTE_ID_LENGTH = 256

type BroadcastCoreEnvelope =
  | {
      transportVersion: typeof BROADCAST_TRANSPORT_VERSION
      protocolVersion: typeof INLINE_CORE_PROTOCOL_VERSION
      accountId: UserID
      type: "ownerAvailable"
      ownerRouteId: string
    }
  | {
      transportVersion: typeof BROADCAST_TRANSPORT_VERSION
      protocolVersion: typeof INLINE_CORE_PROTOCOL_VERSION
      accountId: UserID
      type: "discoverOwner"
    }
  | {
      transportVersion: typeof BROADCAST_TRANSPORT_VERSION
      protocolVersion: typeof INLINE_CORE_PROTOCOL_VERSION
      accountId: UserID
      type: "clientMessage"
      ownerRouteId: string
      clientRouteId: string
      message: InlineCoreClientMessage
    }
  | {
      transportVersion: typeof BROADCAST_TRANSPORT_VERSION
      protocolVersion: typeof INLINE_CORE_PROTOCOL_VERSION
      accountId: UserID
      type: "hostMessage"
      ownerRouteId: string
      clientRouteId: string
      message: InlineCoreHostMessage
    }
  | {
      transportVersion: typeof BROADCAST_TRANSPORT_VERSION
      protocolVersion: typeof INLINE_CORE_PROTOCOL_VERSION
      accountId: UserID
      type: "clientClosed"
      ownerRouteId: string
      clientRouteId: string
    }
  | {
      transportVersion: typeof BROADCAST_TRANSPORT_VERSION
      protocolVersion: typeof INLINE_CORE_PROTOCOL_VERSION
      accountId: UserID
      type: "ownerClosed"
      ownerRouteId: string
    }

type BroadcastMessageEvent = { data: unknown }

export type InlineBroadcastChannel = {
  postMessage(message: BroadcastCoreEnvelope): void
  addEventListener(
    type: "message" | "messageerror",
    listener: (event: BroadcastMessageEvent) => void,
  ): void
  removeEventListener?(
    type: "message" | "messageerror",
    listener: (event: BroadcastMessageEvent) => void,
  ): void
  close(): void
}

export type InlineBroadcastLockManager = {
  request<T>(
    name: string,
    options: { mode: "exclusive"; ifAvailable: true },
    callback: (lock: unknown | null) => Promise<T>,
  ): Promise<T>
}

type BroadcastCoreHost = Pick<
  InlineCoreHost,
  "attachPort" | "detachPort" | "shutdown"
>

export type InlineBroadcastCoreCoordinatorOptions = {
  channelFactory?: (name: string) => InlineBroadcastChannel
  locks?: InlineBroadcastLockManager
  hostFactory?: () => BroadcastCoreHost
  routeId?: string
}

const makeRouteId = () =>
  typeof crypto !== "undefined" && "randomUUID" in crypto
    ? `inline-core-route-${crypto.randomUUID()}`
    : `inline-core-route-${Date.now()}-${Math.random().toString(36).slice(2)}`

const channelName = (accountId: UserID) =>
  `inline-core-broadcast-v${INLINE_CORE_PROTOCOL_VERSION}-${accountId}`

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value != null

const isRouteId = (value: unknown): value is string =>
  typeof value === "string" &&
  value.length > 0 &&
  value.length <= MAX_ROUTE_ID_LENGTH

const isProtocolMessage = (
  value: unknown,
): value is InlineCoreClientMessage | InlineCoreHostMessage =>
  isRecord(value) && typeof value.type === "string"

const isEnvelope = (
  value: unknown,
  accountId: UserID,
): value is BroadcastCoreEnvelope => {
  if (
    !isRecord(value) ||
    value.transportVersion !== BROADCAST_TRANSPORT_VERSION ||
    value.protocolVersion !== INLINE_CORE_PROTOCOL_VERSION ||
    value.accountId !== accountId
  ) return false
  switch (value.type) {
    case "discoverOwner":
      return true
    case "ownerAvailable":
    case "ownerClosed":
      return isRouteId(value.ownerRouteId)
    case "clientMessage":
    case "hostMessage":
      return (
        isRouteId(value.ownerRouteId) &&
        isRouteId(value.clientRouteId) &&
        isProtocolMessage(value.message)
      )
    case "clientClosed":
      return (
        isRouteId(value.ownerRouteId) &&
        isRouteId(value.clientRouteId)
      )
    default:
      return false
  }
}

class BroadcastHostPort implements InlineCoreMessagePort {
  private readonly listeners = new Set<
    (event: InlineCoreMessageEvent) => void
  >()

  constructor(
    readonly clientRouteId: string,
    private readonly send: (message: InlineCoreHostMessage) => void,
  ) {}

  postMessage(message: InlineCoreHostMessage) {
    this.send(message)
  }

  addEventListener(
    _type: "message",
    listener: (event: InlineCoreMessageEvent) => void,
  ) {
    this.listeners.add(listener)
  }

  removeEventListener(
    _type: "message",
    listener: (event: InlineCoreMessageEvent) => void,
  ) {
    this.listeners.delete(listener)
  }

  start() {}

  receive(message: InlineCoreClientMessage) {
    for (const listener of this.listeners) listener({ data: message })
  }
}

class BroadcastRendererPort implements InlineCoreClientPort {
  private readonly listeners = new Set<
    (event: InlineCoreClientMessageEvent) => void
  >()

  constructor(private readonly coordinator: InlineBroadcastCoreCoordinator) {}

  postMessage(message: InlineCoreClientMessage) {
    this.coordinator.postClientMessage(message)
  }

  addEventListener(
    _type: "message",
    listener: (event: InlineCoreClientMessageEvent) => void,
  ) {
    this.listeners.add(listener)
  }

  removeEventListener(
    _type: "message",
    listener: (event: InlineCoreClientMessageEvent) => void,
  ) {
    this.listeners.delete(listener)
  }

  start() {}

  close() {
    void this.coordinator.shutdown()
  }

  receive(message: InlineCoreHostMessage) {
    for (const listener of this.listeners) listener({ data: message })
  }
}

/**
 * Non-SharedWorker transport. Exactly one tab owns InlineCoreHost while an
 * exclusive Web Lock is held; every tab, including the owner tab, talks to it
 * through the same account-scoped BroadcastChannel protocol.
 */
export class InlineBroadcastCoreCoordinator extends EventTarget {
  readonly routeId: string
  readonly port: InlineCoreClientPort

  private readonly accountId: UserID
  private readonly channel?: InlineBroadcastChannel
  private readonly locks?: InlineBroadcastLockManager
  private readonly hostFactory: () => BroadcastCoreHost
  private readonly rendererPort: BroadcastRendererPort
  private readonly hostPorts = new Map<string, BroadcastHostPort>()
  private readonly preOwnerMessages: InlineCoreClientMessage[] = []
  private readonly handleMessage = (event: BroadcastMessageEvent) => {
    this.receiveEnvelope(event.data)
  }
  private readonly handleMessageError = () => {
    this.reportOwnerFailure("Inline core fallback channel could not decode a message")
  }
  private ownerRouteId?: string
  private host?: BroadcastCoreHost
  private releaseOwnerLock?: () => void
  private lockTask: Promise<unknown> | null = null
  private unavailableMessage?: string
  private closed = false
  private shutdownTask: Promise<void> | null = null
  private ownerFailureReported = false

  constructor(
    accountId: UserID,
    options: InlineBroadcastCoreCoordinatorOptions = {},
  ) {
    super()
    this.accountId = accountId
    this.routeId = options.routeId ?? makeRouteId()
    this.rendererPort = new BroadcastRendererPort(this)
    this.port = this.rendererPort
    this.hostFactory = options.hostFactory ?? (() => new InlineCoreHost())
    this.locks =
      options.locks ??
      (typeof navigator === "undefined"
        ? undefined
        : (navigator.locks as InlineBroadcastLockManager | undefined))
    const channelFactory =
      options.channelFactory ??
      (typeof BroadcastChannel === "undefined"
        ? undefined
        : (name: string) => new BroadcastChannel(name))
    if (!this.locks || !channelFactory) {
      this.unavailableMessage =
        "Inline requires SharedWorker or BroadcastChannel with Web Locks to protect its local replica"
      return
    }

    this.channel = channelFactory(channelName(accountId))
    this.channel.addEventListener("message", this.handleMessage)
    this.channel.addEventListener("messageerror", this.handleMessageError)
    this.lockTask = this.acquireOwnerLock().catch((error: unknown) => {
      this.reportOwnerFailure(
        error instanceof Error
          ? `Inline core fallback ownership failed: ${error.message}`
          : "Inline core fallback ownership failed",
      )
    })
  }

  postClientMessage(message: InlineCoreClientMessage) {
    if (this.closed) {
      throw new Error("Inline core fallback transport is closed")
    }
    if (this.unavailableMessage) {
      queueMicrotask(() => this.reportOwnerFailure(this.unavailableMessage!))
      return
    }
    if (!this.ownerRouteId) {
      if (this.preOwnerMessages.length >= MAX_PRE_OWNER_MESSAGES) {
        this.reportOwnerFailure(
          "Inline core fallback owner did not become available",
        )
        return
      }
      this.preOwnerMessages.push(message)
      this.postEnvelope(this.baseEnvelope("discoverOwner"))
      return
    }
    this.sendClientMessage(message)
  }

  shutdown(): Promise<void> {
    if (this.shutdownTask) return this.shutdownTask
    this.shutdownTask = this.finishShutdown()
    return this.shutdownTask
  }

  private async acquireOwnerLock() {
    await this.locks!.request(
      inlineCoreAccountLockName(this.accountId),
      { mode: "exclusive", ifAvailable: true },
      async (lock) => {
        if (!lock || this.closed) {
          if (!this.closed) this.postEnvelope(this.baseEnvelope("discoverOwner"))
          return
        }
        this.host = this.hostFactory()
        this.ownerRouteId = this.routeId
        this.postOwnerAvailable()
        this.flushPreOwnerMessages()
        await new Promise<void>((resolve) => {
          this.releaseOwnerLock = resolve
        })
        await this.host.shutdown()
        this.host = undefined
        this.hostPorts.clear()
      },
    )
  }

  private async finishShutdown() {
    if (this.ownerRouteId) {
      this.sendClientClosed()
    }
    if (this.host) {
      this.postEnvelope({
        ...this.baseEnvelope("ownerClosed"),
        ownerRouteId: this.routeId,
      })
    }
    // Terminal envelopes must be posted before regular traffic is closed.
    // BroadcastChannel clones synchronously, so closing after postMessage does
    // not revoke messages already queued for the other tabs.
    this.closed = true
    this.releaseOwnerLock?.()
    this.releaseOwnerLock = undefined
    await this.lockTask?.catch(() => undefined)
    this.channel?.removeEventListener?.("message", this.handleMessage)
    this.channel?.removeEventListener?.("messageerror", this.handleMessageError)
    this.channel?.close()
    this.preOwnerMessages.length = 0
  }

  private receiveEnvelope(raw: unknown) {
    if (this.closed || !isEnvelope(raw, this.accountId)) return
    switch (raw.type) {
      case "discoverOwner":
        if (this.host) this.postOwnerAvailable()
        return
      case "ownerAvailable":
        if (
          this.ownerRouteId &&
          this.ownerRouteId !== raw.ownerRouteId
        ) {
          this.reportOwnerFailure(
            "Inline core fallback owner changed; reload is required",
          )
          return
        }
        this.ownerRouteId = raw.ownerRouteId
        this.flushPreOwnerMessages()
        return
      case "clientMessage":
        if (
          !this.host ||
          raw.ownerRouteId !== this.routeId ||
          !isRouteId(raw.clientRouteId)
        ) return
        this.receiveClientMessage(raw.clientRouteId, raw.message)
        return
      case "hostMessage":
        if (
          raw.clientRouteId !== this.routeId ||
          raw.ownerRouteId !== this.ownerRouteId
        ) return
        this.rendererPort.receive(raw.message)
        return
      case "clientClosed":
        if (!this.host || raw.ownerRouteId !== this.routeId) return
        this.detachHostPort(raw.clientRouteId)
        return
      case "ownerClosed":
        if (raw.ownerRouteId === this.ownerRouteId) {
          this.reportOwnerFailure(
            "Inline core fallback owner stopped; reload is required",
          )
        }
    }
  }

  private receiveClientMessage(
    clientRouteId: string,
    message: InlineCoreClientMessage,
  ) {
    let port = this.hostPorts.get(clientRouteId)
    if (!port) {
      port = new BroadcastHostPort(clientRouteId, (hostMessage) => {
        this.sendHostMessage(clientRouteId, hostMessage)
      })
      this.hostPorts.set(clientRouteId, port)
      this.host!.attachPort(port)
    }
    port.receive(message)
  }

  private sendClientMessage(message: InlineCoreClientMessage) {
    if (this.ownerRouteId === this.routeId && this.host) {
      this.receiveClientMessage(this.routeId, message)
      return
    }
    this.postEnvelope({
      ...this.baseEnvelope("clientMessage"),
      ownerRouteId: this.ownerRouteId!,
      clientRouteId: this.routeId,
      message,
    })
  }

  private sendHostMessage(
    clientRouteId: string,
    message: InlineCoreHostMessage,
  ) {
    if (clientRouteId === this.routeId) {
      this.rendererPort.receive(message)
      return
    }
    this.postEnvelope({
      ...this.baseEnvelope("hostMessage"),
      ownerRouteId: this.routeId,
      clientRouteId,
      message,
    })
  }

  private sendClientClosed() {
    if (!this.ownerRouteId) return
    if (this.ownerRouteId === this.routeId && this.host) {
      this.detachHostPort(this.routeId)
      return
    }
    this.postEnvelope({
      ...this.baseEnvelope("clientClosed"),
      ownerRouteId: this.ownerRouteId,
      clientRouteId: this.routeId,
    })
  }

  private detachHostPort(clientRouteId: string) {
    const port = this.hostPorts.get(clientRouteId)
    if (!port) return
    this.hostPorts.delete(clientRouteId)
    this.host?.detachPort(port)
  }

  private flushPreOwnerMessages() {
    if (!this.ownerRouteId) return
    const queued = this.preOwnerMessages.splice(0)
    for (const message of queued) this.sendClientMessage(message)
  }

  private postOwnerAvailable() {
    this.postEnvelope({
      ...this.baseEnvelope("ownerAvailable"),
      ownerRouteId: this.routeId,
    })
  }

  private postEnvelope(envelope: BroadcastCoreEnvelope) {
    if (this.closed) return
    try {
      this.channel?.postMessage(envelope)
    } catch {
      this.reportOwnerFailure(
        "Inline core fallback channel could not send a message",
      )
    }
  }

  private baseEnvelope<T extends BroadcastCoreEnvelope["type"]>(type: T) {
    return {
      transportVersion: BROADCAST_TRANSPORT_VERSION,
      protocolVersion: INLINE_CORE_PROTOCOL_VERSION,
      accountId: this.accountId,
      type,
    } as Extract<BroadcastCoreEnvelope, { type: T }>
  }

  private reportOwnerFailure(message: string) {
    if (this.ownerFailureReported || this.closed) return
    this.ownerFailureReported = true
    const event =
      typeof ErrorEvent === "undefined"
        ? new Event("error")
        : new ErrorEvent("error", { message })
    this.dispatchEvent(event)
  }
}

export const supportsInlineBroadcastCore = () =>
  typeof BroadcastChannel !== "undefined" &&
  typeof navigator !== "undefined" &&
  navigator.locks != null
