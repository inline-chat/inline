import type { ConnectionManager } from "@inline/client/core"

type Connection = Pick<ConnectionManager,
  "setNetworkAvailable" | "setAppActive" | "systemDidWake">

/** Browser hints feed the shared connection policy; this adapter owns no retries. */
export class BrowserLifecycle {
  private detachListeners: (() => void) | undefined
  private readonly operations = new Set<Promise<void>>()

  constructor(
    private readonly connection: Connection,
    private readonly onError: (error: unknown) => void,
    private readonly onDiscard: () => void,
  ) {}

  async attach() {
    if (this.detachListeners || typeof window === "undefined") return
    const run = (operation: Promise<void>) => {
      this.operations.add(operation)
      void operation.then(
        () => { this.operations.delete(operation) },
        (error: unknown) => {
          this.operations.delete(operation)
          this.onError(error)
        },
      )
    }
    const wake = () => {
      if (!document.hidden) run(this.connection.systemDidWake())
    }
    const visibility = () => {
      if (document.hidden) run(this.connection.setAppActive(false))
      else wake()
    }
    const online = () => { run(this.connection.setNetworkAvailable(true)) }
    const offline = () => { run(this.connection.setNetworkAvailable(false)) }
    const pagehide = (event: PageTransitionEvent) => {
      run(this.connection.setAppActive(false))
      if (!event.persisted) this.onDiscard()
    }
    const pageshow = (event: PageTransitionEvent) => {
      run(this.connection.setNetworkAvailable(navigator.onLine !== false))
      if (event.persisted) wake()
      else run(this.connection.setAppActive(!document.hidden))
    }
    const freeze = () => { run(this.connection.setAppActive(false)) }
    let lastCheck = Date.now()
    const timer = window.setInterval(() => {
      const now = Date.now()
      if (now - lastCheck > 60_000) wake()
      lastCheck = now
    }, 15_000)

    window.addEventListener("online", online)
    window.addEventListener("offline", offline)
    window.addEventListener("pagehide", pagehide)
    window.addEventListener("pageshow", pageshow)
    document.addEventListener("visibilitychange", visibility)
    document.addEventListener("freeze", freeze)
    document.addEventListener("resume", wake)
    this.detachListeners = () => {
      window.removeEventListener("online", online)
      window.removeEventListener("offline", offline)
      window.removeEventListener("pagehide", pagehide)
      window.removeEventListener("pageshow", pageshow)
      document.removeEventListener("visibilitychange", visibility)
      document.removeEventListener("freeze", freeze)
      document.removeEventListener("resume", wake)
      window.clearInterval(timer)
      this.detachListeners = undefined
    }

    // Establish constraints before RealtimeClient.start can open a socket.
    await Promise.all([
      this.connection.setNetworkAvailable(navigator.onLine !== false),
      this.connection.setAppActive(!document.hidden),
    ])
  }

  async detach() {
    this.detachListeners?.()
    await Promise.allSettled(this.operations)
  }
}
