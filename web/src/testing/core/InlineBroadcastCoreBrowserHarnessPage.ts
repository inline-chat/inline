import { userId } from "@inline/ids"
import { InlineBroadcastCoreCoordinator } from "../../inline/core/InlineBroadcastCoreCoordinator"
import type {
  InlineCoreClientMessage,
  InlineCoreHostMessage,
} from "../../inline/core/InlineCoreProtocol"
import type {
  InlineCoreMessageEvent,
  InlineCoreMessagePort,
} from "../../inline/core/InlineCoreHost"

export type InlineBroadcastCoreBrowserHarness = {
  start: (routeId: string) => void
  ping: (nonce: string) => Promise<string>
  hostCreations: () => number
  ownerErrors: () => string[]
  shutdown: () => Promise<void>
}

declare global {
  interface Window {
    inlineBroadcastCoreHarness: InlineBroadcastCoreBrowserHarness
  }
}

const accountId = userId("9223372036854774998")
const runtimeErrors: string[] = []
let coordinator: InlineBroadcastCoreCoordinator | undefined
let createdHosts = 0

class HeartbeatHost {
  private readonly listeners = new Map<
    InlineCoreMessagePort,
    (event: InlineCoreMessageEvent) => void
  >()

  constructor(private readonly ownerId: string) {}

  attachPort(port: InlineCoreMessagePort) {
    const listener = (event: InlineCoreMessageEvent) => {
      const message = event.data as InlineCoreClientMessage
      if (message.type !== "inlineCoreHeartbeat") return
      port.postMessage({
        type: "inlineCoreHeartbeatAck",
        nonce: message.nonce,
        ownerId: this.ownerId,
      })
    }
    this.listeners.set(port, listener)
    port.addEventListener("message", listener)
  }

  detachPort(port: InlineCoreMessagePort) {
    const listener = this.listeners.get(port)
    if (listener) port.removeEventListener?.("message", listener)
    this.listeners.delete(port)
  }

  async shutdown() {
    for (const port of Array.from(this.listeners.keys())) {
      this.detachPort(port)
    }
  }
}

window.addEventListener("error", (event) => {
  if (event.target === coordinator) return
  runtimeErrors.push(
    event.error instanceof Error
      ? event.error.stack ?? event.error.message
      : event.message,
  )
})
window.addEventListener("unhandledrejection", (event) => {
  runtimeErrors.push(
    event.reason instanceof Error
      ? event.reason.stack ?? event.reason.message
      : String(event.reason),
  )
})

window.inlineBroadcastCoreHarness = {
  start: (routeId) => {
    if (coordinator) throw new Error("Broadcast core harness already started")
    coordinator = new InlineBroadcastCoreCoordinator(accountId, {
      routeId,
      hostFactory: () => {
        createdHosts += 1
        return new HeartbeatHost(routeId)
      },
    })
    coordinator.addEventListener("error", (event) => {
      runtimeErrors.push(
        event instanceof ErrorEvent && event.message
          ? event.message
          : "Inline broadcast owner failed",
      )
    })
  },
  ping: (nonce) =>
    new Promise<string>((resolve, reject) => {
      if (!coordinator) {
        reject(new Error("Broadcast core harness is not started"))
        return
      }
      const activeCoordinator = coordinator
      const timeout = window.setTimeout(() => {
        activeCoordinator.port.removeEventListener?.("message", listener)
        reject(new Error(`Broadcast core heartbeat ${nonce} timed out`))
      }, 3_000)
      const listener = (event: { data: unknown }) => {
        const message = event.data as InlineCoreHostMessage
        if (
          message.type !== "inlineCoreHeartbeatAck" ||
          message.nonce !== nonce
        ) return
        window.clearTimeout(timeout)
        activeCoordinator.port.removeEventListener?.("message", listener)
        resolve(message.ownerId)
      }
      activeCoordinator.port.addEventListener("message", listener)
      activeCoordinator.port.postMessage({
        type: "inlineCoreHeartbeat",
        nonce,
      })
    }),
  hostCreations: () => createdHosts,
  ownerErrors: () => runtimeErrors.slice(),
  shutdown: async () => {
    const activeCoordinator = coordinator
    coordinator = undefined
    await activeCoordinator?.shutdown()
  },
}
